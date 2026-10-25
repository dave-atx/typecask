#!/bin/sh
# Builds the fonts a release ships and publishes them as a GitHub release asset, pinned in
# Typecask/FontsAsset.json for ci_scripts/ci_post_clone.sh to fetch.
#
#   scripts/publish-fonts.sh build  [TAG]   build everything from fonts.lock.json, and .cache/TAG.tar.zst
#   scripts/publish-fonts.sh upload [TAG]   attach that archive to a release and write the pin
#
# Two steps so the archive that gets uploaded is the one already built and tried in the simulator.
# TAG defaults to fonts-YYYYMMDD.
#
# build trims heavy niche casks, those over 10 MB costing more than MAX_MB_PER_INSTALL (default 0.1)
# per yearly install; set it empty to ship everything. It rewrites Typecask/Catalog.json, Previews/
# and Licenses/, so commit those with the pin: CI refuses to build when the catalog and the asset
# disagree. The GitHub workflow in .github/workflows/fonts.yml runs both steps.
set -eu

cd "$(dirname "$0")/.."
STEP="${1:-}"
TAG="${2:-fonts-$(date +%Y%m%d)}"
ARCHIVE=".cache/$TAG.tar.zst"
# What the archive holds, by cask: its assets and On-Demand Resources tag. upload compares it with
# Catalog.json, so metadata-only changes like build-catalog.py --refresh don't force a rebuild.
MANIFEST=".cache/$TAG.assets.json"
assets_manifest() {
    python3 -c 'import json, sys
casks = json.load(open("Typecask/Catalog.json"))["casks"]
json.dump({c["token"]: [c["assets"], c.get("pack")] for c in casks if c["assets"]}, sys.stdout, sort_keys=True)'
}
# GitHub refuses release assets of 2 GiB; uploads near the limit are reported to fail, so leave room.
LIMIT=$((1900 * 1024 * 1024))

case "$STEP" in
build)
    set -- build --archive "$ARCHIVE"
    TRIM="${MAX_MB_PER_INSTALL-0.1}"
    if [ -n "$TRIM" ]; then
        set -- "$@" --max-mb-per-install "$TRIM"
    fi
    GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}" uv run --script scripts/build-catalog.py "$@"

    size=$(stat -f%z "$ARCHIVE")
    if [ "$size" -gt "$LIMIT" ]; then
        echo "error: $ARCHIVE is $((size / 1024 / 1024)) MiB, over the $((LIMIT / 1024 / 1024)) MiB a" \
             "single release asset can safely carry. Set BUDGET or MAX_MB_PER_INSTALL to trim it." >&2
        exit 1
    fi
    assets_manifest > "$MANIFEST"
    echo "Built $ARCHIVE ($((size / 1024 / 1024)) MiB). Try it in the simulator, then: $0 upload $TAG"
    ;;
upload)
    if [ ! -f "$ARCHIVE" ]; then
        echo "error: no $ARCHIVE; run $0 build $TAG first" >&2
        exit 1
    fi
    # The pin is only true if Catalog.json still describes this archive's fonts.
    if [ ! -f "$MANIFEST" ] || [ "$(assets_manifest)" != "$(cat "$MANIFEST")" ]; then
        echo "error: Typecask/Catalog.json no longer matches the fonts in $ARCHIVE; rebuild it" >&2
        exit 1
    fi
    size=$(stat -f%z "$ARCHIVE")
    sha=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
    casks=$(python3 -c 'import json; print(sum(1 for c in json.load(open("Typecask/Catalog.json"))["casks"] if c["assets"]))')
    gh release create "$TAG" "$ARCHIVE" --title "Fonts $TAG" \
        --notes "Typecask/Fonts.xcassets for $casks casks, built from Catalog.json. Fetched by ci_scripts/ci_post_clone.sh."
    url=$(gh release view "$TAG" --json assets --jq '.assets[0].apiUrl')

    cat > Typecask/FontsAsset.json <<EOF
{
  "tag": "$TAG",
  "url": "$url",
  "sha256": "$sha",
  "bytes": $size,
  "casks": $casks
}
EOF
    echo "Pinned $TAG ($((size / 1024 / 1024)) MiB, $casks casks)." \
         "Commit Typecask/Catalog.json, Typecask/Previews and Typecask/FontsAsset.json together."
    ;;
*)
    echo "usage: $0 build|upload [TAG]" >&2
    exit 2
    ;;
esac
