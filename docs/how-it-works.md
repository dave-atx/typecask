# How Typecask works

## Installing fonts

Fonts ship as On-Demand Resources and are installed with Core Text's font provider API, so they appear
in Settings › General › Fonts and in any app that supports installed fonts. Each cask's fonts are tagged
for On-Demand Resources; installing a cask downloads its tag and registers its fonts.

Apple's replacement for On-Demand Resources, deprecated as of iOS 27, is Background Assets. Fonts
delivered that way can't be installed system-wide, which is why Typecask still uses On-Demand Resources.

Each cask ships its variable font where it has one, which covers every weight in a file or two, and
otherwise the Regular, Italic, Bold and Bold Italic of a single family. Some casks are left out of a
release; [the font pipeline](font-pipeline.md#what-a-release-ships) explains which and why.

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
better of the two, so the two sources' leaders interleave. The app and the site show the rank, "#12",
rather than either source's count. Averaging the two instead fills the top with Nerd Fonts: nearly every
Google family is also a cask, and gets averaged with its weaker Homebrew showing, while a cask Google
doesn't have is judged on Homebrew alone.

Trending compares the last 30 days with the yearly rate, among the busiest quarter of each source,
since growth in the long tail is noise.

Recently Updated sorts by the date each cask's source was published, which `lock` records
([the font pipeline](font-pipeline.md#lock) says where it comes from); the page shows it as Updated. A
paired card sorts by the newer of its two casks, and casks without a date come last.

## Links

`typecask://font/TOKEN` opens a font's page, and so does its typecask.app page's URL, which the site's
Smart App Banner hands the app when it opens it (`DeepLink`). The token may leave off its `font-`. The
site's pages aren't universal links: those need the Associated Domains entitlement in the provisioning
profile, and an `apple-app-site-association` file on the site, and a link on typecask.app to itself would
still open in Safari.

Share, in the bar of every page the site has a counterpart for, sends that page's typecask.app link
(`SiteLink`): a font, an article or Start Here, a foundry or designer and their indexes, All Fonts, a design
style, and Nerd Fonts. Installed, Ligatures, Legibility, Symbols, the holidays, and Apple's fonts have no page
on the site, so no Share. A maker's page on the site is at `Maker.slug(of:)`, the slug the articles link it
by, which the site sets for each one (`site/layouts/_partials/maker-slug.html`); change one and change the
other.

## Install on Mac

iOS can't install a font on a Mac, but it can send one. Install on Mac, with a font's buttons, gives the
share sheet a zip of the cask's files and its license (`FontArchive`), made only once a destination is
picked: AirDropped to a Mac, it opens to a folder whose fonts Font Book installs. The files are this build's
copies, from the cask's On-Demand Resources tag, named after each file's first face, with the extension
from the file's first bytes. A Mac goes by the extension.

## A font's page

A font's page is laid out like a printed type specimen: a masthead of a few of the face's letters, large,
with its name, Install, and its facts, then a type tester, the sample at a size you pick. The size carries
over to every font's page, and until it's moved it follows the text size.

The full specimen needs the cask's full fonts, not the preview's few dozen glyphs, so it's opt-in, or there
straight away for an installed cask. It adds every style, a variable font's named instances among them (read
from its `fvar` table); passages at reading sizes, from the Universal Declaration of Human Rights; the
OpenType features the face has; the character set by kind, with the one tapped shown large and its name; and
the languages whose every letter the face has, by CLDR's exemplar characters (`Typecask/Languages.json`).
A feature is listed only where shaping its text with it on draws different glyphs, and not blanks, so a
feature that does nothing to that text is left out (`SpecimenFeatures.swift`).

The fonts come from `TryOutLoader`: an installed cask's are on the device already, and anything else
downloads its On-Demand Resources tag, as Install does, but reads the fonts from its data assets without
installing them, so they're the app's alone. A family built into iOS gets the same page from its faces on
the device. One from Settings' More Fonts keeps its preview alone, since resolving it through Core Text
downloads it.

## Try It Out

Try It Out is an editor set in the cask's full fonts. It opens from the page's Try It Out button, or from
any part of the specimen, zooming from what was tapped and set up for it: the sample, a style, a feature
turned on, or a character. It shares the page's fonts, so they download once. The style and size are
always to hand, with a chip for each OpenType feature and for ligatures. Alignment, line height, and a
variable face's axes are under Adjust, a side panel on iPad and a half sheet on iPhone.

Its text is made on the device from the font's own character set (`TryOutText`), so it never shows a line
the face can't draw: the sample, then the coding sequences and the fi and fl words the face really joins
(each shaped with its ligatures on and off, and kept where the glyphs differ), a line for each feature,
the alphabet, figures, punctuation, accented Latin, Cyrillic, and Greek where the face has most of each
line, currency and math signs, box drawing for a face with all of it, a run of each Nerd Fonts icon set for
a Nerd Font, and up to 240 letters of any other script.

## Design styles

A Google family takes its design style from Google's category. Other casks take it from the font's
PANOSE data, which most Google families leave empty. A face that declares itself fixed pitch is always
Fixed Width. The Nerd Fonts collection is every cask with Nerd Font glyphs, and its previews include a
row of the icons.

The sidebar's counts are of the fonts covering the writing systems picked in the filter, so they match
what each collection then shows.

## Holidays

The Holidays collections, Lunar New Year, Valentine's Day, Halloween, Diwali and Christmas, come from the
seasonal tags google/fonts gives its families in `tags/all/families.csv`, each scored 0 - 100. `lock`
records a family's tags at the locked commit, and `build` keeps those scoring `HOLIDAY_MIN_SCORE` or
more. Google tags only its own families, so `HOLIDAY_CASKS` adds casks from elsewhere by hand.

## Legibility

The Legibility collection is the fonts their designers made to be easy to read, for low vision,
dyslexia or beginning readers, picked by hand in `LEGIBLE_CASKS`. `build` marks each `legible` in
`Catalog.json`, and warns about any it names that the catalog doesn't have, as it does for
`HOLIDAY_CASKS`. Like the holidays, the list is applied as `build` assembles the catalog, so changing it
needs no `PIPELINE_VERSION` bump; the next fonts build carries it.

## Nerd Font versions

A cask and its Nerd Font version share one card and one page: Fira Code's page offers Fira Code Nerd Font
in a section of its own, with its own Install, version, size and license. `build` pairs them as it
assembles the catalog (`pair_nerd_fonts()`), marking the plain cask's `nerdFont` with the other's token:
a Nerd Font cask is one with `glyphs`, and it's matched by the original name Nerd Fonts gives in
parentheses ("CaskaydiaCove Nerd Font (Cascadia Code)"), else by its token without `-nerd-font` or `-nf`.
`NERD_FONT_PAIRS` settles the rest by hand, such as which of Cascadia Code's two Nerd Font builds pairs,
and a plain cask with two candidates pairs with neither, with a warning. Nerd Fonts renames the families
it patches, so the two install side by side; the card shows one Installed badge if either is installed,
and its menu offers both. The Nerd Fonts collection lists the pair, search finds it by either name, and
it ranks as the more popular of the two.

Each cask is still its own entry everywhere else: Shortcuts and Siri find both, and opening or
installing the Nerd Font version from a shortcut shows the shared page. The site keeps a page for each.

## Ligatures

The Ligatures collection is the coding fonts that draw sequences like `->` and `!=` as single symbols,
which `build` finds by shaping them with HarfBuzz both ways (see the
[font pipeline](font-pipeline.md#build)) and marks `ligatures`. Their cards say "Ligatures", their
sample shows the sequences, and their page has a switch that turns the ligatures off in the samples, by
the font descriptor's feature settings, to show the characters underneath.

## Symbols

The Symbols collection is fonts typed on an ordinary keyboard that draw something other than letters:
Redacted's scribbles and Flow's blocks for mockups, Yarndings' knitting symbols, and the Charted fonts'
letters as stitches on a grid. They're picked by hand in `SYMBOL_CASKS`, which `build` marks `symbols`
in `Catalog.json`, as `LEGIBLE_CASKS` does `legible`. Google classifies most of them as Symbols, which
otherwise keeps a family out of the line-up: barcodes, Linefont's charts and Noto's music and symbol
fonts have nothing to set text in, and iOS has no way to type most of the latter, so they don't ship.

## Apple's fonts

The Apple Fonts collection lists the fonts built into iOS and the ones offered under Settings › General
› Fonts › More Fonts, in the same design styles as the casks. Typecask can't install those: an app can
download one of Apple's fonts for its own use with `CTFontDescriptorMatchFontDescriptorsWithProgressHandler`,
but Settings still offers it afterwards, so only Settings makes it available to every app, and the app
says so.

The app ships previews of them, so the gallery doesn't download each one as it scrolls past. The device
draws built-in families itself, and their pages have the full specimen and Try It Out; a downloadable one
gets a subset of the font cut down to its sample, or an image where the font's license doesn't allow that.
[The font pipeline](font-pipeline.md#apples-fonts) covers how those are generated.
