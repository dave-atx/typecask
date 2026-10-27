# Typecask

Install thousands of free fonts on your iPhone and iPad, and use them in any app that supports
installed fonts.

<!-- TODO: the App Store record is 6826936046; link and badge go here once the app is public. -->
[typecask.app](https://typecask.app)

Typecask brings the most popular fonts from [Homebrew](https://brew.sh)'s font casks, and every
family on [Google Fonts](https://fonts.google.com), to iOS and iPadOS. Tap Install, approve the
system prompt, and the font appears in Settings › General › Fonts and in apps like Pages and Keynote.

- **Browse** by design style (Serif, Sans Serif, Fixed Width, Display, Handwriting), or open the
  Nerd Fonts and Apple Fonts collections. Sort by name, popularity or what's trending, and search by
  name.
- **Preview** every font in the gallery before you download anything.
- **Install and uninstall** fonts system-wide. Installed fonts get their own collection.
- **Stay up to date.** When a new release of Typecask carries a newer version of a font you've
  installed, it offers an update.
- **See Apple's own fonts**, both the ones built into iOS and the extra ones Settings can download.

## Requirements

iOS or iPadOS 27 or later, on iPhone or iPad.

## Privacy

Typecask collects no data. It has no accounts or analytics, and makes no network requests
of its own: fonts are downloaded from Apple's App Store servers when you install them.

## Help and feedback

Report a problem, or ask for a font to be added or corrected, in
[GitHub Issues](https://github.com/dave-atx/typecask/issues).

## Fonts and licenses

Every font belongs to its designers and comes with its own license, which you can read on its page in
the app; a font whose license can't be found isn't included. Typecask is not affiliated with Homebrew,
Google or Apple.

The app's source code is licensed under the [Apache License 2.0](LICENSE). The fonts are not covered
by that license; see [NOTICE](NOTICE).

## Contributing

Bug reports, font requests and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) to
build the app and run the checks, and [docs/](docs) for how it works:

- [How it works](docs/how-it-works.md): installing, updates, ranking and Apple's fonts
- [The font pipeline](docs/font-pipeline.md): how the catalog and font assets are built and published
- [Releasing](docs/releasing.md): TestFlight builds and signing
- [The site](docs/site.md): typecask.app, which publishes the shipping build's catalog
