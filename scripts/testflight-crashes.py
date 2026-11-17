#!/usr/bin/env python3
"""Downloads the newest TestFlight crash reports testers sent, with their logs, into a folder.

    scripts/testflight-crashes.py OUT [--limit N]

A crash a tester submits from TestFlight lands in App Store Connect under TestFlight › Crashes; this reads
the same through the App Store Connect API (betaFeedbackCrashSubmissions), with a key in
~/.appstoreconnect/private_keys/AuthKey_KEY_ID.p8: a team key with ISSUER_ID, or an individual key without.
Each report is OUT/ID.json, its device, build, OS and the tester's comment, and OUT/ID.crash, the log.

Run it on a Mac, never in this public repository's Actions: the reports carry testers' email addresses
and comments, and a public repository's artifacts and logs are anyone's to read.
"""

import argparse
import importlib.util
import json
import os
import subprocess
import time
import urllib.error
from pathlib import Path

# The token and request helpers are release-notes.py's, which sets What to Test with the same key.
spec = importlib.util.spec_from_file_location("release_notes", Path(__file__).with_name("release-notes.py"))
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


def token(key_id, issuer, key_path):
    """A team key's token, as release-notes.py makes it, or an individual key's, which names no issuer."""
    if issuer:
        return notes.token(key_id, issuer, key_path)
    header = notes.b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    claims = {"sub": "user", "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    signing_input = f"{header}.{notes.b64url(json.dumps(claims).encode())}"
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input.encode(), check=True, capture_output=True
    ).stdout
    r, offset = notes.der_integer(der, 2)
    s, _ = notes.der_integer(der, offset)
    return f"{signing_input}.{notes.b64url(r + s)}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out", type=Path)
    parser.add_argument("--limit", type=int, default=5)
    arguments = parser.parse_args()
    key_id = os.environ["KEY_ID"]
    key_path = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
    bearer = token(key_id, os.environ.get("ISSUER_ID"), key_path)
    arguments.out.mkdir(parents=True, exist_ok=True)
    query = f"/apps/{notes.APP_ID}/betaFeedbackCrashSubmissions?sort=-createdDate&limit={arguments.limit}"
    submissions = notes.call("GET", query, bearer)["data"]
    print(f"{len(submissions)} crash reports")
    for submission in submissions:
        identifier = submission["id"]
        attributes = submission["attributes"]
        (arguments.out / f"{identifier}.json").write_text(json.dumps(attributes, indent=2) + "\n")
        try:
            log = notes.call("GET", f"/betaFeedbackCrashSubmissions/{identifier}/crashLog", bearer)
            (arguments.out / f"{identifier}.crash").write_text(log["data"]["attributes"].get("logText") or "")
        except urllib.error.HTTPError as error:
            print(f"{identifier}: no log ({error.code})")
        print(
            f"{identifier}: {attributes.get('createdDate')} {attributes.get('deviceModel')} iOS {attributes.get('osVersion')}"
        )


if __name__ == "__main__":
    main()
