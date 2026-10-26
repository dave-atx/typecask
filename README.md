# Typecask

A free, open source iPhone and iPad app that installs popular Homebrew font casks system-wide: the
most-installed casks, plus every Google Fonts family.

Fonts ship as On-Demand Resources and are installed with Core Text's font provider API, so they appear in
Settings → General → Fonts and in any app that supports installed fonts.

Installed casks can be uninstalled again, and have their own collection. A cask whose primary face iOS
already ships under the same PostScript name, like Noto Sans Armenian, reads as built in: registering it
fails with a duplicated-name error, and every app has the font anyway. Apart from the design styles
there's a Nerd Fonts collection, whose previews include a row of the icons.

The gallery sorts by name, popularity or trend. Homebrew and Google measure different crowds,
Homebrew's installs dominated by Nerd Fonts and coding faces, so each cask is placed by percentile in
each source that has it, Homebrew's yearly installs and Google Fonts' yearly views from
`fonts.google.com/metadata/stats`, and ranked by the better. Trending is the last 30 days against the
yearly rate, among the busiest quarter of each source, since growth in the long tail is noise.

Each cask records its Homebrew version, and its primary face's own version string (`fontVersion`, name
ID 5). At launch the app compares that with the installed copy's and offers Update when they differ,
which removes the old fonts and installs this build's. A font installed by an earlier build stays
installed when a later one stops shipping it, since the system keeps its own copy, and can still be
uninstalled.

It also lists Apple's own fonts, alongside the casks and in the same design styles: the ones built into
iOS, and the ones offered under Settings › General › Fonts › More Fonts. It can't install those: an app
can download one of Apple's fonts for its own use with `CTFontDescriptorMatchFontDescriptorsWithProgressHandler`,
but Settings still offers it afterwards, so only Settings makes them available to every app, and the app
says so. Rather than download each one as the gallery scrolls past it, the app ships previews:

```sh
xcrun simctl erase 'iPad Pro 11-inch (M5)'
TEST_RUNNER_TYPECASK_APPLE_FONTS_OUTPUT="$PWD/Typecask" xcodebuild test -project Typecask.xcodeproj \
    -scheme Typecask -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
    -only-testing:TypecaskUITests/ApplePreviewRenderer
./scripts/build-catalog.py apple-previews     # subsets them, and corrects their styles
```

The **Apple fonts** workflow does the same on a macOS runner and opens a pull request.

The first writes `Typecask/AppleFonts.json` and an image of each downloadable family in
`Typecask/ApplePreviews/`. It runs in the simulator because iOS's built-in and downloadable fonts
differ from the Mac's, and on an erased one so that fonts installed there don't read as built in.
`apple-previews` then replaces each image with the family's preview face subset to its sample, from
the copy the simulator downloaded, so run it before erasing the simulator again. Those are iOS's own
copies, and reading them needs no Core Text on the Mac, where even matching a font that's downloadable
but not downloaded asks the user to download it. A family keeps its image when the font's embedding
permission is restricted (the least restrictive of its fsType bits counts, as in Font Book), or when
its sample needs shaping only Apple's AAT tables provide, which fontTools drops when it subsets.
Built-in families need neither: the device draws them itself. Rerun both when a new iOS changes the
list.

## Building

Requires Xcode 27.2 and [uv](https://docs.astral.sh/uv/). Simulator builds need no signing team; to
build for a device or archive, put yours in `Signing.local.xcconfig`, which git ignores:

```sh
echo 'DEVELOPMENT_TEAM = ABCDE12345' > Signing.local.xcconfig
```

```sh
# Builds Catalog.json, Previews/ and Licenses/ for every cask in fonts.lock.json, and Fonts.xcassets
# for the casks named here: a static, a variable and a collection font.
./scripts/build-catalog.py build --fonts font-departure-mono-nerd-font font-roboto font-d2coding
open Typecask.xcodeproj
```

The fonts come from two steps, so that a build is repeatable.

`lock` decides the line-up and pins where each cask comes from in `fonts.lock.json`. The line-up is
Homebrew's 1,000 most-installed font casks (`--count`), plus every Google Fonts family (`--google-top N`
for only the most popular N). The two orderings have little to do with each other: Homebrew's is
dominated by Nerd Fonts and coding faces, and only nine of its top hundred are Google Fonts. Popularity
and categories come from `fonts.google.com/metadata/fonts`, which is public and needs no API key. Each
family is matched to a cask by its specimen homepage, then by the google/fonts directory the cask checks
out, then by name: fonts that began elsewhere, like Inter and JetBrains Mono, keep their upstream homepage.

