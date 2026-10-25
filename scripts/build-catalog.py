#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["fonttools==4.67.0"]
# ///
"""Builds Typecask's catalog from Homebrew's most-installed font casks.

Writes into Typecask/:
  Catalog.json      gallery metadata, including each cask's design style
  Previews/         fonts subset to the sample text, for rendering the gallery before install
  Licenses/         license texts from each cask's download, or else from the GitHub repository it comes from
  Fonts.xcassets/   fonts as data sets tagged for On-Demand Resources (one tag per cask); about 11 GB for every
                    cask, so pass --fonts to limit it to a few casks for local builds
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date
from pathlib import Path

from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ANALYTICS_URL = "https://formulae.brew.sh/api/analytics/cask-install/365d.json"
CASKS_URL = "https://formulae.brew.sh/api/cask.json"
DEFAULT_CATALOG_SIZE = 1000
EXCLUDED = {
    # Apple's license forbids redistribution.
    "font-sf-pro",
    "font-sf-mono",
    "font-sf-mono-nerd-font-ligaturized",
    # Icons, symbols and emoji have nothing to preview.
    "font-symbols-only-nerd-font",
    "font-powerline-symbols",
    "font-fontawesome",
    "font-sketchybar-app-font",
    "font-noto-color-emoji",
    # Bundles the faces of font-noto-sans-cjk-{sc,jp,kr}, which would collide.
    "font-noto-sans-cjk",
}
ALWAYS_INCLUDED = ["font-ioskeley-mono", "font-ioskeley-mono-term-nerd-font"]
SAMPLE_TEXT = "The quick brown fox jumps over the lazy dog 0123456789 {}[]()<>=!&|"
ARCHIVE_SUFFIXES = (".zip", ".tar.xz", ".tar.gz", ".7z")
COLLECTION_SUFFIXES = (".ttc", ".otc")
LICENSE_NAME = re.compile(r"licen[cs]e|\bofl\b|copying|copyright", re.IGNORECASE)
LICENSE_SUFFIXES = ("", ".txt", ".md")
GITHUB_REPO = re.compile(r"github\.com/([^/]+)/([^/]+?)(?:\.git)?/")
CATALOG_INFO = {"info": {"author": "xcode", "version": 1}}

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Typecask"
FONTS = APP / "Fonts.xcassets"
PREVIEWS = APP / "Previews"
LICENSES = APP / "Licenses"
WORK = ROOT / ".cache" / "casks"
BREW_ENV = os.environ | {"HOMEBREW_NO_AUTO_UPDATE": "1"}


def fetch_json(url):
    with urllib.request.urlopen(url) as response:
        return json.load(response)


def rank_casks(analytics, casks_by_token):
    """Returns every eligible font cask with its install count, most-installed first."""
    installs = {}
    for item in analytics["items"]:
        token = item["cask"]
        if token.startswith("font-") and token in casks_by_token and token not in EXCLUDED:
            installs.setdefault(token, int(item["count"].replace(",", "")))
    return [(casks_by_token[token], installs[token]) for token in sorted(installs, key=installs.get, reverse=True)]


def fetch_downloads(tokens, batch=50):
    """Fetches in batches, returning only what landed in the cache.

    Homebrew is given many tokens at once so it downloads concurrently, but a single dead URL fails the
    whole command — at a thousand casks that is a certainty, so failures are tolerated here and the
    missing casks are skipped later rather than ending the run.
    """
    downloads = {}
    for start in range(0, len(tokens), batch):
        chunk = tokens[start:start + batch]
        subprocess.run(["brew", "fetch", "--cask", *chunk], env=BREW_ENV, check=False)
        paths = subprocess.run(
            ["brew", "--cache", "--cask", *chunk], env=BREW_ENV, check=False, capture_output=True, text=True
        ).stdout.split()
        for token, path in zip(chunk, map(Path, paths)):
            if path.exists():
                downloads[token] = path
    return downloads


def stage(cask, download):
    """Returns the directory that the cask's artifact paths are relative to."""
    if download.is_dir():
        return download / cask.get("url_specs", {}).get("only_path", "")
    staged = WORK / cask["token"]
    shutil.rmtree(staged, ignore_errors=True)
    staged.mkdir(parents=True)
    name = download.name.split("--", 1)[-1]
    if name.endswith(ARCHIVE_SUFFIXES):
        subprocess.run(["tar", "-xf", download, "-C", staged], check=True)
    else:
        shutil.copy(download, staged / name)
    return staged


@dataclass(frozen=True)
class Face:
    path: Path
    number: int  # index within a collection
    postscript_name: str
    regular: bool


