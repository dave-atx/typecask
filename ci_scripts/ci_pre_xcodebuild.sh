#!/bin/sh
# Xcode Cloud runs this after dependencies resolve, before xcodebuild.
#
# TestFlight rejects a build number it has already seen, so N from the testflight-N tag that triggered
# the build becomes CURRENT_PROJECT_VERSION. Tagging testflight-4 uploads build 4. Falls back to
# Xcode Cloud's own incrementing build number when the build wasn't started by a tag.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

TAG="${CI_TAG:-}"
case "$TAG" in
testflight-*) BUILD="${TAG#testflight-}" ;;
*) BUILD="${CI_BUILD_NUMBER:-1}" ;;
esac

case "$BUILD" in
'' | *[!0-9]*)
    echo "error: build number '$BUILD' from tag '$TAG' is not a number" >&2
    exit 1
    ;;
esac

echo "Setting CURRENT_PROJECT_VERSION to $BUILD (tag: ${TAG:-none})"
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
