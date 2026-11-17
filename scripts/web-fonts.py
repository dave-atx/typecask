#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["fonttools==4.67.0", "brotli==1.2.0", "uharfbuzz==0.51.1", "boto3==1.40.70"]
# ///
"""Turns a fonts release's fonts into web fonts for the site's Try It Out, and publishes them to R2.

    scripts/web-fonts.py build XCASSETS OUT       convert into OUT/w/ and write OUT/manifest.json
    scripts/web-fonts.py upload OUT TAG           put OUT on R2, the manifest as manifests/TAG.json

`build` reads a Fonts.xcassets (or DebugFonts.xcassets), one folder per cask, and makes a WOFF2 of each
face, a collection's split into its faces, since browsers don't load collections. Each is named by a
hash of its bytes, w/HASH.woff2, so a fonts release uploads only the faces that changed and a page never
caches a stale one. The manifest lists each cask's faces, with their axes, and the text Try It Out starts
with, made as the app's TryOutText makes it (Typecask/TryOutText.swift, whose lists these mirror): the
coding sequences and fi and fl words the face joins, shaped by HarfBuzz both ways, then whichever lines
of letters, figures and symbols it covers, box drawing, Nerd Fonts' icons and another script's letters.
The site puts the cask's sample line first.

`upload` needs R2's S3 credentials (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CLOUDFLARE_ACCOUNT_ID) and
puts what R2 doesn't have yet in R2_BUCKET (default typecask-fonts), which fonts.typecask.app serves. It
fails rather than take the bucket past R2_MAX_GB (default 8, short of R2's 10 GB free tier): nothing deletes
old releases' faces, so that's the sign to clear them out.

Run it under the memory cap, as the other font scripts: python3 scripts/memcap.py 14 scripts/web-fonts.py ...
"""

import argparse
import hashlib
import io
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor
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
OTHER_SCRIPTS = [(0x0530, 0x1DFF), (0x2E80, 0xDFFF), (0xF900, 0xFDFF), (0x10000, 0x2FFFF)]
OTHER_SCRIPT_CHARACTERS = 240
OFF = {"liga": False, "calt": False, "clig": False}
# Bump when a manifest entry changes shape or its text is made differently, so cached entries are redone.
FORMAT = 1


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
    return [code for code in range(low, high + 1) if code in covered and not chr(code).isspace()]


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
    """One cask's faces, written as WOFF2 into out/w/, and its manifest entry."""
    folder, out = job
    files = sorted(path for path in folder.rglob("*") if path.suffix.lower() in FONT_SUFFIXES)
    faces = []
    for path in files:
        for number, font in faces_in(path):
            face = describe(font)
            covered = set(font.getBestCmap() or {})
            data = woff2(font)
            digest = hashlib.sha256(data).hexdigest()[:32]
            target = out / "w" / f"{digest}.woff2"
            if not target.exists():
                target.write_bytes(data)
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
        return folder.name, None
    # Listed regular before bold and upright before italic; the text comes from the face nearest regular.
    faces.sort(key=lambda face: (face["italic"], face["weight"], face["name"]))
    regular = min(faces, key=lambda face: (face["italic"], abs(face["weight"] - 400)))
    text, ligatures = showcase(regular["_path"], regular["_number"], regular["_covered"])
    listed = [{key: value for key, value in face.items() if not key.startswith("_")} for face in faces]
    return folder.name, {"faces": listed, "text": text, "ligatures": ligatures}


def build(xcassets, out, jobs):
    (out / "w").mkdir(parents=True, exist_ok=True)
    (out / "cache").mkdir(parents=True, exist_ok=True)
    folders = sorted(path for path in xcassets.iterdir() if path.is_dir() and path.name.startswith("font-"))
    keys = {folder.name: cask_key(folder) for folder in folders}
    # Casks whose files R2 has seen before keep their entry, and their faces are there already.
    client, bucket = r2()
    casks = {}
    if client:
        cached = listed(client, bucket, "cache/")
        for folder in folders:
            if f"cache/{keys[folder.name]}.json" in cached:
                body = client.get_object(Bucket=bucket, Key=f"cache/{keys[folder.name]}.json")["Body"].read()
                casks[folder.name] = json.loads(body)
    pending = [folder for folder in folders if folder.name not in casks]
    print(f"{len(casks)} casks unchanged since a release R2 has; converting {len(pending)}")
    with ProcessPoolExecutor(jobs) as pool:
        for token, entry in pool.map(build_cask, [(folder, out) for folder in pending]):
            if entry:
                casks[token] = entry
                (out / "cache" / f"{keys[token]}.json").write_text(json.dumps(entry, ensure_ascii=False))
            else:
                print(f"{token}: no font files")
    (out / "manifest.json").write_text(json.dumps({"casks": casks}, ensure_ascii=False, sort_keys=True) + "\n")
    size = sum(path.stat().st_size for path in (out / "w").iterdir())
    print(f"{len(casks)} casks; converted {len(list((out / 'w').iterdir()))} faces, {size / 1e6:.0f} MB of WOFF2")


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


def listed(client, bucket, prefix):
    return set(sizes(client, bucket, prefix))


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


def upload(out, tag):
    client, bucket = r2()
    stored = sizes(client, bucket)
    have = {key for key in stored if key.startswith("w/")}
    new = [path for path in sorted((out / "w").iterdir()) if f"w/{path.name}" not in have]
    # R2 has no quota of its own, and nothing here deletes old releases' faces, so the bucket only grows.
    # Stopping short of R2_MAX_GB says it's time to clear out faces no release in use still lists.
    total = sum(stored.values()) + sum(path.stat().st_size for path in new)
    if total > (cap := float(os.environ.get("R2_MAX_GB", "8")) * 1e9):
        sys.exit(f"{bucket} would hold {total / 1e9:.1f} GB, over R2_MAX_GB's {cap / 1e9:.0f} GB: clear it out first")
    for path in new:
        # Named by their bytes, so never changed: cached for good.
        client.upload_file(
            str(path),
            bucket,
            f"w/{path.name}",
            ExtraArgs={"ContentType": "font/woff2", "CacheControl": "public, max-age=31536000, immutable"},
        )
    cached = listed(client, bucket, "cache/")
    for path in sorted((out / "cache").glob("*.json")):
        if f"cache/{path.name}" not in cached:
            client.upload_file(str(path), bucket, f"cache/{path.name}", ExtraArgs={"ContentType": "application/json"})
    client.upload_file(
        str(out / "manifest.json"),
        bucket,
        f"manifests/{tag}.json",
        ExtraArgs={"ContentType": "application/json", "CacheControl": "public, max-age=3600"},
    )
    print(f"uploaded {len(new)} new faces ({len(have)} already there) and manifests/{tag}.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    built = commands.add_parser("build")
    built.add_argument("xcassets", type=Path)
    built.add_argument("out", type=Path)
    built.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    uploaded = commands.add_parser("upload")
    uploaded.add_argument("out", type=Path)
    uploaded.add_argument("tag")
    arguments = parser.parse_args()
    if arguments.command == "build":
        build(arguments.xcassets, arguments.out, arguments.jobs)
    else:
        upload(arguments.out, arguments.tag)


if __name__ == "__main__":
    sys.exit(main())
