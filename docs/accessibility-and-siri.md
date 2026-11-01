# Accessibility and Siri

## Accessibility

The App Store's accessibility label can claim VoiceOver, Voice Control, Larger Text, Dark Interface,
Differentiate Without Color Alone, Sufficient Contrast and Reduced Motion. Captions and Audio
Descriptions don't apply: the app has no audio or video. Everything below is checked in the simulator;
VoiceOver's own speech and focus still need a pass on a device.

### VoiceOver and Voice Control

A gallery card or sample row reads as the font's name, with its status ("Installed", "Update
available", "Built into iOS") as the value, and its design style, popularity rank and Nerd Fonts icons
as custom content, a swipe away. Left to the link, VoiceOver read the whole sample line, every
bracket of it, ahead of the name. Voice Control answers to the name. `galleryItemAccessibility(_:)` in
`GalleryGrid.swift` does this for both the grid and the sample list.

The sort button looks the same whatever the order, as Apple's do, and reads it to VoiceOver from its
label, "Sort By, Trending": a toolbar button drops an accessibility value. Voice Control still answers
to "Sort By".

A card or row also offers Install, Update or Uninstall, and the homepage, without opening the font's
page: as VoiceOver and Voice Control actions, and in a menu on a long press (`caskActions(_:)` in
`InstallActions.swift`).

A font's page reads its sample once; the smaller copy under it is hidden. When an install, update or
uninstall ends, VoiceOver's focus moves to the button that replaced the one tapped, and
`FontInstaller.run(_:on:)` announces how it ended, including any error, at high priority so focus
returning from the consent sheet doesn't cut it off. The app's own controls all go through `run`.
Installs from a shortcut don't announce: Siri's answer says how it went.

### Text size

At the accessibility sizes:

- A card's name takes up to three lines rather than one.
- A sample row puts its rank under the name rather than beside it.
- A font's page stacks each detail's value under its label (`DetailRowStyle`), and its buttons under
  each other.
- The sidebar drops its counts, which in its fixed width broke "All Fonts" into "A ll Font s".

A font's page has a slider for the sample's size, 12 to 144 points, so someone can judge a face at
the size they'd read it. It follows the text size until it's moved, then keeps that size for every
font (`specimenSize` in user defaults).

### Color and contrast

Status is never color alone: "Installed", "Built into iOS" and errors are text, with only the icon
colored. The colors that do carry meaning are in `Assets.xcassets`, each with dark and Increase
Contrast variants:

| Color | Used for | Light, on a card |
|---|---|---|
| `InstalledBadge` | A card's installed checkmark, the page's Installed icon | 3.9:1 |
| `UpdateBadge` | A card's update arrow | 4.7:1 |
| `CaptionText` | A card's or row's rank, and "Built In" | 5.2:1 |

The system's green and orange are about 2:1 on white, where an icon needs 3:1, and its secondary gray
is 3.3:1 on a card, where a caption needs 4.5:1. Its red is 3.5:1, so an error's text stays gray and
only its icon is red.

The Install and Homepage buttons are iOS's glass buttons in the system blue, which the audit fails on
contrast. Passing would mean a darker tint for the whole app.

### Motion

A card shrinks slightly when pressed, except with Reduce Motion on.

### The Legibility collection

