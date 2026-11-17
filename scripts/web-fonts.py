#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["fonttools==4.67.0", "brotli==1.2.0", "uharfbuzz==0.51.1", "boto3==1.40.70"]
# ///
"""Turns a fonts release's fonts into web fonts for the site's Try It Out, and publishes them to R2.

    scripts/web-fonts.py build XCASSETS OUT [--tag TAG]

Reads a Fonts.xcassets (or DebugFonts.xcassets), one folder per cask, and makes a WOFF2 of each face, a
collection's split into its faces, since browsers don't load collections. Each is named by a hash of its
bytes, w/HASH.woff2, so a fonts release uploads only the faces that changed and a page never caches a
stale one. The manifest lists each cask's faces, with their axes, and the text Try It Out starts with,
made as the app's TryOutText makes it (Typecask/TryOutText.swift, whose lists these mirror): the coding
sequences and fi and fl words the face joins, shaped by HarfBuzz both ways, then whichever lines of
letters, figures and symbols it covers, box drawing, Nerd Fonts' icons and another script's letters. The
site puts the cask's sample line first.

With R2's S3 credentials (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CLOUDFLARE_ACCOUNT_ID), each cask's faces
and its entry go up to R2_BUCKET (default typecask-fonts, which fonts.typecask.app serves) as soon as it's
converted, filed under a hash of its files: a run that fails or times out keeps what it did, and every
later run, whatever the release, reuses the casks whose files haven't changed. --tag then publishes the
manifest as manifests/TAG.json. A font that can't be converted is reported and left out; more than
MAX_FAILURES and the manifest isn't published. Nothing deletes old faces, so uploads stop rather than take
the bucket past R2_MAX_GB (default 8, short of R2's 10 GB free tier): the sign to clear it out.

Each cask prints a line as it finishes, with how many are done and about how long the rest will take.
Run it locally under the memory cap, as the other font scripts:
python3 scripts/memcap.py 14 scripts/web-fonts.py build ...
"""

import argparse
import hashlib
import io
import json
import logging
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import uharfbuzz
from fontTools.ttLib import TTCollection, TTFont

FONT_SUFFIXES = (".ttf", ".otf", ".ttc", ".otc")

CODING_CANDIDATES = [
    "->", "=>", "<-", "<=", ">=", "!=", "!==", "==", "===", "<>", "<=>", "|>", "<|", "::", ":::", ":=", "=:=",
    "=/=", "...", "..", "..<", "..=", "?.", "??", "&&", "||", "++", "--", "**", "//", "///", "/*", "*/", "<!--",
    "-->", "</", "/>", "</>", "~>", "<~", "~~", "=~", "!~", ">>", "<<", ">>=", "<<=", "<->", "<=<", ">=>",
    "|->", "<|>", "-<", ">-", "#{", "#[", "#(", "#!", ";;", "|=", "^=", "0x", "www",
]  # fmt: skip
TEXT_CANDIDATES = ["office", "fluffy", "affirm", "afflict", "fjord", "after", "first", "flight"]
LINES = [
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "abcdefghijklmnopqrstuvwxyz",
    "0123456789 ½ ¼ ¾",
    "! \" # $ % & ' ( ) * + , - . / : ; < = > ? @ [ \\ ] ^ _ ` { | } ~",
    "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØŒÙÚÛÜÝ àáâãäåæçèéêëìíîïñòóôõöøœùúûüýÿß",
    "ĄąĆćĘęŁłŃńŚśŹźŻż ČčĎďĚěŇňŘřŠšŤťŮůŽž ĞğİıŞş ĀāĒēĪīŌōŪū",
    "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ абвгдежзийклмнопрстуфхцчшщъыьэюя",
    "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ αβγδεζηθικλμνξοπρστυφχψω",
    "$ € £ ¥ ¢ ₹ ₩ ₽ ₺ ₿ § ¶ † ‡ © ® ™ ° ‰ • … – — « » ‹ › “ ” ‘ ’",
    "← ↑ → ↓ ↔ ⇐ ⇒ ⇔ ≠ ≈ ≤ ≥ ± × ÷ ∞ √ ∑ ∏ ∫ ∂ ∆ ∈ ∀ ∃ ¬ ∧ ∨",
]
BOXES = "┌──┬──┐ ░░▒▒▓▓██\n│  │  │ ▀▀▄▄▌▐■□\n├──┼──┤ ╔══╦══╗\n└──┴──┘ ╚══╩══╝"
ICON_RANGES = [
    (0xE0A0, 0xE0D7), (0xF000, 0xF2E0), (0xE700, 0xE8EF), (0xE5FA, 0xE6B7), (0xEA60, 0xEC1E), (0xF400, 0xF533),
    (0xF300, 0xF381), (0xE300, 0xE3E3), (0xF0001, 0xF1AF0),
]  # fmt: skip
ICONS_PER_SET = 24
# Powerline's own glyphs, which a Nerd Font has and others hardly ever do.
NERD_SIGN = range(0xE0A0, 0xE0D8)
# Short of the surrogates, U+D800 to U+DFFF, which some fonts map but no text can hold.
OTHER_SCRIPTS = [(0x0530, 0x1DFF), (0x2E80, 0xD7FF), (0xF900, 0xFDFF), (0x10000, 0x2FFFF)]
OTHER_SCRIPT_CHARACTERS = 240
OFF = {"liga": False, "calt": False, "clig": False}
# Bump when a manifest entry changes shape or its text is made differently, so cached entries are redone.
FORMAT = 1
# Fonts that can't be converted, past which a run fails rather than publish a manifest without them.
MAX_FAILURES = 25