def read_faces(path):
    """Reads only name tables. Collections share glyph tables between faces, so loading faces eagerly reads the
    shared data once per face: tens of GB for Iosevka's 324-face SuperTTC."""
    def face(number, font):
        names = font["name"]
        regular = (names.getDebugName(17) or names.getDebugName(2)) == "Regular"
        return Face(path, number, names.getDebugName(6), regular)

    if path.suffix.lower() in COLLECTION_SUFFIXES:
        with TTCollection(path, lazy=True) as collection:
            return [face(number, font) for number, font in enumerate(collection.fonts)]
    with TTFont(path, lazy=True) as font:
        return [face(0, font)]


def primary_face(faces):
    """Prefers the shortest-named upright Regular, which skips Nerd Font Mono/Propo variants."""
    return min(faces, key=lambda face: (not face.regular, len(face.postscript_name)))


# PANOSE serif styles 11-15 are the sans-serif ones: normal, obtuse and perpendicular sans, plus flared
# and rounded, which are sans designs too (Lato and Carlito both declare 15). 2-10 are the true serif brackets.
PANOSE_SANS_SERIF = range(11, 16)
PANOSE_MONOSPACED = 9


def classify(font):
    """The font's design style, from PANOSE and the OS/2 family class.

    Read before subsetting, from the cask's own primary face. Falls back through PANOSE to sFamilyClass
    because plenty of fonts fill in only one of them.
    """
    os2 = font.get("OS/2")
    panose = getattr(os2, "panose", None)
    family_class = (os2.sFamilyClass >> 8) if os2 is not None else 0
    family_type = getattr(panose, "bFamilyType", 0)
    serif_style = getattr(panose, "bSerifStyle", 0)

    post = font.get("post")
    if (post is not None and post.isFixedPitch) or getattr(panose, "bProportion", 0) == PANOSE_MONOSPACED:
        return "monospaced"
    if family_type == 3 or family_class == 10:
        return "handwriting"
    if family_type in (4, 5) or family_class in (9, 12):
        return "display"
    if family_type == 2 and serif_style:
        return "sansSerif" if serif_style in PANOSE_SANS_SERIF else "serif"
    if 1 <= family_class <= 7:
        return "serif"
    return "sansSerif"


def write_preview(face, token):
    postscript_name = "TypecaskPreview-" + re.sub(r"[^A-Za-z0-9-]", "_", token)
    with TTFont(face.path, fontNumber=face.number, lazy=True) as font:
        style = classify(font)
        # Subsetting first leaves the instancer a few dozen glyphs instead of the whole font.
        options = Options()
        options.layout_features = ["*"]
        options.name_IDs = ["*"]
        subsetter = Subsetter(options)
        subsetter.populate(text=SAMPLE_TEXT)
        subsetter.subset(font)
        if "fvar" in font:
            instantiateVariableFont(font, {axis.axisTag: None for axis in font["fvar"].axes}, inplace=True)
        if "STAT" in font:
            del font["STAT"]
        font["name"].names = []
        for name_id, value in ((1, postscript_name), (2, "Regular"), (4, postscript_name), (6, postscript_name)):
            font["name"].setName(value, name_id, 3, 1, 0x409)
        if "CFF " in font:
            font["CFF "].cff.fontNames = [postscript_name]
        file_name = f"{postscript_name}.{'otf' if 'CFF ' in font or 'CFF2' in font else 'ttf'}"
        font.save(PREVIEWS / file_name)
    return file_name, style


def github_license(owner, repo):
    try:
        response = fetch_json(f"https://api.github.com/repos/{owner}/{repo}/license")
    except urllib.error.HTTPError:
        return None
    return f"License of github.com/{owner}/{repo}:\n\n" + base64.b64decode(response["content"]).decode()


def find_license(root, cask):
    paths = sorted(path for path in root.rglob("*") if path.suffix.lower() in LICENSE_SUFFIXES
                   and LICENSE_NAME.search(path.stem) and path.is_file())
    if paths:
        return "\n\n".join(path.read_text(errors="replace") for path in paths)
    repo = GITHUB_REPO.search(cask["url"] + "/")
    return repo and github_license(*repo.groups())


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def write_dataset(path, asset, token):
    group = FONTS / token
    dataset = group / f"{asset}.dataset"
    dataset.mkdir(parents=True)
    # actool skips a group folder with no Contents.json, which leaves the cask's asset pack empty: the tag
    # downloads fine and registration then fails with "could not be found in an asset catalog". No
    # provides-namespace, so the assets keep the bare PostScript names Catalog.json records.
    group_contents = group / "Contents.json"
    if not group_contents.exists():
        write_json(group_contents, CATALOG_INFO)
    try:
        os.link(path, dataset / path.name)
    except OSError:
        shutil.copy(path, dataset / path.name)
    write_json(dataset / "Contents.json", CATALOG_INFO | {
        "data": [{"filename": path.name, "idiom": "universal"}],
        "properties": {"on-demand-resource-tags": [token]},
    })


