#!/usr/bin/env python3
"""Fills Typecask/DebugFonts.xcassets with the few casks' fonts a debug build carries.

    scripts/debug-fonts.py [TOKEN ...] [--archive FILE]

A debug build leaves out Typecask/Fonts.xcassets, which holds every cask's fonts, makes a 3 - 4 GB app
and gives actool minutes of work, and carries this catalog instead; a release build does the opposite
(EXCLUDED_SOURCE_FILE_NAMES in the project). The debug app offers Install only for the casks whose
On-Demand Resources tags it finds in its bundle.

With no tokens, it takes the casks the UI tests install, a static font, a variable one, a collection,
one in a shared pack, and two the accessibility audit looks at. A cask in a shared pack brings the rest
of its pack, so a build that carries a tag has every font behind it.

The fonts come from Typecask/Fonts.xcassets where scripts/fetch-fonts-asset.sh has unpacked it, else
from --archive, a fonts release's .tar.zst, else from the release Typecask/FontsAsset.json pins,
downloaded once into .cache/.
"""

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "Typecask"
FULL = APP / "Fonts.xcassets"
DEBUG = APP / "DebugFonts.xcassets"
PIN = APP / "FontsAsset.json"
CACHE = ROOT / ".cache"

DEFAULT_CASKS = [
    "font-departure-mono-nerd-font",  # InstallTests' default
    "font-roboto",  # variable
    "font-d2coding",  # a collection
    "font-fira-code",  # in a shared pack
    "font-atkinson-hyperlegible-next",
    "font-lexend",
]

ROOT_CONTENTS = {"info": {"author": "xcode", "version": 1}}


def groups_for(tokens):
    """The asset catalog groups to carry: each cask named, and every cask sharing its pack."""
    casks = json.loads((APP / "Catalog.json").read_text())["casks"]
    by_token = {cask["token"]: cask for cask in casks}
    if unknown := [token for token in tokens if token not in by_token]:
        sys.exit(f"not in Catalog.json: {', '.join(unknown)}")
    if empty := [token for token in tokens if not by_token[token]["assets"]]:
        sys.exit(f"no fonts in this catalog: {', '.join(empty)}")
    packs = {by_token[token].get("pack") or token for token in tokens}
    return sorted(cask["token"] for cask in casks if cask["assets"] and (cask.get("pack") or cask["token"]) in packs)


def pinned_archive():
    """The pinned release's archive, downloaded into .cache/ the first time and checked every time."""
    pin = json.loads(PIN.read_text())
    archive = CACHE / f"{pin['tag']}.tar.zst"
    if not archive.exists():
        CACHE.mkdir(exist_ok=True)
        partial = archive.with_suffix(".partial")
        print(f"Fetching {pin['tag']}, {pin['bytes'] / 1e9:.1f} GB, once")
        # The API asset URL serves the file itself with this Accept header.
        subprocess.run(
            ["curl", "-fL", "--retry", "3", "-H", "Accept: application/octet-stream", "-o", partial, pin["url"]],
            check=True,
        )
        partial.replace(archive)
    digest = hashlib.sha256()
    with archive.open("rb") as file:
        while chunk := file.read(1 << 20):
            digest.update(chunk)
    if digest.hexdigest() != pin["sha256"]:
        sys.exit(f"{archive} doesn't match {PIN.name}'s sha256; delete it and run this again")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tokens", nargs="*", metavar="TOKEN", help="casks to carry (default: a few the tests use)")
    parser.add_argument("--archive", type=pathlib.Path, help="a fonts release's .tar.zst to take them from")
    arguments = parser.parse_args()
    groups = groups_for(arguments.tokens or DEFAULT_CASKS)

    # Staged outside Typecask/, where a run that died halfway would leave a folder the build picks up.
    CACHE.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
        staging = pathlib.Path(temporary) / "DebugFonts.xcassets"
        if FULL.is_dir() and not arguments.archive:
            if missing := [group for group in groups if not (FULL / group).is_dir()]:
                sys.exit(f"{FULL.name} has no {', '.join(missing)}; rerun scripts/fetch-fonts-asset.sh")
            for group in groups:
                shutil.copytree(FULL / group, staging / group)
        else:
            if not shutil.which("zstd"):
                sys.exit("tar needs zstd to unpack the archive: brew install zstd")
            archive = arguments.archive or pinned_archive()
            subprocess.run(
                ["tar", "--zstd", "-xf", archive, "-C", temporary, *(f"Fonts.xcassets/{group}" for group in groups)],
                check=True,
            )
            (pathlib.Path(temporary) / "Fonts.xcassets").rename(staging)
        # Every asset catalog group needs its own Contents.json, or actool ships an empty pack.
        (staging / "Contents.json").write_text(json.dumps(ROOT_CONTENTS, indent=2) + "\n")
        if DEBUG.exists():
            shutil.rmtree(DEBUG)
        staging.rename(DEBUG)

    print(f"{DEBUG.relative_to(ROOT)}: {', '.join(groups)}")


if __name__ == "__main__":
    main()
