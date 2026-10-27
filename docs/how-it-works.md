# How Typecask works

## Installing fonts

Fonts ship as On-Demand Resources and are installed with Core Text's font provider API, so they appear
in Settings › General › Fonts and in any app that supports installed fonts. Each cask's fonts are tagged
for On-Demand Resources; installing a cask downloads its tag and registers its fonts.

Apple's replacement for On-Demand Resources, deprecated as of iOS 27, is Background Assets. Fonts
delivered that way can't be installed system-wide, which is why Typecask still uses On-Demand Resources.

Each cask ships its variable font where it has one, which covers every weight in a file or two, and
otherwise the Regular, Italic, Bold and Bold Italic of a single family. Some casks are left out of a
release, or read as "Fonts not included in this build"; [the font pipeline](font-pipeline.md#what-a-release-ships)
explains which and why.

## Fonts iOS already has

A cask whose primary face iOS already ships under the same PostScript name, like Noto Sans Armenian,
reads as "Built into iOS". Registering it fails with a duplicated-name error, and every app has the font
anyway.

## Updates

Each cask records its Homebrew version and its primary face's own version string (`fontVersion`,
name ID 5). Each time the app comes to the foreground it compares that with the installed copy's and offers
Update when they differ, which removes the old fonts and installs the current build's. A cask whose
fonts were removed in Settings meanwhile reads as not installed again.

The system keeps its own copy of an installed font, so fonts survive app updates and reinstalls. A font
installed by an earlier build stays installed when a later one stops shipping it, and can still be
uninstalled.

## Popularity and trending

Homebrew and Google measure different crowds: Homebrew's installs are dominated by Nerd Fonts and
coding faces. So each cask is placed by percentile in each source that has it, Homebrew's yearly
installs and Google Fonts' yearly views (from `fonts.google.com/metadata/stats`), and ranked by the
better of the two.

Trending compares the last 30 days with the yearly rate, among the busiest quarter of each source,
since growth in the long tail is noise.

## Design styles

A Google family takes its design style from Google's category. Other casks take it from the font's
PANOSE data, which most Google families leave empty. A face that declares itself fixed pitch is always
Fixed Width. The Nerd Fonts collection is every cask with Nerd Font glyphs, and its previews include a
row of the icons.

## Apple's fonts

The Apple Fonts collection lists the fonts built into iOS and the ones offered under Settings › General
› Fonts › More Fonts, in the same design styles as the casks. Typecask can't install those: an app can
download one of Apple's fonts for its own use with `CTFontDescriptorMatchFontDescriptorsWithProgressHandler`,
but Settings still offers it afterwards, so only Settings makes it available to every app, and the app
says so.

The app ships previews of them, so the gallery doesn't download each one as it scrolls past. The device
draws built-in families itself; a downloadable one gets a subset of the font cut down to its sample, or
an image where the font's license doesn't allow that.
[The font pipeline](font-pipeline.md#apples-fonts) covers how those are generated.
