#!/usr/bin/env python3
"""Says what a fonts build changed, in Markdown, for its release notes and pull request.

    scripts/fonts-changelog.py [BASE] [--lost FILE]

Compares the casks that ship in Typecask/Catalog.json, those with fonts in the archive, with the ones
at BASE (default HEAD), and lists what was added, removed, updated to a new version, or rebuilt into
different files at the same version. A removed cask says why where it can: fonts.lock.json says
whether it is still in the line-up, and the .cache/build-report.json that build writes says why a
locked cask didn't ship.

A cask that shipped at BASE and failed to build this time leads the notes with a warning, and --lost
writes those tokens to FILE, one to a line, so the workflow can hold the pull request as a draft.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = "Typecask/Catalog.json"
LOCK = "fonts.lock.json"
REPORT = ROOT / ".cache" / "build-report.json"
# A section longer than this folds into a <details> block, so a rebuild of every cask after a
# PIPELINE_VERSION bump doesn't bury the casks that were added and removed.
FOLD_AFTER = 25
# GitHub caps a pull request body at 65,536 characters and release notes at 125,000.
MAX_CHARACTERS = 60_000
# curl's exit codes for the download failures casks actually hit.
CURL_ERRORS = {6: "host not found", 7: "connection refused", 22: "HTTP error", 28: "timed out", 35: "TLS error"}


def load(path, base):
    """The JSON at path in the working tree, or at base when given; {} where it doesn't exist."""
    if base is None:
        file = ROOT / path
        return json.loads(file.read_text()) if file.is_file() else {}
    shown = subprocess.run(["git", "-C", ROOT, "show", f"{base}:{path}"], check=False, capture_output=True, text=True)
    return json.loads(shown.stdout) if shown.returncode == 0 else {}


def shipping(catalog):
    return {cask["token"]: cask for cask in catalog.get("casks", []) if cask["assets"]}


def failure(error):
    """A build error as a few words: most are curl failing, as a CalledProcessError naming its command."""
    if match := re.search(r"\['curl'.*exit status (\d+)", error):
        return f"download failed: {CURL_ERRORS.get(int(match[1]), f'curl exit {match[1]}')}"
    return error if len(error) <= 100 else error[:99] + "…"


def removal_reason(token, locked, listed, report):
    if token not in locked:
        return "no longer in the line-up"
    if error := report.get("failed", {}).get(token):
        return f"{failure(error)}; retried next run"
    if reason := report.get("skipped", {}).get(token):
        return reason
    if reason := report.get("trimmed", {}).get(token):
        return f"trimmed as a heavy niche cask ({reason})"
    if reason := report.get("unshippable", {}).get(token):
        return reason
    if owners := report.get("shadowed", {}).get(token):
        return f"its fonts now come from {', '.join(f'`{owner}`' for owner in owners)}"
    if token in listed:
        return "listed, but none of its files can ship"
    return "not in this build"


def line(cask, note=""):
    return f"- [{cask['name']}]({cask['homepage']}) `{cask['token']}`" + (f" {note}" if note else "")


def render(summary, sections, limit=None):
    out = summary.splitlines()
    for title, blurb, items in sections:
        if not items:
            continue
        shown = items if limit is None else items[:limit]
        out += ["", f"### {title} ({len(items)})", ""]
        if blurb:
            out += [blurb, ""]
        body = shown + ([f"- …and {len(items) - len(shown)} more"] if len(shown) < len(items) else [])
        if len(items) > FOLD_AFTER:
            out += ["<details>", f"<summary>{len(items)} casks</summary>", "", *body, "", "</details>"]
        else:
            out += body
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("base", nargs="?", default="HEAD", help="the revision to compare with (default HEAD)")
    parser.add_argument("--lost", type=Path, metavar="FILE", help="write the casks lost to a failed build here")
    arguments = parser.parse_args()
    base = arguments.base
    catalog = load(CATALOG, None)
    before, after = shipping(load(CATALOG, base)), shipping(catalog)
    listed = {cask["token"] for cask in catalog.get("casks", [])}
    locked = {entry["token"] for entry in load(LOCK, None).get("casks", [])}
    report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}

    def by_name(tokens, casks):
        return sorted(tokens, key=lambda token: (casks[token]["name"].casefold(), token))

    added = [line(after[token], after[token]["version"]) for token in by_name(after.keys() - before.keys(), after)]
    removed = [
        line(before[token], f"— {removal_reason(token, locked, listed, report)}")
        for token in by_name(before.keys() - after.keys(), before)
    ]
    updated, rebuilt = [], []
    for token in by_name(after.keys() & before.keys(), after):
        old, new = before[token], after[token]
        if old["version"] != new["version"]:
            updated.append(line(new, f"{old['version'] or '?'} → {new['version'] or '?'}"))
        elif any(old.get(key) != new.get(key) for key in ("fontVersion", "bytes", "assets")):
            rebuilt.append(line(new, new["version"]))

    fonts = sum(len(cask["assets"]) for cask in after.values())
    counts = [(len(added), "added"), (len(removed), "removed"), (len(updated), "updated"), (len(rebuilt), "rebuilt")]
    changes = ", ".join(f"{count} {word}" for count, word in counts if count) or f"no changes from {base}"
    summary = f"{len(after):,} casks ship {fonts:,} fonts: {changes}."
    lost = sorted((before.keys() - after.keys()) & report.get("failed", {}).keys())
    if lost:
        names = ", ".join(f"`{token}`" for token in lost)
        summary = (
            f"> [!WARNING]\n> {len(lost)} {'cask' if len(lost) == 1 else 'casks'} that shipped before failed to build "
            "this time and are left out: "
            f"{names}. Re-running the workflow may bring them back.\n\n{summary}"
        )
    if arguments.lost:
        arguments.lost.write_text("".join(f"{token}\n" for token in lost))
    sections = [
        ("Added", None, added),
        ("Removed", None, removed),
        ("Updated", None, updated),
        ("Rebuilt", "Same version, different font files: a new upstream build or a pipeline change.", rebuilt),
    ]
    text, limit = render(summary, sections), None
    while len(text) > MAX_CHARACTERS:
        limit = max(len(items) for *_, items in sections) // 2 if limit is None else limit // 2
        text = render(summary, sections, limit)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
