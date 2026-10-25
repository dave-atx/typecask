#!/bin/sh
# Xcode Cloud runs this after cloning, before resolving dependencies.
#
# Typecask/Fonts.xcassets is generated, not committed, and the fonts in it have to be in the archive
# for On-Demand Resources to host them. scripts/publish-fonts.sh builds it once, attaches it to a
# GitHub release and pins that release in Typecask/FontsAsset.json; this fetches exactly that file,
# so CI pays for one download instead of downloading and subsetting every cask.
#
# Without a pin, it falls back to building a few casks from fonts.lock.json. TYPECASK_CASKS picks them.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

# Signing.xcconfig leaves the team to a local file, which isn't committed; Xcode Cloud names its own.
if [ -n "${CI_TEAM_ID:-}" ] && [ ! -f Signing.local.xcconfig ]; then
    echo "DEVELOPMENT_TEAM = $CI_TEAM_ID" > Signing.local.xcconfig
fi
PIN=Typecask/FontsAsset.json

if [ -f "$PIN" ]; then
    url=$(plutil -extract url raw -o - "$PIN")
    sha=$(plutil -extract sha256 raw -o - "$PIN")
    archive="${TMPDIR:-/tmp}/typecask-fonts.tar.zst"

    echo "Fetching $url"
    # The API asset URL serves the file itself with this Accept header; a token is only needed while
    # the repository is private.
    if [ -n "${TYPECASK_GITHUB_TOKEN:-}" ]; then
        curl -fL --retry 3 -H "Accept: application/octet-stream" \
            -H "Authorization: Bearer $TYPECASK_GITHUB_TOKEN" -o "$archive" "$url"
    else
        curl -fL --retry 3 -H "Accept: application/octet-stream" -o "$archive" "$url"
    fi
    echo "$sha  $archive" | shasum -a 256 -c -

    rm -rf Typecask/Fonts.xcassets
    # libarchive reads zstd itself, so this needs nothing installed.
    tar --zstd -xf "$archive" -C Typecask

    # Catalog.json and the asset are published together. If they've drifted, casks would offer an
    # Install button for fonts the build doesn't carry, so stop here instead.
    python3 - << 'PY'
import json, pathlib, sys
catalog = json.loads(pathlib.Path("Typecask/Catalog.json").read_text())
expected = {cask["token"] for cask in catalog["casks"] if cask["assets"]}
found = {path.name for path in pathlib.Path("Typecask/Fonts.xcassets").iterdir() if path.is_dir()}
if expected != found:
    sys.exit(f"Fonts.xcassets doesn't match Catalog.json: {len(expected - found)} casks missing, "
             f"{len(found - expected)} unexpected. Rerun scripts/publish-fonts.sh and commit both.")
print(f"{len(found)} casks of fonts, matching Catalog.json")
PY
    exit 0
fi

CASKS="${TYPECASK_CASKS:-font-departure-mono-nerd-font font-roboto font-d2coding}"

# uv runs build-catalog.py with its pinned fontTools; the Xcode Cloud image doesn't ship it.
if ! command -v uv > /dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    PATH="$HOME/.local/bin:$PATH"
fi

echo "No $PIN; building font assets for: $CASKS"
# shellcheck disable=SC2086 # CASKS is a deliberately word-split list of tokens.
uv run --script scripts/build-catalog.py build --fonts $CASKS

echo "Fonts.xcassets groups:"
ls Typecask/Fonts.xcassets
