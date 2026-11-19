#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Writes Typecask/Languages.json: the letters each language needs, from CLDR's exemplar characters.

    scripts/languages.py

A font's page lists the languages it can set, which the app works out on the device from the font's
character set once its full fonts are on hand. A language counts when the font has every one of its
main exemplar characters, lowercase and uppercase. CLDR is under the Unicode License; hyperglot, the
usual source for this, is GPL, which the App Store's terms rule out (see AGENTS.md).

Only languages, and languages in a script (sr-Latn), not regional variants (fr-CA), which share their
language's letters. The download is pinned, so the same CLDR always writes the same file.
"""

import hashlib
import io
import json
import pathlib
import re
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Typecask" / "Languages.json"
CLDR_VERSION = "49.0.0"
URL = f"https://registry.npmjs.org/cldr-misc-full/-/cldr-misc-full-{CLDR_VERSION}.tgz"
SHA256 = "d0129e972402b1d6b32ab44c82c5a058c3f721bf61bf07b2b652c9444eba8821"
LOCALE = re.compile(r"package/main/([a-z]{2,3}(?:-[A-Z][a-z]{3})?)/characters\.json")


def parse_set(text):
    """The characters of a CLDR UnicodeSet, like "[aàâ b {dž} c-e \\u0301]", with sequences split up:
    a font that has each character of dž can set it."""
    assert text.startswith("[") and text.endswith("]"), text
    body, characters, index, previous = text[1:-1], set(), 0, None
    while index < len(body):
        character = body[index]
        if character == "{":
            end = body.index("}", index)
            characters.update(body[index + 1 : end].replace("\\", ""))
            index, previous = end + 1, None
            continue
        if character == "-" and previous is not None and index + 1 < len(body):
            last, index = read_character(body, index + 1)
            characters.update(chr(point) for point in range(ord(previous) + 1, ord(last) + 1))
            previous = None
            continue
        if character == " ":
            index, previous = index + 1, None
            continue
        previous, index = read_character(body, index)
        characters.add(previous)
    return characters


def read_character(body, index):
    """The character at `index`, reading an escape like \\u0301 or \\-, and where the next one starts."""
    if body[index] != "\\":
        return body[index], index + 1
    if body[index + 1] == "u":
        return chr(int(body[index + 2 : index + 6], 16)), index + 6
    if body[index + 1] == "U":
        return chr(int(body[index + 2 : index + 10], 16)), index + 10
    return body[index + 1], index + 2


def letters(exemplars):
    """The exemplars and their capitals, where a capital is a single character (not ß's SS)."""
    characters = parse_set(exemplars)
    characters |= {upper for character in characters if len(upper := character.upper()) == 1}
    return "".join(sorted(characters))


def main():
    with urllib.request.urlopen(URL) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit(f"{URL} doesn't match its pinned sha256")
    languages = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            if not (match := LOCALE.fullmatch(member.name)):
                continue
            locale = match.group(1)
            characters = json.load(archive.extractfile(member))["main"][locale]["characters"]
            if exemplars := characters.get("exemplarCharacters"):
                languages[locale] = letters(exemplars)
    output = {"source": f"CLDR {CLDR_VERSION} main exemplar characters", "languages": dict(sorted(languages.items()))}
    OUTPUT.write_text(json.dumps(output, ensure_ascii=False, indent=1) + "\n")
    print(f"{OUTPUT.relative_to(ROOT)}: {len(languages)} languages")


if __name__ == "__main__":
    main()
