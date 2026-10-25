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

## TestFlight

Xcode Cloud builds are triggered by pushing a `testflight-N` tag. `N` becomes the build number, so
`testflight-4` uploads build 4 and TestFlight won't reject it as a duplicate.

The workflow itself lives in App Store Connect rather than this repo — Xcode Cloud has no
workflow-as-code format — so it has to be created once by hand, in Xcode under Product > Xcode Cloud >
Create Workflow, or in App Store Connect under the app's Xcode Cloud tab:

1. **Start Condition:** delete the default branch condition and add *Tag Changes*, with the tag pattern
   `testflight-*`.
2. **Environment:** Xcode 27.2, and set `TYPECASK_CASKS` if the build should ship a line-up other than
   the default in `ci_scripts/ci_post_clone.sh`.
3. **Action:** *Archive* for iOS, with the Deployment Preparation set to *TestFlight (Internal Testing
   Only)* or *TestFlight and App Store*.
4. **Post-Action:** *TestFlight Internal Testing*, pointed at a tester group.

It needs an Apple Developer Program membership, an App Store Connect record for
`org.marquard.Typecask`, `DEVELOPMENT_TEAM` set in the project, and the repository pushed to a host
Xcode Cloud can reach (GitHub, GitLab or Bitbucket).

Both scripts in `ci_scripts/` run automatically. `ci_post_clone.sh` builds `Fonts.xcassets` with
`--assets-only`, because it's generated rather than committed and a full run would download tens of GB;
`ci_pre_xcodebuild.sh` sets the build number from the tag.

### How many fonts a release can ship

Apple caps an app at [1000 asset packs](https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits)
and 70 GB of hosted On-Demand Resources on iOS 18 and later. One tag can produce several packs once
Xcode slices them, so a release can't ship fonts for all 1000 casks in the catalog — `TYPECASK_CASKS`
decides which ones it carries, and the rest show "Fonts not included in this build". Note also that
On-Demand Resources are deprecated as of iOS 27; Background Assets is the replacement, but fonts
delivered through it can't be installed system-wide, which is why this app still uses ODR.

## Checks

```sh
swiftlint --strict
xcrun simctl erase 'iPhone Duo'
xcodebuild test -project Typecask.xcodeproj -scheme Typecask -destination 'platform=iOS Simulator,name=iPhone Duo'
```

The UI test installs a cask, accepting the system consent sheet, and checks it is still installed after a relaunch.
Pick the cask with `TEST_RUNNER_TYPECASK_CASK=<token>`. Erase the simulator first: fonts outlive
`simctl uninstall`, so a cask installed by an earlier run has no Install button.
