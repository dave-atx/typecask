#!/bin/sh
# Checks fonts the way App Store Connect does before it accepts an upload, and fails on any it would
# reject (ITMS-90792). Give it the directories to search; with none, it checks every font the app
# ships: the previews and the unpacked Fonts.xcassets.
#
#   scripts/check-fonts.sh [path ...]
#
# FontValidator ships with macOS but isn't on PATH. Version 3.5, in macOS 27.2, is the first that
# takes these options and reports what the App Store acts on; see Apple's TN3214. On an older macOS,
# a CI runner's included, this warns and checks nothing rather than fail every build until the image
# catches up. Asset catalogs compile to a format it can't read, so it checks the sources, not an app.
set -eu

cd "$(dirname "$0")/.."

VALIDATOR=/System/Library/Frameworks/ApplicationServices.framework/Frameworks/ATS.framework/Support/FontValidator
MINIMUM=3.5

if [ $# -eq 0 ]; then
    set -- Typecask/Previews Typecask/ApplePreviews Typecask/Fonts.xcassets
fi

skip() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning title=Fonts not checked::$1"
    else
        echo "warning: fonts not checked: $1" >&2
    fi
    exit 0
}

[ -x "$VALIDATOR" ] || skip "no FontValidator at $VALIDATOR"
version=$("$VALIDATOR" -version 2> /dev/null | sed -n 's/^Version \([0-9.]*\).*/\1/p' | head -1)
lowest=$(printf '%s\n%s\n' "$MINIMUM" "${version:-0}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
if [ -z "$version" ] || [ "$lowest" != "$MINIMUM" ]; then
    skip "FontValidator ${version:-of unknown version} is older than $MINIMUM, which macOS 27.2 brings; this is macOS $(sw_vers -productVersion)"
fi

report=$(mktemp)
trap 'rm -f "$report"' EXIT
# iOS at strict, because the app requests the Fonts capability. Progress goes to stderr; the report
# goes to the file, and the exit status is 255 when any font fails.
status=0
"$VALIDATOR" -platform iOS -level strict -reportType full -appleFonts -onlyFailures \
    -reportOutput "$report" "$@" > /dev/null 2>&1 || status=$?

python3 - "$report" "$status" << 'PY'
import json, sys
report = json.load(open(sys.argv[1]))
status = int(sys.argv[2])
failed = [detail for detail in report.get("Details", []) if not detail.get("result")]
for detail in failed:
    issues = [
        f"{issue.get('code')} {'; '.join(issue.get('messages', [])) or issue.get('issue', '')}"
        for font in detail.get("fonts", [])
        for issue in font.get("issues", [])
    ]
    print(f"error: {detail['path']}: {' | '.join(issues) or 'rejected'}")
print(f"{report.get('FontFiles', 0)} fonts checked, {report.get('Failures', len(failed))} rejected")
if failed or status not in (0, 255):
    sys.exit(1 if failed else f"FontValidator exited {status}")
PY
