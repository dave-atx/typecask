#!/bin/sh
# Renders Typecask/AppIcon.icon, the app icon Icon Composer edits, to the flat images for what can't
# use the .icon itself. Rerun it after changing the icon, and check the renders in docs/icon.md.
#
#   scripts/icon.sh
#
# Writes:
#
#   docs/icon/<appearance>.png    each iOS appearance; default.png is 1024 pixels, since
#                                 scripts/site-catalog.sh takes it for the site's og:image
#   Typecask/Assets.xcassets/AboutIcon.imageset/about-icon.png, about-icon-dark.png
#                                 the About screen's copy, 88 points at 3x
#
# The renders are checked in because the site builds on Linux, and an app can't load its own icon as
# an image. ictool comes with Icon Composer, inside Xcode.
set -eu

cd "$(dirname "$0")/.."

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
icon=Typecask/AppIcon.icon
about=Typecask/Assets.xcassets/AboutIcon.imageset

if [ ! -x "$ictool" ]; then
    echo "icon.sh: no ictool at $ictool; is Xcode selected with xcode-select?" >&2
    exit 1
fi

# render <output> <rendition> <points> <scale>
render() {
    rm -f "$1"
    # ictool prints an empty JSON object on success, and doesn't always exit nonzero when it fails.
    "$ictool" "$icon" --export-image --output-file "$1" --platform iOS --rendition "$2" \
        --width "$3" --height "$3" --scale "$4" > /dev/null
    if [ ! -s "$1" ]; then
        echo "icon.sh: ictool wrote nothing for the $2 rendition" >&2
        exit 1
    fi
}

mkdir -p docs/icon
render docs/icon/default.png Default 1024 1
render docs/icon/dark.png Dark 256 1
render docs/icon/tinted-light.png TintedLight 256 1
render docs/icon/tinted-dark.png TintedDark 256 1
render docs/icon/clear-light.png ClearLight 256 1
render docs/icon/clear-dark.png ClearDark 256 1
render "$about/about-icon.png" Default 88 3
render "$about/about-icon-dark.png" Dark 88 3

oxipng -q -o 4 --strip safe docs/icon/*.png "$about"/*.png
echo "icon.sh: rendered $icon to docs/icon/ and $about/"
