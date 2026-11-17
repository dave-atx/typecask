#!/usr/bin/env python3
"""Prints a version's release notes, or sets them as a TestFlight build's What to Test.

    scripts/release-notes.py [VERSION]                 print them, for the App Store's What's New
    scripts/release-notes.py --testflight BUILD [VERSION]
    scripts/release-notes.py --site REF                versions up to REF's, as JSON for the site

The notes are docs/release-notes/VERSION.txt (VERSION defaults to the project's MARKETING_VERSION),
written by hand. Lines starting with # are left out, and {fonts} becomes how many fonts were added and
updated since the build its "# since TAG" line names, counted from the catalogs of that tag and the
working tree: the fonts ship in the app, so a release is how they reach anyone.

--testflight sets the notes on that build of the version through the App Store Connect API, with the
key the TestFlight workflow writes for altool (KEY_ID, ISSUER_ID and AuthKey_KEY_ID.p8). The build
shows up in the API a few minutes after its upload, so this waits for it. It signs the API's token with
openssl, so it needs nothing beyond Python and the runner's own tools.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOTES = ROOT / "docs" / "release-notes"
PROJECT = ROOT / "Typecask.xcodeproj" / "project.xcproj"
CATALOG = "Typecask/Catalog.json"
APP_ID = "6826936046"
API = "https://api.appstoreconnect.apple.com/v1"
# App Store Connect's limit for What's New and What to Test.
MAX_CHARACTERS = 4000


def marketing_version(ref=None):
    return re.search(r'"MARKETING_VERSION": "([^"]+)"', read(PROJECT.relative_to(ROOT).as_posix(), ref))[1]


def version_key(version):
    return [int(part) for part in version.split(".") if part.isdigit()]


def read(path, ref=None):
    """A file in the working tree, or at ref, or None where it isn't. A CI checkout is shallow and has no
    tags, so a missing ref is fetched."""
    if ref is None:
        file = ROOT / path
        return file.read_text() if file.is_file() else None
    show = ["git", "-C", ROOT, "show", f"{ref}:{path}"]
    shown = subprocess.run(show, check=False, capture_output=True, text=True)
    if (
        shown.returncode != 0
        and subprocess.run(
            ["git", "-C", ROOT, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
            check=False,
            capture_output=True,
        ).returncode
    ):
        subprocess.run(["git", "-C", ROOT, "fetch", "-q", "--depth=1", "origin", "tag", ref], check=True)
        shown = subprocess.run(show, check=False, capture_output=True, text=True)
    return shown.stdout if shown.returncode == 0 else None


def shipping(catalog):
    return {cask["token"]: cask for cask in catalog["casks"] if cask["assets"]}


def fonts_line(base, ref=None):
    """ "6 new fonts and 13 updated": casks shipping at ref (the working tree by default) and not at base,
    and those whose version or font version changed since."""
    before = shipping(json.loads(read(CATALOG, base)))
    after = shipping(json.loads(read(CATALOG, ref)))
    added = len(after.keys() - before.keys())
    updated = sum(
        (before[token].get("version"), before[token].get("fontVersion"))
        != (after[token].get("version"), after[token].get("fontVersion"))
        for token in after.keys() & before.keys()
    )
    new = f"{added:,} new font{'s' if added != 1 else ''}"
    return f"{new} and {updated:,} updated." if updated else f"{new}."


def notes(version, ref=None, catalog=None):
    """The notes as written at ref (the working tree by default), {fonts} counted at catalog (ref's own by
    default)."""
    path = NOTES / f"{version}.txt"
    if (source := read(path.relative_to(ROOT).as_posix(), ref)) is None:
        sys.exit(f"no release notes for {version}: write {path.relative_to(ROOT)}")
    lines = source.splitlines()
    base = next((match[1] for line in lines if (match := re.match(r"#\s*since\s+(\S+)", line))), None)
    text = "\n".join(line for line in lines if not line.startswith("#")).strip()
    if "{fonts}" in text:
        if not base:
            sys.exit(f"{path.name} uses {{fonts}} but has no '# since TAG' line")
        text = text.replace("{fonts}", fonts_line(base, catalog or ref))
    if len(text) > MAX_CHARACTERS:
        sys.exit(f"{path.name} is {len(text)} characters; App Store Connect takes {MAX_CHARACTERS}")
    return text


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_integer(der, offset):
    """An integer from a DER encoding at offset, as 32 bytes, and the offset after it."""
    assert der[offset] == 0x02
    length = der[offset + 1]
    value = der[offset + 2 : offset + 2 + length].lstrip(b"\0")
    return value.rjust(32, b"\0"), offset + 2 + length


def token(key_id, issuer, key_path):
    """A 20-minute App Store Connect API token, ES256-signed. openssl signs in DER; a JWT wants r and s."""
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    claims = {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    signing_input = f"{header}.{b64url(json.dumps(claims).encode())}"
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input.encode(), check=True, capture_output=True
    ).stdout
    # SEQUENCE { INTEGER r, INTEGER s }, with a one-byte length: an ES256 signature is at most 72 bytes.
    r, offset = der_integer(der, 2)
    s, _ = der_integer(der, offset)
    return f"{signing_input}.{b64url(r + s)}"


def call(method, path, bearer, body=None):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response) if response.status != 204 else {}


def set_what_to_test(build, version, text):
    key_id, issuer = os.environ["KEY_ID"], os.environ["ISSUER_ID"]
    key_path = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
    query = f"/builds?filter[app]={APP_ID}&filter[version]={build}&filter[preReleaseVersion.version]={version}&limit=1"
    deadline = time.time() + 30 * 60
    while True:
        # A fresh token each time round: the wait can outlast one.
        bearer = token(key_id, issuer, key_path)
        if found := call("GET", query, bearer)["data"]:
            break
        if time.time() > deadline:
            sys.exit(f"build {build} of {version} didn't appear in App Store Connect within 30 minutes")
        print(f"waiting for build {build} of {version} to appear in App Store Connect")
        time.sleep(60)
    build_id = found[0]["id"]
    localizations = call("GET", f"/builds/{build_id}/betaBuildLocalizations", bearer)["data"]
    existing = next((item for item in localizations if item["attributes"]["locale"] == "en-US"), None)
    if existing:
        call(
            "PATCH",
            f"/betaBuildLocalizations/{existing['id']}",
            bearer,
            {"data": {"type": "betaBuildLocalizations", "id": existing["id"], "attributes": {"whatsNew": text}}},
        )
    else:
        call(
            "POST",
            "/betaBuildLocalizations",
            bearer,
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": "en-US", "whatsNew": text},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )
    print(f"set What to Test on build {build} of {version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version", nargs="?", help="default: the project's MARKETING_VERSION")
    parser.add_argument("--testflight", metavar="BUILD", help="set the notes as this build's What to Test")
    parser.add_argument("--site", metavar="REF", help="print every version's notes as of REF, newest first, as JSON")
    arguments = parser.parse_args()
    if arguments.site:
        # The notes as written now, so a line can be corrected after a release, for the versions up to the
        # one at the tag; each version's fonts are counted at the tag, the build people have.
        released = version_key(marketing_version(arguments.site))
        versions = sorted(
            (path.stem for path in NOTES.glob("*.txt") if version_key(path.stem) <= released),
            key=version_key,
            reverse=True,
        )
        site = [{"version": version, "notes": notes(version, catalog=arguments.site)} for version in versions]
        print(json.dumps(site, indent=2, ensure_ascii=False))
        return
    version = arguments.version or marketing_version()
    text = notes(version)
    if arguments.testflight:
        try:
            set_what_to_test(arguments.testflight, version, text)
        except urllib.error.HTTPError as error:
            sys.exit(f"App Store Connect said {error.code}: {error.read().decode()[:500]}")
    else:
        print(text)


if __name__ == "__main__":
    main()