Most casks, 1,886 of about 2,350, are files in github.com/google/fonts, so the lock pins those by the
git tree of their family's directory at one google/fonts commit, and builds read them from a single
sparse clone. The rest are pinned by URL and SHA-256: Homebrew's own hash where it has one, and for a
`:no_check` cask the hash of what was there when the lock was written. A Google family whose upstream
download can't be had, like PT Sans from paratype.com, is taken from google/fonts instead. A lock takes
under a minute.

`build` builds everything from the lock. Each cask builds into `.cache/built/<token>/<key>`, keyed by
its locked source and `PIPELINE_VERSION`, so a cask whose source hasn't changed is reused rather than
downloaded and subset again, and a google/fonts commit that doesn't touch a family doesn't rebuild it.
Bump `PIPELINE_VERSION` when a change alters what a cask builds into. Downloads Homebrew already has are
used from its cache, checked against the locked hash. Casks with no license anywhere are skipped and
remembered; a cask that fails to download is retried next run.

A Google family takes its design style from Google's category rather than the font's PANOSE data, which
most Google families leave empty (without it Nothing You Could Do read as sans serif), and its
description and, where its own download has none, its license from its google/fonts directory. A face
that declares itself fixed pitch stays in Fixed Width either way. Google's metadata still lists six old
Edu names, like Edu VIC WA NT Hand, with no files behind them; those families are in the catalog under
their current names.

Each cask's fonts go in their own asset catalog group, which needs its own `Contents.json`: without it
`actool` silently leaves the cask's asset pack empty, the On-Demand Resources tag downloads fine, and
installing then fails with "could not be found in an asset catalog". Debug builds embed the asset packs
in the app so On-Demand Resources work in the simulator without Xcode hosting them.

Set `GITHUB_TOKEN` before a large build: a cask whose download has no license falls back to its GitHub
repository's, through the API, which allows 60 requests an hour unauthenticated and 5,000 with a token.

## TestFlight

Xcode Cloud builds are triggered by pushing a `testflight-N` tag. `N` becomes the build number, so
`testflight-4` uploads build 4 and TestFlight won't reject it as a duplicate.

The workflow itself lives in App Store Connect rather than this repo — Xcode Cloud has no
workflow-as-code format — so it has to be created once by hand, in Xcode under Product > Xcode Cloud >
Create Workflow, or in App Store Connect under the app's Xcode Cloud tab:

1. **Start Condition:** delete the default branch condition and add *Tag Changes*, with the tag pattern
   `testflight-*`.
2. **Environment:** Xcode 27.2. The repository is public, so the font asset downloads without a
   token; `ci_post_clone.sh` sends `TYPECASK_GITHUB_TOKEN` if one is set, for a private fork.
3. **Action:** *Archive* for iOS, with the Deployment Preparation set to *TestFlight (Internal Testing
   Only)* or *TestFlight and App Store*.
4. **Post-Action:** *TestFlight Internal Testing*, pointed at a tester group.

It needs an Apple Developer Program membership, an App Store Connect record for
`org.marquard.Typecask` whose App ID has the Fonts capability ("Install Fonts"), and the repository
pushed to a host Xcode Cloud can reach (GitHub, GitLab or Bitbucket). The team comes from Xcode Cloud's
`CI_TEAM_ID`, which `ci_post_clone.sh` writes into `Signing.local.xcconfig`.

Both scripts in `ci_scripts/` run automatically. `ci_pre_xcodebuild.sh` sets the build number from
the tag. `ci_post_clone.sh` supplies `Fonts.xcassets`, which is generated rather than committed.

### Font assets

On-Demand Resources only host fonts that are in the archive, so every app build needs the font files.
They're built once, published as a GitHub release asset, and pinned, by the **Fonts** workflow in
`.github/workflows/fonts.yml`. It runs on Mondays, or from the Actions tab:

1. **build** (Ubuntu) runs `lock`, unless told not to, then `scripts/publish-fonts.sh build` and
   `archive`, as separate steps. The
   built casks are kept in the Actions cache, keyed by the lock and the build script; a run restores the
   newest one, so only casks whose source changed are downloaded and subset. It checks the archive
   against `Catalog.json`, and keeps `.cache` on the runner's larger temporary disk.
