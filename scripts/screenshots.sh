#!/bin/sh
# Takes the app screenshots typecask.app shows and writes them to site/assets/screens/.
#
#   scripts/screenshots.sh
#
# Runs TypecaskUITests/SiteScreenshots on an iPhone and an iPad simulator at once, in dark
# appearance, since the site is dark only, with the status bar at 9:41 and full. The build is a copy
# of the project without Fonts.xcassets: the screenshots need only the bundled previews, and the
# fonts make a 3 - 4 GB debug app.
#
# The screenshots are checked in, because the site builds on Linux, where there's no simulator.
# Rerun this when the app's look changes, then check the result with hugo server. Set
# TYPECASK_SCREENSHOT_PHONE or TYPECASK_SCREENSHOT_PAD to use other simulators.
set -eu

cd "$(dirname "$0")/.."

phone=${TYPECASK_SCREENSHOT_PHONE:-iPhone 18 Pro}
pad=${TYPECASK_SCREENSHOT_PAD:-iPad Pro 13-inch (M5)}
out=site/assets/screens

# The first available simulator with exactly this name. Xcode can list several under one name, one
# per runtime, and -destination name= refuses to pick between them.
udid() {
    xcrun simctl list devices available | grep -F "    $1 (" | head -1 |
        sed 's/.*(\([0-9A-F-]\{36\}\)).*/\1/'
}

work=$(mktemp -d -t typecask-screens)
devices=""
cleanup() {
    for device in $devices; do
        xcrun simctl status_bar "$device" clear || true
    done
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

destinations=""
for name in "$phone" "$pad"; do
    device=$(udid "$name")
    if [ -z "$device" ]; then
        echo "screenshots.sh: no available simulator named '$name'." >&2
        exit 1
    fi
    devices="$devices $device"
    destinations="$destinations -destination id=$device"
    xcrun simctl boot "$device" 2> /dev/null || true
    xcrun simctl bootstatus "$device" -b > /dev/null
    xcrun simctl ui "$device" appearance dark
    xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiMode active \
        --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
done

echo "screenshots.sh: copying the project without its fonts"
rsync -a --exclude /.git --exclude /.cache --exclude /site --exclude /DerivedData \
    --exclude /Typecask/Fonts.xcassets ./ "$work/src/"

# Word splitting on $destinations is the point: it holds one -destination pair per simulator.
# shellcheck disable=SC2086
if ! xcodebuild test -project "$work/src/Typecask.xcodeproj" -scheme Typecask $destinations \
    -only-testing:TypecaskUITests/SiteScreenshots -derivedDataPath "$work/DerivedData" \
    -resultBundlePath "$work/Screenshots.xcresult" -quiet; then
    # Keep the result bundle, which holds a screen recording and the UI hierarchy at the failure.
    rm -rf Screenshots.xcresult
    mv "$work/Screenshots.xcresult" Screenshots.xcresult
    xcrun xcresulttool get test-results summary --path Screenshots.xcresult |
        python3 -I -c 'import json, sys
for failure in json.load(sys.stdin).get("testFailures", []):
    print("screenshots.sh: %s: %s" % (failure["testName"], failure["failureText"]), file=sys.stderr)'
    echo "screenshots.sh: the screenshots are unchanged; Screenshots.xcresult has the details." >&2
    exit 1
fi

xcrun xcresulttool export attachments --path "$work/Screenshots.xcresult" \
    --output-path "$work/attachments" > /dev/null

# The manifest maps each test's attachments, by the name the test gave them, to the exported file.
# XCTest adds its own, a UI hierarchy and the like, beside a failure; only the named screens are kept.
mkdir -p "$out"
python3 -I - "$work/attachments" "$out" << 'EOF'
import json
import re
import shutil
import sys
from pathlib import Path

attachments, out = Path(sys.argv[1]), Path(sys.argv[2])
for test in json.loads((attachments / "manifest.json").read_text()):
    for attachment in test["attachments"]:
        match = re.match(r"((?:iphone|ipad)-[a-z-]+)_", attachment["suggestedHumanReadableName"])
        if not match:
            continue
        name = match[1]
        shutil.copyfile(attachments / attachment["exportedFileName"], out / f"{name}.png")
        print(f"screenshots.sh: wrote {out / name}.png")
EOF

# Hugo resizes them for the page; this only keeps what's checked in small.
for png in "$out"/*.png; do
    sips -Z 2000 "$png" > /dev/null
done
oxipng -q -o 4 --strip safe "$out"/*.png
