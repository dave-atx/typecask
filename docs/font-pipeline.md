# The font pipeline

`scripts/build-catalog.py` turns Homebrew's font casks and Google Fonts into what the app ships. It
works in two steps, so that a build is repeatable: `lock` decides what to ship and pins where each cask
comes from, and `build` builds everything from that lock.

`build` writes into `Typecask/`:

| Path | What it is |
| --- | --- |
| `Catalog.json` | gallery metadata: each cask's design style, versions, description, popularity and pack |
| `Previews/` | fonts subset to the gallery's sample text, so the gallery renders before anything is installed |
| `Licenses.deflate` | every cask's license, one JSON object by token, raw-deflated |
| `Fonts.xcassets/` | the fonts themselves, tagged for On-Demand Resources (several GB, gitignored) |

and the same licenses as text into `Licenses/` at the root, outside the app, so a fonts pull request
shows what changed in them. The app carries them compressed: 2,000-odd text files, most of them the
same OFL, took 20 MB on a device, where the one file takes 0.8 MB.

These are generated, so don't edit them by hand: change the script and rebuild.

## Lock

```sh
./scripts/build-catalog.py lock
```

`lock` writes `fonts.lock.json`, and takes under a minute. The line-up is Homebrew's 1,000
most-installed font casks (`--count`), plus every Google Fonts family (`--google-top N` for only the
most popular N). Popularity and categories come from `fonts.google.com/metadata/fonts`, which is public
and needs no API key. Each Google family is matched to a cask by its specimen homepage, then by the
google/fonts directory the cask checks out, then by name, since fonts that began elsewhere, like Inter
and JetBrains Mono, keep their upstream homepage.

Most casks are files in github.com/google/fonts, so the lock pins those by the git tree of their
family's directory at one google/fonts commit, and builds read them from a single sparse clone. The rest
are pinned by URL and SHA-256: Homebrew's own hash where it has one, and for a `:no_check` cask the
hash of what was there when the lock was written, with the file kept in `.cache/downloads/`.

Everything that depends on the network is decided here. `lock` downloads each Google family's upstream
release fresh, and falls back to google/fonts when it no longer matches Homebrew's hash or can't be
had at all (PT Sans from paratype.com, say). Every other download that's new or changed since the last
lock is fetched and checked too, and kept for the build; one that can't be had or doesn't match leaves
the cask at its previous pin, listed as kept at its locked version, so a host that's down holds back an
update instead of dropping a font.

## Build

```sh
./scripts/build-catalog.py build                       # every cask in the lock
./scripts/build-catalog.py build --fonts font-roboto   # font assets only for the casks named
```

Each cask builds into `.cache/built/<token>/<key>`, keyed by its locked source and `PIPELINE_VERSION`,
so a cask whose source hasn't changed isn't downloaded and subset again. Bump
`PIPELINE_VERSION` when a change alters what a cask builds into, and `SKIP_VERSION` when a change could
rescue skipped casks. Downloads already in Homebrew's cache are used, checked against the locked hash.

A download comes from what `lock` kept, then the mirror (below), then its host. curl retries every
error five times, and casks that still fail are tried again one at a time once the rest are built.
Casks with no license anywhere are skipped and remembered; a cask that fails even so is retried next
run. Where a download has no license, `build` looks in the family's google/fonts directory and then in
its GitHub repository, through the API. Set `GITHUB_TOKEN` before a large build: the API allows 60
requests an hour unauthenticated and 5,000 with a token.

A Google family also takes its description, and its design style from Google's category, from its
google/fonts metadata. Google's metadata still lists six old Edu names, like Edu VIC WA NT Hand, with no
files behind them; those families are in the catalog under their current names.

A full build loads thousands of fonts and has used over 20 GB of memory. Run it under the memory cap:

```sh
python3 scripts/memcap.py 14 scripts/publish-fonts.sh build
```

### Reproducibility

