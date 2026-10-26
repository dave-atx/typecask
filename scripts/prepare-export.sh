#!/bin/sh
# Installs the App Store provisioning profile and writes the ExportOptions.plist that matches it.
#
#   scripts/prepare-export.sh PROFILE OUT_PLIST
#
# Export signs manually, naming the Apple Distribution certificate and this profile, because
# automatic signing with an App Store Connect API key looks for cloud-managed distribution
# certificates instead and an API key has no access to those: testflight-4 archived with a
# development certificate the key minted on the spot, then failed to export at all.
#
# Everything is checked here because xcodebuild resolves signing at the very end of an export, once
# it has spent the better part of an hour staging several GB of asset packs. An unusable certificate
# or profile otherwise surfaces as late as it possibly can.
#
# TEAM_ID, if set, has to match the profile's team. KEYCHAIN names the keychain holding the identity.
set -eu

cd "$(dirname "$0")/.."

PROFILE="${1:?usage: $0 PROFILE OUT_PLIST}"
OUT="${2:?usage: $0 PROFILE OUT_PLIST}"

decoded=$(mktemp -t typecask-profile)
trap 'rm -f "$decoded"' EXIT

# A .mobileprovision is a CMS-signed property list.
security cms -D -i "$PROFILE" -o "$decoded"

name=$(plutil -extract Name raw -o - "$decoded")
uuid=$(plutil -extract UUID raw -o - "$decoded")
team=$(plutil -extract TeamIdentifier.0 raw -o - "$decoded")
expires=$(plutil -extract ExpirationDate raw -o - "$decoded")
# TEAMID.bundle.id, or TEAMID.* for a wildcard profile, which can't carry our entitlements.
app_id=$(plutil -extract Entitlements.application-identifier raw -o - "$decoded")
bundle=${app_id#"$team".}

echo "Profile: $name"
echo "UUID:    $uuid"
echo "Bundle:  $bundle"
echo "Team:    $team"
echo "Expires: $expires"

if [ "$bundle" = "$app_id" ]; then
    echo "error: application-identifier '$app_id' doesn't begin with team '$team'" >&2
    exit 1
fi

case "$bundle" in
*'*')
    echo "error: '$bundle' is a wildcard profile, which can't carry the app's entitlements." >&2
    echo "       Make an App Store profile for the explicit App ID instead." >&2
    exit 1
    ;;
esac

if [ -n "${TEAM_ID:-}" ] && [ "$team" != "$TEAM_ID" ]; then
    echo "error: profile is for team '$team', but APPLE_TEAM_ID is '$TEAM_ID'." >&2
    exit 1
fi

# The bundle identifier the project actually builds. project.xcproj is JSON with trailing commas, so
# it's matched rather than parsed, as in set-build-number.sh.
if ! grep -q "\"PRODUCT_BUNDLE_IDENTIFIER\": \"$bundle\"" Typecask.xcodeproj/project.xcproj; then
    echo "error: nothing in the project builds '$bundle'. Wrong profile for this app." >&2
    exit 1
fi

EXPIRES="$expires" python3 - << 'PY'
import os
import sys
from datetime import datetime, timezone

# plutil prints a date as ISO 8601 in UTC.
expires = datetime.strptime(os.environ["EXPIRES"], "%Y-%m-%dT%H:%M:%SZ").replace(
    tzinfo=timezone.utc
)
left = expires - datetime.now(timezone.utc)
if left.total_seconds() <= 0:
    sys.exit(f"error: the profile expired {-left.days} days ago. Download a new one.")
print(f"{left.days} days before the profile expires")
PY

# A distribution identity has to be in the keychain for the manual signing below to find one.
identities=$(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"})
case "$identities" in
*"Apple Distribution"*) ;;
*)
    echo "error: no Apple Distribution identity to export with. The keychain holds:" >&2
    echo "$identities" >&2
    exit 1
    ;;
esac

install_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$install_dir"
cp "$decoded" "$install_dir/$uuid.mobileprovision"
echo "Installed to $install_dir/$uuid.mobileprovision"

cat > "$OUT" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$team</string>
  <key>uploadSymbols</key><true/>
  <!-- set-build-number.sh already wrote it; letting Xcode choose would ignore the tag. -->
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$bundle</key><string>$uuid</string>
  </dict>
</dict>
</plist>
PLIST

echo "Wrote $OUT"
plutil -lint "$OUT"
