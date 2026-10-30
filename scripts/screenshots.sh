#!/bin/sh
# Takes the app screenshots typecask.app shows and writes them to site/assets/screens/, or, with
# app-store, the images App Store Connect takes.
#
#   scripts/screenshots.sh                    the site's, scaled to fit 2000 pixels
#   scripts/screenshots.sh app-store          full size from an iPhone, a 13-inch iPad and an iPhone
#                                             Duo, laid out for the store, in AppStoreScreenshots/
#   scripts/screenshots.sh app-store-render   the store's images again from the shots already
#                                             taken, after a change to scripts/app-store/
#
# Runs TypecaskUITests/SiteScreenshots on an iPhone and an iPad simulator at once, in dark
# appearance, since the site is dark only, with the status bar at 9:41 and full. The build is a copy
# of the project without Fonts.xcassets: the screenshots need only the bundled previews, and the
# fonts make a 3 - 4 GB debug app.
#
# The site's screenshots are checked in, because the site builds on Linux, where there's no
# simulator. Rerun this when the app's look changes, then check the result with hugo server. Set
# TYPECASK_SCREENSHOT_PHONE or TYPECASK_SCREENSHOT_PAD to use other simulators.
#
# The store's are not: AppStoreScreenshots/ is gitignored and uploaded by hand, a folder per
# screenshot slot plus the product page header and search results images. The simulator's shots go
# in AppStoreScreenshots/raw/, and each page in scripts/app-store/ lays them out as one image.
# Headless Google Chrome draws the pages, which load their fonts from Google Fonts, so rendering
# needs the network. The Duo runs twice, folded and unfolded, which needs idb to set its hinge. Set
# TYPECASK_SCREENSHOT_DUO to use another Duo simulator.
set -eu

cd "$(dirname "$0")/.."

mode=${1:-site}
case $mode in
site)
    phone=${TYPECASK_SCREENSHOT_PHONE:-iPhone 18 Pro}
    duo=""
    out=site/assets/screens
    ;;
app-store | app-store-render)
    # The shots sit inside a device frame in every iPhone image, so the Pro Max's serve both the
    # large and the medium iPhone slots.
    phone=${TYPECASK_SCREENSHOT_PHONE:-iPhone 18 Pro Max}
    duo=${TYPECASK_SCREENSHOT_DUO:-iPhone Duo}
    out=AppStoreScreenshots/raw
    ;;
*)
    echo "usage: scripts/screenshots.sh [app-store | app-store-render]" >&2
    exit 2
    ;;
esac
pad=${TYPECASK_SCREENSHOT_PAD:-iPad Pro 13-inch (M5)}

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