def add_cask(cask, installs, root, license, owners, with_fonts):
    token = cask["token"]
    (LICENSES / f"{token}.txt").write_text(license)
    # `assets` is what this build can actually register; `faces` counts every font in the cask either way,
    # so a cask left out by --fonts still reports its real size in the gallery.
    all_assets, assets, faces, size = [], [], [], 0
    for artifact in cask["artifacts"]:
        if "font" not in artifact:
            continue
        path = root / artifact["font"][0]
        file_faces = read_faces(path)
        # Named by PostScript name, which unlike family names is unique per file.
        asset = file_faces[0].postscript_name
        if asset in owners:
            print(f"warning: {token}: skipping {path.name}, {asset!r} already comes from {owners[asset]}")
            continue
        owners[asset] = token
        all_assets.append(asset)
        if with_fonts:
            write_dataset(path, asset, token)
            assets.append(asset)
        faces += file_faces
        size += path.stat().st_size
    primary = primary_face(faces)
    preview_file, style = write_preview(primary, token)
    return {
        "token": token,
        "name": cask["name"][0],
        "homepage": cask["homepage"],
        "installs": installs,
        "bytes": size,
        "fonts": len(all_assets),
        "assets": assets,
        "primaryFont": primary.postscript_name,
        "style": style,
        "previewFile": preview_file,
    }


def main():
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fonts", nargs="+", metavar="TOKEN", help="write font assets only for these casks")
    parser.add_argument("--count", type=int, default=DEFAULT_CATALOG_SIZE, metavar="N",
                        help=f"how many casks to put in the catalog (default {DEFAULT_CATALOG_SIZE})")
    parser.add_argument("--scratch", metavar="DIR",
                        help="stage casks and Homebrew's download cache here, for a run that needs more "
                             "room than the boot disk has")
    arguments = parser.parse_args()
    global WORK, BREW_ENV
    if arguments.scratch:
        scratch = Path(arguments.scratch)
        WORK = scratch / "casks"
        # Homebrew's own cache holds every downloaded archive and dwarfs the staging directory.
        BREW_ENV = BREW_ENV | {"HOMEBREW_CACHE": str(scratch / "homebrew")}
        (scratch / "homebrew").mkdir(parents=True, exist_ok=True)
    count = arguments.count
    ranked = rank_casks(fetch_json(ANALYTICS_URL), {cask["token"]: cask for cask in fetch_json(CASKS_URL)})
    # Fetched together so Homebrew downloads them concurrently; casks replacing unlicensed ones are fetched later.
    downloads = fetch_downloads([cask["token"] for cask, _ in ranked[:count]] + ALWAYS_INCLUDED)
    for directory in (FONTS, PREVIEWS, LICENSES):
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir(parents=True)
    write_json(FONTS / "Contents.json", CATALOG_INFO)
    owners, entries, open_slots, still_included = {}, [], count, set(ALWAYS_INCLUDED)
    for cask, installs in ranked:
        token = cask["token"]
        if not open_slots and token not in still_included:
            if still_included:
                continue
            break
        still_included.discard(token)
        download = downloads.get(token) or fetch_downloads([token]).get(token)
        if download is None:
            print(f"warning: {token}: skipped, download failed")
            continue
        try:
            root = stage(cask, download)
            if license := find_license(root, cask):
                print(f"{token} ({installs:,} installs)")
                with_fonts = arguments.fonts is None or token in arguments.fonts
                entries.append(add_cask(cask, installs, root, license, owners, with_fonts))
                open_slots = max(open_slots - 1, 0)
            else:
                # Without a license to ship alongside the fonts, there's no basis for redistributing them.
                print(f"warning: {token}: skipped, no license found")
        except Exception as error:  # noqa: BLE001 - one unreadable cask shouldn't end a run of a thousand
            print(f"warning: {token}: skipped, {type(error).__name__}: {error}")
        shutil.rmtree(WORK / token, ignore_errors=True)
    write_json(APP / "Catalog.json", {
        "source": "Homebrew cask install analytics, 365 days",
        "generated": date.today().isoformat(),
        "sampleText": SAMPLE_TEXT,
        "casks": entries,
    })
    print(f"{len(entries)} casks, {sum(len(entry['assets']) for entry in entries)} fonts")


if __name__ == "__main__":
    sys.exit(main())