The sidebar's Legibility collection lists fonts their designers made to be easy to read: Atkinson
Hyperlegible, Lexend and Readex Pro, OpenDyslexic, Andika, B612, Intel One Mono and a few more. They're
picked by hand, in `LEGIBLE_CASKS` in `scripts/build-catalog.py`, which marks each in `Catalog.json` as
`legible`; see [how it works](how-it-works.md#legibility).

### Keyboard

On iPad the File menu has Install (or Update, when there is one), on ⌘D, and Uninstall, for the font
whose page is showing (`TypecaskCommands.swift`). The page publishes its font with
`focusedSceneValue`, and SwiftUI enables the items from it and the font's status.

iPadOS gets in the way of the obvious shortcuts:

- It swallows ⌘I (Italic) and ⌘⌫ without a word, which is why Install is ⌘D and Uninstall has none.
- Its Find holds ⌘F. A command of the app's own on ⌘F clashes with it, which leaves both undefined,
  and SwiftUI's search field doesn't answer Find, so there's no shortcut to search. In a SwiftUI app
  the app delegate's `buildMenu(with:)` isn't called, so Find can't be removed either.
- Clashes show up in the app's log as "Conflicting keyboard shortcut". Check for them after adding one.

### The accessibility audit

`AccessibilityAuditTests` runs Xcode's accessibility audit over the gallery, the sample list and a
font's page, at the default text size and the largest. It passes over what iOS draws itself, the
sidebar and the glass buttons, and over truncation the app does on purpose: specimens and names cut to a
few lines, whose full text VoiceOver reads or the page shows. A specimen is drawn in its own font, so a
thin face measures low contrast whatever its color, and that's passed over too. Anything else fails, and
the test prints the element. CI doesn't run it:

```sh
xcodebuild test -project Typecask.xcodeproj -scheme Typecask \
    -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
    -only-testing:TypecaskUITests/AccessibilityAuditTests
```

## Siri, Shortcuts and Spotlight

Three intents, all in `InstallFontIntent.swift`, each with App Shortcuts phrases, so they work from Siri
and Spotlight with nothing set up, and as actions in the Shortcuts app:

| Intent | Phrases | Does |
|---|---|---|
| `InstallFontIntent` | "Install Lexend with Typecask", "Install a font with Typecask", "Install this font with Typecask" | Opens the font's page and installs it; with no font named, the one on screen |
| `OpenFontIntent` | "Show Lexend in Typecask", "Open Lexend in Typecask", "Show a font in Typecask" | Opens the font's page |
| `SearchFontsIntent` | "Search Typecask", "Search for fonts in Typecask" | Searches the whole gallery |

`OpenFontIntent` adopts the `system.open` schema and `SearchFontsIntent` adopts `system.searchInApp`
(`system.search` is deprecated in iOS 27), which offers them to Apple Intelligence beyond their phrases.

Saved shortcuts store an intent by its type name and a font by its token, and Siri listens for the
phrases. Renaming an intent, changing what a font's ID is, or rewording a phrase breaks them; add
phrases rather than reword them.

### Fonts

A font is a `FontEntity`, identified by its cask's token, with its name as a property. Its query
matches every word of what's said, in any order, against the name and token, ignores "font" ("the
Lexend font"), and puts an exact name first, so "Lexend" finds Lexend ahead of Lexend Deca. Siri and
Shortcuts suggest the 200 most popular. Each suggestion becomes a spoken phrase for every phrase that
names a font, three of them, and an app gets about a thousand per language; "Install a font" and "Show
a font" reach the rest by name.

A font's page tells Siri and Apple Intelligence which font it shows (`appEntityIdentifier`). That isn't
enough for a bare "install this font": Siri sends a request to an app's own intent only through a
phrase that names the app, or through one of Apple's schemas, and none covers installing. Without the
app's name, Siri answers on its own, telling you to tap Install. So the install intent's font is
optional, and with none given it installs the font whose page is showing, asking only when no page is:
"Install this font with Typecask".

### Installing

The install intent brings the app forward: the system's consent sheet for installing fonts needs it on
screen, and On-Demand Resources belong to the app, not an extension. It opens the font's page, closing
the About sheet if it's open, so the download shows. It waits for the launch's scan of installed fonts
first, since a shortcut can launch the app, and until then every font reads as not installed. A font
already installed or built into iOS is reported rather than installed again. Siri's answer shows the
font's sample line, so you can see it got the font you asked for.

The installer and the gallery model are made in `TypecaskApp.init` and registered as the intents'
dependencies there, because a shortcut can run before any view appears.

### Spotlight

Every font is in Spotlight, found by its name, token, design style, designers and Google's
description. The app indexes the catalog in the background at launch, once per build of it: the index
is stamped in user defaults (`spotlightIndexedCatalog`) with the build number, the catalog's date and
its count of fonts. Each indexing replaces what was there, so fonts a release dropped don't linger.
`FontEntityQuery` is also an `IndexedEntityQuery`, so the system can ask for the index again.

### Home Screen quick actions

A long press on the app's icon offers Search Fonts, Installed, Trending (All Fonts sorted by trending),
and the font whose page was last open, by name (`QuickActions.swift`). They're set in code each launch,
because the project generates its Info.plist from build settings, which can't hold a list; so on a
fresh install they appear once the app has run. SwiftUI has no way to receive one, so the app delegate
gives each scene a `QuickActionSceneDelegate`, which handles an action that launched the app as well as
one that brought it forward.

### Testing

`ShortcutTests` and `InstallTests` use `AppIntentsTesting`, which runs intents and queries against the
installed app as Siri and Shortcuts do. They cover the query's matching and suggestions, Open Font over
the About sheet and the page's annotation, Search Fonts, finding a font through Spotlight, and
installing through the shortcut, consent sheet and all. `testShortcutInstallsCask` needs its cask in
the debug build's fonts, like the rest of `InstallTests`; see [CONTRIBUTING.md](../CONTRIBUTING.md).

`QuickActionTests` long-presses the icon on the Home Screen and checks Installed, Search Fonts and the last
font, that one from a cold launch. Each takes over two minutes: XCUITest waits a minute, twice, for
SpringBoard to settle, which it never reports.

Not covered: picking a font in the home screen's Spotlight, how Siri's answer looks, and the Trending
quick action.
