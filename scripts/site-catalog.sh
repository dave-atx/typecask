#!/bin/sh
# Copies the catalog, previews and licenses that the shipping app carries into site/, where Hugo
# reads them.
#
# The site has to describe the build people can install, not main. A fonts release merges into main
# every Monday, and the app that ships it goes out whenever a testflight-N tag is pushed, so main's
# Catalog.json routinely lists fonts no installed copy of the app has. Reading the catalog out of the
# most recent testflight-N tag keeps the site and the app in step. Point RELEASE_TAGS at release-*
# once the App Store, rather than TestFlight, is what people get.
#
# Everything this writes is gitignored. Run it before hugo, locally and in CI.
set -eu

cd "$(dirname "$0")/.."

pattern=${TYPECASK_RELEASE_TAGS:-testflight-*}
tag=${TYPECASK_RELEASE_TAG:-}

if [ -z "$tag" ]; then
    # Version sort, so testflight-10 comes after testflight-9 rather than before it.
    tag=$(git tag --list "$pattern" --sort=v:refname | tail -1)
fi

if [ -z "$tag" ]; then
    # A shallow CI clone carries no tags. Ask the remote for the newest one and fetch that one
    # commit: the whole history is a fonts release of previews every week, and none of it is needed.
    tag=$(git ls-remote --tags --refs origin "$pattern" | sed 's|.*refs/tags/||' | sort -V | tail -1)
    if [ -n "$tag" ]; then
        echo "site-catalog.sh: fetching $tag"
        git fetch --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    fi
fi

if [ -z "$tag" ]; then
    echo "site-catalog.sh: no tag matches '$pattern', here or on the remote." >&2
    exit 1
fi

if ! git rev-parse --verify --quiet "$tag^{commit}" > /dev/null; then
    echo "site-catalog.sh: tag '$tag' isn't in this clone." >&2
    exit 1
fi

echo "site-catalog.sh: building the site from $tag"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# git archive reads the tag's tree, so this works on a checkout of any other revision. Licenses come
# from the same tag as the fonts they cover; the app and the site both have to ship a font's license
# with the font. The icon is scripts/icon.sh's render of AppIcon.icon; tags from before AppIcon.icon
# have only the flat PNG of the old icon set.
icon=docs/icon/default.png
if ! git cat-file -e "$tag:$icon" 2> /dev/null; then
    icon=Typecask/Assets.xcassets/AppIcon.appiconset/icon-1024.png
fi
git archive "$tag" Typecask/Catalog.json Typecask/Previews Licenses "$icon" | tar -x -C "$tmp"

rm -rf site/data/catalog.json site/data/release.json site/static/p site/licenses \
    site/assets/icon.png
mkdir -p site/data site/static site/licenses site/assets

mv "$tmp/Typecask/Catalog.json" site/data/catalog.json
mv "$tmp/Typecask/Previews" site/static/p
mv "$tmp/Licenses"/*.txt site/licenses/
mv "$tmp/$icon" site/assets/icon.png

# release.json is what the footer and the font pages cite, so a visitor can tell which build of the
# app the catalog belongs to.
cat > site/data/release.json << JSON
{
  "tag": "$tag",
  "build": "${tag##*-}",
  "commit": "$(git rev-parse "$tag^{commit}")",
  "date": "$(git log -1 --format=%cs "$tag^{commit}")"
}
JSON

printf 'site-catalog.sh: %s casks, %s previews, %s licenses\n' \
    "$(grep -c '"token"' site/data/catalog.json)" \
    "$(find site/static/p -type f | wc -l | tr -d ' ')" \
    "$(find site/licenses -type f | wc -l | tr -d ' ')"
