# Typecask

A free, open source iPhone and iPad app that installs the 1000 most-installed Homebrew font casks
system-wide.

Fonts ship as On-Demand Resources (one tag per cask) and are installed with Core Text's font provider API, so they
appear in Settings → General → Fonts and in any app that supports installed fonts.

## Building

Requires Xcode 27.2, [uv](https://docs.astral.sh/uv/) and Homebrew.

```sh
# Writes Catalog.json, Previews/ and Licenses/ for every cask, and Fonts.xcassets for the casks named
# here: a static, a variable and a collection font.
./scripts/build-catalog.py --fonts font-departure-mono-nerd-font font-roboto font-d2coding
open Typecask.xcodeproj
```

`--count` sets how many casks to catalog, 1000 by default; Homebrew has about 2,650 font casks with install
data. `--scratch DIR` stages the downloads and Homebrew's own cache somewhere other than the boot disk,
which a full run needs — the top 100 alone are ~2.6 GB. Casks that fail to download, or that no license can
be found for, are skipped with a warning rather than ending the run.

Without `--fonts`, `Fonts.xcassets` holds every font — about 11 GB for 100 casks — and a release build needs
roughly three times that in free disk space. It is generated rather than committed. Debug builds embed the
asset packs in the app so On-Demand Resources work in the simulator without Xcode hosting them.

Each cask's fonts go in their own asset catalog group, which needs its own `Contents.json`: without it
`actool` silently leaves the cask's asset pack empty, the On-Demand Resources tag downloads fine, and
installing then fails with "could not be found in an asset catalog".

Casks whose download contains no license, and whose GitHub repository has none either, are skipped: the fonts can't be
redistributed without one.

## Checks

```sh
swiftlint --strict
xcrun simctl erase 'iPhone Duo'
xcodebuild test -project Typecask.xcodeproj -scheme Typecask -destination 'platform=iOS Simulator,name=iPhone Duo'
```

The UI test installs a cask, accepting the system consent sheet, and checks it is still installed after a relaunch.
Pick the cask with `TEST_RUNNER_TYPECASK_CASK=<token>`. Erase the simulator first: fonts outlive
`simctl uninstall`, so a cask installed by an earlier run has no Install button.
