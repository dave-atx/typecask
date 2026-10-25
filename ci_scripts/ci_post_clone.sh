#!/bin/sh
# Xcode Cloud runs this after cloning, before resolving dependencies.
#
# Typecask/Fonts.xcassets is generated, not committed — it runs to tens of GB for the whole catalog.
# Catalog.json, Previews/ and Licenses/ are committed, so a release build only has to fetch the casks
# it actually ships. TYPECASK_CASKS picks them; set it as an environment variable on the workflow to
# change the line-up without touching this script.
set -eu

CASKS="${TYPECASK_CASKS:-font-departure-mono-nerd-font font-roboto font-d2coding}"

cd "$CI_PRIMARY_REPOSITORY_PATH"

if ! command -v brew > /dev/null 2>&1; then
    echo "error: Homebrew is required to fetch casks and is not on PATH" >&2
    exit 1
fi

# uv runs build-catalog.py with its pinned fontTools; the Xcode Cloud image doesn't ship it.
if ! command -v uv > /dev/null 2>&1; then
    brew install uv
fi

echo "Building font assets for: $CASKS"
# shellcheck disable=SC2086 -- CASKS is a deliberately word-split list of tokens.
uv run --script scripts/build-catalog.py --assets-only --fonts $CASKS

echo "Fonts.xcassets groups:"
ls Typecask/Fonts.xcassets
