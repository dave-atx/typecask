#!/bin/sh
# Writes the build number TestFlight will see into the project: scripts/set-build-number.sh 4
#
# TestFlight rejects a build number it has already seen, so the N from the testflight-N tag that
# triggered the build becomes CURRENT_PROJECT_VERSION. The TestFlight workflow runs this.
set -eu

cd "$(dirname "$0")/.."

BUILD="${1:-}"

case "$BUILD" in
'' | *[!0-9]*)
    echo "error: build number '$BUILD' is not a number" >&2
    exit 1
    ;;
esac

echo "Setting CURRENT_PROJECT_VERSION to $BUILD"
BUILD="$BUILD" python3 - << 'PY'
import os
import re
from pathlib import Path

path = Path("Typecask.xcodeproj/project.xcproj")
source = path.read_text()
updated, count = re.subn(
    r'("CURRENT_PROJECT_VERSION": )"[^"]*"', r'\1"%s"' % os.environ["BUILD"], source
)
if count != 1:
    raise SystemExit(f"expected one CURRENT_PROJECT_VERSION in {path}, found {count}")
path.write_text(updated)
PY