The same lock must produce byte-identical `Catalog.json` and previews on macOS or Linux. Sort with an
explicit tie-break, don't let set iteration order reach the output, open fonts with
`recalcTimestamp=False`, and hash with `hashlib` (`hash()` is seeded per run). To check, build twice with different
`PYTHONHASHSEED` values and compare.

## What a release ships

- **Files.** A cask's variable font where it has one; otherwise the Regular, Italic, Bold and Bold
  Italic of a single family, the primary face's. Both are read from the fonts' own tables (`fvar`, and
  the typographic family and subfamily names), not their filenames, which follow no one scheme:
  Charter's `Charter Bold.otf` and Linux Libertine's `LinLibertine_RBah.ttf`. The primary face's
  file always ships, though Terminus calls its Regular "Medium". Nerd Fonts' Mono and
  Propo spacing variants are left out, and so is any file over 100 MB (CJK collections and Iosevka
  SuperTTCs), so a cask made only of those reads as "Fonts not included in this build".
- **The primary face** is the one the gallery previews and the app checks to see whether a cask is
  installed: a text face rather than a math one, upright, Regular, nearest 400 in weight, normal
  width, proportional where the cask also has a monospaced family, then the shortest family name.
- **Previews** are the primary face subset to the sample, keeping only the OpenType features Core
  Text applies by default and no hinting, which Core Text doesn't use: every feature kept every
  stylistic alternate, and Iosevka's preview came to 1,900 glyphs. A variable font is instanced at
  its Regular, whatever its default: Fira Code's is Light. A face with no Latin letters is previewed
  in its own script, from the same list of lines `ApplePreviewRenderer` uses, and a face that draws
  none of them, an icon, emoji or music font, is skipped as having nothing to preview.
- **Heavy niche casks** are left out entirely: those over 10 MB that cost more than 0.1 MB per yearly
  install, which is Iosevka's stylistic sets, the rarer Maple Mono builds and a handful of CJK families.
  Google families are exempt, since Homebrew undercounts fonts most people get from Google. Set
  `MAX_MB_PER_INSTALL` to move the line, or leave it empty to ship everything.
- **Licenses.** A cask ships only with a license.

### Asset packs

