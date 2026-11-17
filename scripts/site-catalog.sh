#!/bin/sh
# Copies the catalog, previews and licenses that the shipping app carries into site/, where Hugo
# reads them, with that version's release notes.
#
# The site has to describe the app people can install, not main, nor the newest TestFlight build. A
# fonts release merges into main every Monday and TestFlight builds go out whenever a testflight-N tag
# is pushed, but the App Store serves the version Apple last released. So each version submitted for
# review gets a release-VERSION tag on the commit its build came from, and this asks Apple's lookup API
# which version is live and builds from that version's tag: new fonts, What's New and anything gated on
# the version go live with the release, on the next site build after it. If the lookup fails, or the
# live version has no tag, the newest release-* tag stands in.
#
# Everything this writes is gitignored. Run it before hugo, locally and in CI. TYPECASK_RELEASE_TAG
# builds from a particular tag, as for a look at an unreleased version.
set -eu

cd "$(dirname "$0")/.."

APP_ID=6826936046
pattern=${TYPECASK_RELEASE_TAGS:-release-*}
tag=${TYPECASK_RELEASE_TAG:-}

# Has the tag, fetching just its commit when the clone hasn't: a shallow CI clone carries no tags, and
# the whole history is a fonts release of previews every week, none of which is needed.
have_tag() {
    if git rev-parse --verify --quiet "$1^{commit}" > /dev/null; then
        return 0
    fi
    if git ls-remote --exit-code --tags --refs origin "$1" > /dev/null 2>&1; then
        echo "site-catalog.sh: fetching $1"
        git fetch -q --depth 1 origin "refs/tags/$1:refs/tags/$1"
        return 0
    fi
    return 1
}

if [ -z "$tag" ] && [ "$pattern" = "release-*" ]; then
    live=$(curl -fsS --max-time 20 "https://itunes.apple.com/lookup?id=$APP_ID&country=us" 2> /dev/null |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["results"][0]["version"])' 2> /dev/null || true)
    if [ -n "$live" ] && have_tag "release-$live"; then
        tag="release-$live"
        echo "site-catalog.sh: the App Store has $live"
    else
        echo "site-catalog.sh: no tag for the App Store's version (${live:-lookup failed}); using the newest" >&2
    fi
fi

if [ -z "$tag" ]; then
    # Version sort, so release-1.10 comes after release-1.9 rather than before it.
    tag=$(git tag --list "$pattern" --sort=v:refname | tail -1)
fi

if [ -z "$tag" ]; then
    tag=$(git ls-remote --tags --refs origin "$pattern" | sed 's|.*refs/tags/||' | sort -V | tail -1)
    if [ -n "$tag" ]; then
        have_tag "$tag"
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

rm -rf site/data/catalog.json site/data/release.json site/data/notes.json site/data/webfonts.json \
    site/static/release.json \
    site/static/p site/licenses \
    site/assets/icon.png
mkdir -p site/data site/static site/licenses site/assets

mv "$tmp/Typecask/Catalog.json" site/data/catalog.json
mv "$tmp/Typecask/Previews" site/static/p
mv "$tmp/Licenses"/*.txt site/licenses/
mv "$tmp/$icon" site/assets/icon.png

# release.json is what the footer cites, so a visitor can tell which version of the app the catalog
# belongs to, and what pages gated on a version (deep links) compare with. The build is the
# testflight-N tag on the same commit, where there is one. fontsTag names the web fonts on R2 that
# match these fonts, for Try It Out.
commit=$(git rev-parse "$tag^{commit}")
version=$(git show "$tag:Typecask.xcodeproj/project.xcproj" | sed -n 's/.*"MARKETING_VERSION": "\([^"]*\)".*/\1/p' | head -1)
build=$(git ls-remote --tags --refs origin 'testflight-*' | awk -v commit="$commit" '$1 == commit { sub(".*testflight-", ""); print }' | sort -n | tail -1)
fonts_tag=$(git show "$tag:Typecask/FontsAsset.json" 2> /dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag"])' 2> /dev/null || true)
cat > site/data/release.json << JSON
{
  "tag": "$tag",
  "version": "$version",
  "build": "$build",
  "fontsTag": "$fonts_tag",
  "commit": "$commit",
  "date": "$(git log -1 --format=%cs "$commit")"
}
JSON

# Try It Out's web fonts: the manifest scripts/web-fonts.py put on R2 for this version's fonts release.
# Without one, as before the Web Fonts workflow has run on it, the pages leave Try It Out out.
if [ -n "$fonts_tag" ] && curl -fsS --max-time 60 -o site/data/webfonts.json \
    "https://fonts.typecask.app/manifests/$fonts_tag.json" 2> /dev/null; then
    echo "site-catalog.sh: web fonts from $fonts_tag"
else
    echo '{}' > site/data/webfonts.json
    echo "site-catalog.sh: no web fonts for ${fonts_tag:-this tag}; Try It Out is left out" >&2
fi

# Served too, as typecask.app/release.json, so the Site workflow can tell when a deploy moves the site to
# a new version.
cp site/data/release.json site/static/release.json

# What's New: the notes of every version up to the tag's, as main has them now, so a line can be fixed
# after a release; the fonts each counts are the tag's.
python3 scripts/release-notes.py --site "$tag" > site/data/notes.json

printf 'site-catalog.sh: %s casks, %s previews, %s licenses\n' \
    "$(grep -c '"token"' site/data/catalog.json)" \
    "$(find site/static/p -type f | wc -l | tr -d ' ')" \
    "$(find site/licenses -type f | wc -l | tr -d ' ')"