# Draws each page in scripts/app-store/ beside the raw shots, at its CSS size times its scale, which
# multiply out to a size App Store Connect takes, into a folder per screenshot slot. A zoom redraws a
# page drawn for one device at another's size: the iPhone pages at the medium iPhone's 402 x 874, the
# iPad's 917 x 688 at 1376 x 1032. The pages paint an opaque background, so oxipng drops the alpha
# channel, which App Store Connect refuses.
render_store() {
    chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if [ ! -x "$chrome" ]; then
        echo "screenshots.sh: the App Store images need Google Chrome in /Applications." >&2
        exit 1
    fi
    for shot in iphone-samples iphone-detail ipad-gallery duo-outer-samples duo-outer-detail \
        duo-inner-samples duo-inner-detail; do
        if [ ! -f "$out/$shot.png" ]; then
            echo "screenshots.sh: no $out/$shot.png; run scripts/screenshots.sh app-store." >&2
            exit 1
        fi
    done
    find AppStoreScreenshots -mindepth 1 -maxdepth 2 -name '*.png' -not -path '*/raw/*' -delete
    mkdir -p "$work/store"
    cp "$out"/*.png "$work/store/"
    while read -r name page width height scale zoom; do
        png=AppStoreScreenshots/$name.png
        staged=$work/store/$(echo "$name" | tr / -).html
        mkdir -p "$(dirname "$png")"
        sed "s#</head>#<style>body { zoom: $zoom; }</style></head>#" "scripts/app-store/$page.html" > "$staged"
        "$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
            --window-size="$width,$height" --force-device-scale-factor="$scale" \
            --virtual-time-budget=10000 --screenshot="$PWD/$png" "file://$staged" > /dev/null 2>&1
        oxipng -q -o 4 --strip safe "$png"
        size=$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$png" |
            awk '/pixel/ { printf "%s%s", sep, $2; sep = "x" } /hasAlpha: yes/ { printf " with alpha" }')
        if [ "$size" != "$((width * scale))x$((height * scale))" ]; then
            echo "screenshots.sh: $png came out $size, not $((width * scale))x$((height * scale))." >&2
            exit 1
        fi
        echo "screenshots.sh: wrote $png"
    done << 'EOF'
iphone-large/1-free iphone-1-free 440 956 3 1
iphone-large/2-preview iphone-2-preview 440 956 3 1
iphone-large/3-any-app iphone-3-any-app 440 956 3 1
iphone-large/4-styles iphone-4-styles 440 956 3 1
iphone-medium/1-free iphone-1-free 402 874 3 0.913636
iphone-medium/2-preview iphone-2-preview 402 874 3 0.913636
iphone-medium/3-any-app iphone-3-any-app 402 874 3 0.913636
iphone-medium/4-styles iphone-4-styles 402 874 3 0.913636
ipad/1-gallery ipad-1-gallery 1376 1032 2 1.50055
ipad/2-any-app ipad-2-any-app 1376 1032 2 1.50055
duo-outer/1-free duo-outer-1-free 466 678 3 1
duo-outer/2-preview duo-outer-2-preview 466 678 3 1
duo-inner/1-free duo-inner-1-free 951 669 3 1
duo-inner/2-preview duo-inner-2-preview 951 669 3 1
header header 1920 823 2 1
search-results search-results 1920 1280 2 1
EOF
}

if [ "$mode" = app-store-render ]; then
    render_store
    exit 0
fi

# Boots a simulator in the dark appearance with a full status bar at 9:41, and leaves its id in
# $device.
prepare() {
    device=$(udid "$1")
    if [ -z "$device" ]; then
        echo "screenshots.sh: no available simulator named '$1'." >&2
        exit 1
    fi
    devices="$devices $device"
    xcrun simctl boot "$device" 2> /dev/null || true
    xcrun simctl bootstatus "$device" -b > /dev/null
    xcrun simctl ui "$device" appearance dark
    xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiMode active \
        --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
}

prepare "$phone"
phone_id=$device
prepare "$pad"
pad_id=$device
if [ -n "$duo" ]; then
    if ! command -v idb > /dev/null; then
        echo "screenshots.sh: the iPhone Duo's inner display needs idb, to unfold it." >&2
        exit 1
    fi
    # Folding the Duo back with idb leaves its outer display black, or the app drawn small in one
    # corner, until it reboots, so it starts from a fresh boot, which is folded.
    device=$(udid "$duo")
    if [ -n "$device" ]; then
        xcrun simctl shutdown "$device" 2> /dev/null || true
    fi
    prepare "$duo"
    duo_id=$device
fi

echo "screenshots.sh: copying the project without its fonts"
rsync -a --exclude /.git --exclude /.cache --exclude /site --exclude /DerivedData \
    --exclude /Typecask/Fonts.xcassets ./ "$work/src/"

xcodebuild build-for-testing -project "$work/src/Typecask.xcodeproj" -scheme Typecask \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$work/DerivedData" -quiet

mkdir -p "$out"

# One run of SiteScreenshots, into the result bundle named first, with the display second and the
# destinations after.
test_once() {
    result=$1
    display=$2
    shift 2
    TEST_RUNNER_TYPECASK_SCREENSHOT_DISPLAY=$display xcodebuild test-without-building \
        -project "$work/src/Typecask.xcodeproj" -scheme Typecask "$@" \
        -only-testing:TypecaskUITests/SiteScreenshots -derivedDataPath "$work/DerivedData" \
        -resultBundlePath "$result" -quiet
}

# Keeps the failed run's result bundle, which holds a screen recording and the UI hierarchy at the
# failure, prints what failed, and stops.
report_failure() {
    rm -rf Screenshots.xcresult
    mv "$1" Screenshots.xcresult
    xcrun xcresulttool get test-results summary --path Screenshots.xcresult |
        python3 -I -c 'import json, sys
for failure in json.load(sys.stdin).get("testFailures", []):
    print("screenshots.sh: %s: %s" % (failure["testName"], failure["failureText"]), file=sys.stderr)'
    echo "screenshots.sh: Screenshots.xcresult has the details." >&2
    exit 1
}

# Runs SiteScreenshots on the simulators given, after the run's name and the display, and copies the
# screens it attaches into $out. A display of outer or inner tells the tests they're on an iPhone
# Duo, folded or unfolded, and they name the shots for it. A run that fails gets one more try:
# SpringBoard sometimes refuses to launch the test runner ("Busy", "failed preflight checks").
run_tests() {
    run=$1
    display=$2
    shift 2
    if ! test_once "$work/$run.xcresult" "$display" "$@"; then
        echo "screenshots.sh: the $run run failed; trying it again" >&2
        rm -rf "$work/$run.xcresult"
        if ! test_once "$work/$run.xcresult" "$display" "$@"; then
            report_failure "$work/$run.xcresult"
        fi
    fi

    xcrun xcresulttool export attachments --path "$work/$run.xcresult" --output-path "$work/$run" \
        > /dev/null

    # The manifest maps each test's attachments, by the name the test gave them, to the exported
    # file. XCTest adds its own, a UI hierarchy and the like, beside a failure; only the named
    # screens are kept.
    python3 -I - "$work/$run" "$out" << 'EOF'
import json
import re
import shutil
import sys
from pathlib import Path

attachments, out = Path(sys.argv[1]), Path(sys.argv[2])
for test in json.loads((attachments / "manifest.json").read_text()):
    for attachment in test["attachments"]:
        match = re.match(r"((?:iphone|ipad|duo)-[a-z-]+)_", attachment["suggestedHumanReadableName"])
        if not match:
            continue
        name = match[1]
        shutil.copyfile(attachments / attachment["exportedFileName"], out / f"{name}.png")
        print(f"screenshots.sh: wrote {out / name}.png")
EOF
}

run_tests devices "" -destination "id=$phone_id" -destination "id=$pad_id"

# The Duo boots folded, onto its outer display. idb sets the hinge: 180 degrees is flat, which
# moves the app to the inner display. The app takes a moment to move. It's left unfolded; the next
# run reboots it.
if [ -n "$duo" ]; then
    run_tests duo-outer outer -destination "id=$duo_id"
    # A test run leaves idb's companion with a dead connection to the simulator's input, which drops
    # the hinge change without an error, so it starts afresh, and the angle is read back.
    idb kill > /dev/null 2>&1 || true
    idb hinge --udid "$duo_id" 180 > /dev/null
    if [ "$(idb hinge --udid "$duo_id")" != 180.0 ]; then
        echo "screenshots.sh: idb couldn't unfold the iPhone Duo." >&2
        exit 1
    fi
    sleep 2
    run_tests duo-inner inner -destination "id=$duo_id"
fi

# Hugo resizes the site's for the page; this only keeps what's checked in small. App Store Connect
# takes only the device's own sizes, so those stay as they are.
if [ "$mode" = site ]; then
    for png in "$out"/*.png; do
        sips -Z 2000 "$png" > /dev/null
    done
fi
oxipng -q -o 4 --strip safe "$out"/*.png

if [ "$mode" = app-store ]; then
    render_store
fi
