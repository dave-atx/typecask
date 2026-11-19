#!/usr/bin/env python3
"""Lists the casks whose foundries and designers a build drafted from their fonts' name tables, for review.

    scripts/makers.py list [--markdown]

Google Fonts credits its own families, and scripts/makers.json sorts those credits into people and foundries.
Every other cask needs an entry under casks in makers.json. Until it has one, the build reads its makers from
the name table of its primary face, which is as often a URL, a tool, or a team's name as a person. The
fonts pull request lists those casks with what was drafted for each: copy a draft into makers.json as it is,
correct it, or give the cask {} for no credit at all.

A Nerd Font or Powerline version takes the makers of the cask it patches, where the catalog has that cask: one
paired with it, or one whose Google description, credited in descriptionBy, it carries. It isn't listed.
"""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Typecask" / "Catalog.json"
LOCK = ROOT / "fonts.lock.json"
MAKERS = ROOT / "scripts" / "makers.json"


def drafted():
    """The catalog's records whose makers were drafted rather than reviewed, by name."""
    casks = json.loads(CATALOG.read_text())["casks"]
    locked = {entry["token"]: entry for entry in json.loads(LOCK.read_text())["casks"]}
    reviewed = json.loads(MAKERS.read_text())["casks"]
    paired = {record["nerdFont"] for record in casks if record.get("nerdFont")}
    return sorted(
        (
            record
            for record in casks
            if record["token"] not in reviewed
            and record["token"] not in paired
            and not record.get("descriptionBy")
            and not (locked.get(record["token"], {}).get("google") or {}).get("designers")
        ),
        key=lambda record: (record["name"].casefold(), record["token"]),
    )


def describe(record):
    parts = [f"{kind}: {', '.join(record[kind])}" for kind in ("foundries", "designers") if record.get(kind)]
    return "; ".join(parts) or "nothing"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="list the casks with drafted makers")
    listing.add_argument("--markdown", action="store_true", help="as a Markdown list, for the pull request")
    arguments = parser.parse_args()
    for record in drafted():
        if arguments.markdown:
            print(f"- [{record['name']}]({record['homepage']}) `{record['token']}`: {describe(record)}")
        else:
            print(f"{record['token']}: {describe(record)}")


if __name__ == "__main__":
    main()