2. **verify** (macOS, Xcode 27) unpacks a spread of casks from the archive and runs the UI tests on
   them in the simulator: installs, an uninstall, an update and a font iOS already has. A whole line-up
   is too big for the runner's disk once Xcode has copied it into the app, so it carries only those.
3. **publish** attaches the archive to a `fonts-YYYYMMDD-N` release, writes the pin, and opens a pull
   request with the lock, catalog, previews, licenses and pin. Merging it is the release; the next
   TestFlight build ships it. The repository has to allow GitHub Actions to create pull requests
   (Settings › Actions › General).

Locally, the same two steps:

```sh
scripts/publish-fonts.sh build     # everything from fonts.lock.json
scripts/publish-fonts.sh archive   # .cache/fonts-YYYYMMDD.tar.zst
# build the app and try installs in the simulator, then:
scripts/publish-fonts.sh upload    # attach that same archive to a release and write the pin
```

`upload` refuses if any cask's `assets` or `pack` in `Catalog.json` differ from what `build` recorded
beside the archive. Commit the lock, `Catalog.json`, `Previews/`, `Licenses/` and the pin together:
`ci_post_clone.sh` downloads the pinned asset, verifies the hash, and refuses to build if the casks in
it don't match the ones `Catalog.json` says are installable. Without a pin it falls back to building the
casks named in `TYPECASK_CASKS` from the lock.

Heavy niche casks are left out: those over 10 MB that cost more than 0.1 MB per yearly install, which is
Iosevka's stylistic sets, the rarer Maple Mono builds and a handful of CJK families. Google families are
exempt, since Homebrew counts undercount fonts most people get from Google. Set `MAX_MB_PER_INSTALL` to
move the line, or leave it empty to ship everything.

Each cask ships its variable font where it has one, which covers every weight in a file or two, and
otherwise the Regular, Italic, Bold and Bold Italic of a single family. Nerd Fonts' Mono and Propo
spacing variants are left out, and so is any file over 100 MB, which is CJK collections and Iosevka
SuperTTCs, so a cask made only of those reads as "Fonts not included in this build". GitHub caps a
single release asset at 2 GiB, and the publish step refuses an archive over 1.9 GiB.

### How many fonts a release can ship

Apple caps an app at [1000 asset packs](https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits)
and 70 GB of hosted On-Demand Resources on iOS 18 and later. Each On-Demand Resources tag becomes one
pack — font data assets don't slice by device the way images do, which a 760-cask build confirmed — so
`build` gives each cask of 1 MB or more its own tag and spreads smaller casks across 450 shared ones by
a hash of the cask's token, so a cask keeps its pack as others come and go, 900 in all at most. The tag
is the `pack` field in `Catalog.json`. Installing a
cask downloads its pack-mates too but registers only its own fonts, so the cost is a few hundred KB of
extra download. Note also that On-Demand Resources are deprecated as of iOS 27; Background Assets is the
replacement, but fonts delivered through it can't be installed system-wide, which is why this app
still uses ODR.

## Checks

```sh
swiftlint --strict
uvx ruff format --check scripts && uvx ruff check scripts
uvx --from shellcheck-py shellcheck scripts/*.sh ci_scripts/*.sh
uvx --from shfmt-py shfmt -d scripts ci_scripts
uvx --from actionlint-py actionlint

xcrun simctl erase 'iPad Pro 11-inch (M5)'
TEST_RUNNER_TYPECASK_CASK=font-roboto xcodebuild test -project Typecask.xcodeproj -scheme Typecask \
    -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -only-testing:TypecaskUITests/InstallTests
```

`ruff.toml` and `.editorconfig` hold the Python and shell settings. The UI tests install a cask, accepting
the system consent sheet, and check it's still installed after a relaunch; uninstall one and check it stays
uninstalled; update one marked outdated; and check that a cask iOS already ships offers no Install button.
Pick the cask with `TEST_RUNNER_TYPECASK_CASK=<token>`. Erase the simulator first: fonts outlive
`simctl uninstall`, so a cask installed by an earlier run has no Install button. The Fonts workflow runs
the same tests on a spread of casks.

Subsetting large font collections takes a lot of memory: a build once reached 26 GB before reading fonts
lazily. `python3 scripts/memcap.py 14 scripts/publish-fonts.sh build` runs it under a cap on its physical
footprint, which macOS's RSS doesn't report. AGENTS.md has more of what's worth knowing before changing
things.