# fontTools' complaints about the fonts it reads, a few hundred lines a run that bury the progress.
logging.getLogger("fontTools").setLevel(logging.ERROR)


def faces_in(path):
    """Each face in a font file, as (number, TTFont)."""
    if path.suffix.lower() in (".ttc", ".otc"):
        return list(enumerate(TTCollection(path, lazy=True).fonts))
    return [(0, TTFont(path, lazy=True, recalcTimestamp=False))]


def name_of(font, ids):
    for name_id in ids:
        if (name := font["name"].getDebugName(name_id)) is not None:
            return name
    return None


def describe(font):
    """A face's style name, weight, italic and axes, as the site's style menu and sliders want them."""
    os2 = font.get("OS/2")
    weight = os2.usWeightClass if os2 else 400
    italic = bool(os2 and os2.fsSelection & 1) or bool("head" in font and font["head"].macStyle & 2)
    axes = []
    if "fvar" in font:
        for axis in font["fvar"].axes:
            if axis.flags & 1:  # hidden
                continue
            axes.append(
                {
                    "tag": axis.axisTag,
                    "name": name_of(font, [axis.axisNameID]) or axis.axisTag,
                    "min": axis.minValue,
                    "max": axis.maxValue,
                    "default": axis.defaultValue,
                }
            )
    style = name_of(font, [17, 2]) or "Regular"
    return {"name": style, "weight": weight, "italic": italic, "axes": axes}


def woff2(font):
    """The face as WOFF2 bytes."""
    font.flavor = "woff2"
    buffer = io.BytesIO()
    font.save(buffer)
    return buffer.getvalue()


def joins(hb_font, text):
    def glyphs(features):
        buffer = uharfbuzz.Buffer()
        buffer.add_str(text)
        buffer.guess_segment_properties()
        uharfbuzz.shape(hb_font, buffer, features)
        return [info.codepoint for info in buffer.glyph_infos]

    return glyphs({}) != glyphs(OFF)


def draws(text, covered):
    return all(character in " \n" or ord(character) in covered for character in text)


def kept(line, covered):
    words = ["".join(c for c in word if ord(c) in covered) for word in line.split(" ")]
    total = sum(c != " " for c in line)
    left = sum(len(word) for word in words)
    if left == 0 or left * 2 < total:
        return None
    return " ".join(word for word in words if word)


def scalars(low, high, covered):
    return [
        code
        for code in range(low, high + 1)
        if code in covered and not 0xD800 <= code <= 0xDFFF and not chr(code).isspace()
    ]