Apple caps an app at [1,000 asset packs](https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits)
and 70 GB of hosted On-Demand Resources. Each On-Demand Resources tag becomes one pack (font data
doesn't slice by device the way images do), so `build` gives each cask of 1 MB or more its own tag and
spreads smaller casks across 450 shared tags by a hash of the token, 900 packs at most. A cask keeps its
pack as others come and go, which keeps a fonts pull request's diff to what changed. The tag is the
`pack` field in `Catalog.json`. Installing a cask downloads its pack-mates too, a few hundred KB extra,
but registers only its own fonts.

Each cask's fonts go in their own asset catalog group, which needs its own `Contents.json`: without it
`actool` silently leaves the pack empty, and installing fails with "could not be found in an asset
catalog". Debug builds embed the asset packs in the app, so On-Demand Resources work in the simulator
without Xcode hosting them.

## Publishing fonts

Every app build needs the font files in the archive, since On-Demand Resources only hosts what was
uploaded. They're built once, attached to a GitHub release, and pinned in `Typecask/FontsAsset.json`
by the **Fonts** workflow (`.github/workflows/fonts.yml`), which runs on Mondays or from the Actions
tab:

1. **build** (Ubuntu) runs `lock` unless told not to, then `scripts/publish-fonts.sh build` and
   `archive`. Built casks are kept in the Actions cache, so only casks whose source changed are
   downloaded and subset.
2. **verify** (macOS) unpacks a spread of casks from the archive and runs the UI tests on them in the
   simulator: installs, an uninstall, an update and a font iOS already has.
3. **publish** attaches the archive to a `fonts-YYYYMMDD-N` release, writes the pin, and opens a pull
   request with the lock, catalog, previews, licenses and pin, against the branch the run started
   from. Merging it into main is the release; the next app build ships it. Started from another
   branch, the run rebuilds the fonts for that branch's pipeline changes, so they merge together.
   The repository has to allow GitHub Actions to create pull requests.

The release notes and the pull request both say which casks were added, removed, updated to a new
version or rebuilt into different files, compared with main as it is when the run publishes.
`scripts/fonts-changelog.py [BASE]` writes that from `Catalog.json` against the one at `BASE` (default
`HEAD`), and gives each removal its reason: out of the line-up in the lock, or failed, skipped, trimmed
or overlapping another cask in the `.cache/build-report.json` that `build` writes. Run it after a local
build to see what a release would change. A cask that shipped before and failed to build this time
leads them with a warning, and the pull request opens as a draft, so a release only loses a font when
someone has decided it should.

Locally, the same steps:

```sh
scripts/publish-fonts.sh build     # everything from fonts.lock.json
scripts/publish-fonts.sh archive   # .cache/fonts-YYYYMMDD.tar.zst
# build the app and try installs in the simulator, then:
scripts/publish-fonts.sh upload    # attach that archive to a release and write the pin
```

`upload` refuses if any cask's `assets` or `pack` in `Catalog.json` differ from what `build` recorded
beside the archive, and refuses an archive over 1.9 GiB (GitHub caps a release asset at 2 GiB). Commit
the lock, `Catalog.json`, `Previews/`, `Licenses.deflate`, `Licenses/` and the pin together. `scripts/fetch-fonts-asset.sh`
downloads the pinned archive for an app build, checks its hash, and refuses to continue if its casks
don't match the ones `Catalog.json` says are installable. Without a pin it builds the casks named in
`TYPECASK_CASKS` from the lock instead.

### The download mirror

Downloads from hosts other than GitHub are kept as assets of the `font-sources` release, named by
SHA-256, so any lock builds the same files after its hosts go down or change them: gust.org.pl was down
for all of one build, and int10h.org once served Ac437 with a different hash. GitHub's downloads aren't
copied, since the mirror is no more durable than GitHub (`DURABLE_HOSTS` in `build-catalog.py`). Only
casks in the catalog are mirrored, since those are the ones with a license to redistribute; Apple's
fonts never are. After `build`, `scripts/build-catalog.py mirror` gathers what the mirror lacks into
`.cache/mirror/`, and `publish-fonts.sh upload` attaches it. Never delete the mirror's assets: an old
lock builds from them.

## Apple's fonts

`Typecask/AppleFonts.json` and `Typecask/ApplePreviews/` list Apple's fonts and hold previews of the
downloadable ones. Regenerate them when a new iOS changes the list, with the **Apple fonts** workflow,
which opens a pull request, or locally:

```sh
xcrun simctl erase 'iPad Pro 11-inch (M5)'
TEST_RUNNER_TYPECASK_APPLE_FONTS_OUTPUT="$PWD/Typecask" xcodebuild test -project Typecask.xcodeproj \
    -scheme Typecask -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
    -only-testing:TypecaskUITests/ApplePreviewRenderer
./scripts/build-catalog.py apple-previews
```

`ApplePreviewRenderer` is a generator run as a test. It runs in the simulator because iOS's built-in
and downloadable fonts differ from the Mac's, and on an erased one so that fonts installed there don't
read as built in. It lists the fonts, downloads each downloadable family, and renders an image of it.

`apple-previews` then replaces each image with the family's preview face subset to its sample, from the
copy the simulator downloaded, so run it before erasing the simulator again. A family keeps its image
when the font's embedding permission is restricted (the least restrictive of its fsType bits counts, as
in Font Book), or when its sample needs shaping that only Apple's AAT tables provide, which fontTools
drops when it subsets. Apple's fonts themselves are never shipped.

Don't resolve a downloadable Apple font through Core Text on a Mac: even matching one that isn't
downloaded asks the user to download it. Reading the simulator's copies needs no Core Text.
