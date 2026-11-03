#!/bin/sh
# Boots an iPad Pro 11-inch (M5) simulator on the iOS runtime that matches the selected Xcode's
# simulator SDK, downloading the runtime and creating the device if the machine lacks them. In CI it
# writes SIMULATOR (the UDID) and DESTINATION (for xcodebuild) to GITHUB_ENV; elsewhere it prints them.
#
#   scripts/boot-simulator.sh
#
# The runtime has to match the SDK: UI tests link Xcode's AppIntentsTesting, which needs symbols only
# its own iOS version has, so on an older runtime the whole test bundle fails to load. GitHub's
# xcode-27 image ships Xcode 27.2 with simulators only for iOS 27.0 and 27.1.
#
# A first boot spends minutes setting itself up, so boot early and wait with
# `xcrun simctl bootstatus "$SIMULATOR" -b` just before the first test.
set -eu

DEVICE="iPad Pro 11-inch (M5)"

sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)

# Prints the runtime's identifier and the device's type. A runtime can be for one device only, as
# iOS-27-2-iPhone19-4 is, so it has to support the device, not just be the SDK's version.
runtime() {
    xcrun simctl list runtimes available -j | python3 -c '
import json, sys
sdk, name = sys.argv[1:]
for runtime in json.load(sys.stdin)["runtimes"]:
    if runtime["platform"] != "iOS" or runtime["version"].split(".")[:2] != sdk.split(".")[:2]:
        continue
    for device_type in runtime["supportedDeviceTypes"]:
        if device_type["name"] == name:
            print(runtime["identifier"], device_type["identifier"])
            sys.exit()' "$sdk" "$DEVICE"
}

found=$(runtime)
if [ -z "$found" ]; then
    echo "No iOS $sdk simulator runtime for $DEVICE; downloading it."
    xcodebuild -downloadPlatform iOS
    found=$(runtime)
    if [ -z "$found" ]; then
        echo "error: still no iOS $sdk simulator runtime for $DEVICE after downloading" >&2
        exit 1
    fi
fi
runtime_id=${found% *}
device_type=${found#* }

udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for device in json.load(sys.stdin)["devices"].get(sys.argv[1], []):
    if device["name"] == sys.argv[2]:
        print(device["udid"])
        break' "$runtime_id" "$DEVICE")
if [ -z "$udid" ]; then
    udid=$(xcrun simctl create "$DEVICE" "$device_type" "$runtime_id")
fi

echo "Booting $DEVICE on $runtime_id ($udid)"
xcrun simctl boot "$udid"

if [ -n "${GITHUB_ENV:-}" ]; then
    echo "SIMULATOR=$udid" >> "$GITHUB_ENV"
    echo "DESTINATION=platform=iOS Simulator,id=$udid" >> "$GITHUB_ENV"
else
    echo "SIMULATOR=$udid"
    echo "DESTINATION=platform=iOS Simulator,id=$udid"
fi