def showcase(path, number, covered):
    """Try It Out's text after the sample line, and whether the face joins anything."""
    hb_font = uharfbuzz.Font(uharfbuzz.Face(uharfbuzz.Blob.from_file_path(str(path)), number))
    sections = []
    coding = [text for text in CODING_CANDIDATES if draws(text, covered) and joins(hb_font, text)]
    words = [text for text in TEXT_CANDIDATES if draws(text, covered) and joins(hb_font, text)]
    if coding:
        sections.append(" ".join(coding))
    if words:
        sections.append(" ".join(words))
    if drawn := [line for line in (kept(line, covered) for line in LINES) if line]:
        sections.append("\n".join(drawn))
    if draws(BOXES, covered):
        sections.append(BOXES)
    if sum(code in covered for code in NERD_SIGN) >= 8:
        rows = []
        for low, high in ICON_RANGES:
            present = scalars(low, high, covered)
            if len(present) > ICONS_PER_SET:
                present = [present[i * len(present) // ICONS_PER_SET] for i in range(ICONS_PER_SET)]
            if present:
                rows.append(" ".join(chr(code) for code in present))
        sections.append("\n".join(rows))
    letters = [code for low, high in OTHER_SCRIPTS for code in scalars(low, high, covered)][:OTHER_SCRIPT_CHARACTERS]
    if letters:
        sections.append("\n".join(" ".join(chr(c) for c in letters[i : i + 20]) for i in range(0, len(letters), 20)))
    return "\n\n".join(sections), bool(coding or words)


def build_cask(job):
    """One cask's faces, written as WOFF2 into out/w/, and its manifest entry; or the error it hit, so one
    font that can't be read doesn't end the run."""
    folder, out = job
    started = time.monotonic()
    try:
        entry, written = convert(folder, out)
    except Exception as error:  # noqa: BLE001 — any font can break any way; the run reports it and goes on
        return folder.name, None, [], f"{type(error).__name__}: {error}", time.monotonic() - started
    return folder.name, entry, written, None, time.monotonic() - started


def convert(folder, out):
    files = sorted(path for path in folder.rglob("*") if path.suffix.lower() in FONT_SUFFIXES)
    faces, written = [], []
    for path in files:
        for number, font in faces_in(path):
            face = describe(font)
            covered = set(font.getBestCmap() or {})
            data = woff2(font)
            digest = hashlib.sha256(data).hexdigest()[:32]
            target = out / "w" / f"{digest}.woff2"
            if not target.exists():
                target.write_bytes(data)
            written.append(target)
            faces.append(
                face
                | {
                    "file": f"w/{digest}.woff2",
                    "bytes": len(data),
                    "_path": path,
                    "_number": number,
                    "_covered": covered,
                }
            )
    if not faces:
        return None, []
    # Listed regular before bold and upright before italic; the text comes from the face nearest regular.
    faces.sort(key=lambda face: (face["italic"], face["weight"], face["name"]))
    regular = min(faces, key=lambda face: (face["italic"], abs(face["weight"] - 400)))
    text, ligatures = showcase(regular["_path"], regular["_number"], regular["_covered"])
    listed = [{key: value for key, value in face.items() if not key.startswith("_")} for face in faces]
    return {"faces": listed, "text": text, "ligatures": ligatures}, written


class Store:
    """R2, as the run goes: each cask's faces and cache entry go up as soon as it's converted, so a run that
    fails or times out keeps what it did, and the next picks up where it stopped. Without R2's credentials,
    as in a local run, it keeps nothing."""

    def __init__(self):
        self.client, self.bucket = r2()
        stored = sizes(self.client, self.bucket) if self.client else {}
        self.keys = set(stored)
        self.total = sum(stored.values())
        # R2 has no quota of its own, and nothing here deletes old releases' faces, so the bucket only grows.
        # Stopping short of R2_MAX_GB says it's time to clear out faces no release in use still lists.
        self.cap = float(os.environ.get("R2_MAX_GB", "8")) * 1e9
        self.uploaded = 0

    def cached(self, key):
        if f"cache/{key}.json" not in self.keys:
            return None
        return json.loads(self.client.get_object(Bucket=self.bucket, Key=f"cache/{key}.json")["Body"].read())

    def keep(self, key, entry, written):
        if not self.client:
            return
        new = [path for path in written if f"w/{path.name}" not in self.keys]
        size = sum(path.stat().st_size for path in new)
        if self.total + size > self.cap:
            sys.exit(
                f"{self.bucket} would hold {(self.total + size) / 1e9:.1f} GB, over R2_MAX_GB's "
                f"{self.cap / 1e9:.0f} GB: clear it out first"
            )
        for path in new:
            # Named by their bytes, so never changed: cached for good.
            self.client.upload_file(
                str(path),
                self.bucket,
                f"w/{path.name}",
                ExtraArgs={"ContentType": "font/woff2", "CacheControl": "public, max-age=31536000, immutable"},
            )
            self.keys.add(f"w/{path.name}")
        self.total += size
        self.uploaded += len(new)
        # After its faces, so an entry on R2 always has them there.
        self.client.put_object(
            Bucket=self.bucket,
            Key=f"cache/{key}.json",
            Body=json.dumps(entry, ensure_ascii=False).encode(),
            ContentType="application/json",
        )
        self.keys.add(f"cache/{key}.json")

    def publish(self, manifest, tag):
        self.client.upload_file(
            str(manifest),
            self.bucket,
            f"manifests/{tag}.json",
            ExtraArgs={"ContentType": "application/json", "CacheControl": "public, max-age=3600"},
        )


def build(xcassets, out, jobs, tag=None):
    (out / "w").mkdir(parents=True, exist_ok=True)
    folders = sorted(path for path in xcassets.iterdir() if path.is_dir() and path.name.startswith("font-"))
    keys = {folder.name: cask_key(folder) for folder in folders}
    store = Store()
    casks = {}
    for folder in folders:
        if entry := store.cached(keys[folder.name]):
            casks[folder.name] = entry
    pending = [folder for folder in folders if folder.name not in casks]
    say(f"{len(folders)} casks: {len(casks)} done in an earlier run, {len(pending)} to convert")
    failed = {}
    started = time.monotonic()
    with ProcessPoolExecutor(jobs) as pool:
        futures = [pool.submit(build_cask, (folder, out)) for folder in pending]
        for done, future in enumerate(as_completed(futures), 1):
            token, entry, written, error, seconds = future.result()
            elapsed = time.monotonic() - started
            left = elapsed / done * (len(pending) - done)
            progress = f"[{done}/{len(pending)}, {elapsed / 60:.0f} min, about {left / 60:.0f} left]"
            if error:
                failed[token] = error
                say(f"::warning title=Web fonts::{token}: {error}")
                say(f"{progress} {token} failed")
                continue
            if not entry:
                say(f"{progress} {token}: no font files")
                continue
            store.keep(keys[token], entry, written)
            casks[token] = entry
            size = sum(face["bytes"] for face in entry["faces"])
            faces = len(entry["faces"])
            say(f"{progress} {token}: {faces} face{'s' * (faces != 1)}, {size / 1e6:.1f} MB, {seconds:.0f} s")
    manifest = out / "manifest.json"
    manifest.write_text(json.dumps({"casks": casks}, ensure_ascii=False, sort_keys=True) + "\n")
    say(f"{len(casks)} casks in the manifest; {store.uploaded} faces uploaded; {len(failed)} failed")
    # A few fonts that can't be converted only go without Try It Out. Many means something's wrong with
    # this script, and a manifest missing them would take Try It Out off their pages.
    if len(failed) > MAX_FAILURES:
        sys.exit(f"{len(failed)} casks failed, more than {MAX_FAILURES}: not publishing the manifest")
    if tag and store.client:
        store.publish(manifest, tag)
        say(f"published manifests/{tag}.json")


def say(line):
    print(line, flush=True)


def r2():
    """An S3 client for R2, and the bucket, or (None, None) without credentials."""
    if not os.environ.get("R2_ACCESS_KEY_ID"):
        return None, None
    import boto3  # Only R2 needs it.

    client = boto3.client(
        "s3",
        endpoint_url=f"https://{os.environ['CLOUDFLARE_ACCOUNT_ID']}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto",
    )
    return client, os.environ.get("R2_BUCKET", "typecask-fonts")


def sizes(client, bucket, prefix=""):
    """Every object under prefix, with its size in bytes."""
    found = {}
    for page in client.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        found.update((item["Key"], item["Size"]) for item in page.get("Contents", []))
    return found


def cask_key(folder):
    """A hash of the cask's font files and of this script's output format: the same files make the same
    entry, so a cached one stands in for converting them again."""
    digest = hashlib.sha256(str(FORMAT).encode())
    for path in sorted(path for path in folder.rglob("*") if path.suffix.lower() in FONT_SUFFIXES):
        digest.update(path.name.encode())
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()[:32]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    built = commands.add_parser("build")
    built.add_argument("xcassets", type=Path)
    built.add_argument("out", type=Path)
    built.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    built.add_argument("--tag", help="publish the manifest on R2 as manifests/TAG.json")
    arguments = parser.parse_args()
    build(arguments.xcassets, arguments.out, arguments.jobs, arguments.tag)


if __name__ == "__main__":
    sys.exit(main())
