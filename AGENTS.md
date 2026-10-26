# Typecask: notes for agents

The README explains what the app does and how the font pipeline works. This file is the short list of
things that cost real time to learn: read it before changing the pipeline, the tests, or anything that
deletes or renames files.

## Layout

- `Typecask/`: the SwiftUI app. `Catalog.json`, `Previews/`, `Licenses/`, `AppleFonts.json` and
  `ApplePreviews/` are generated: change the scripts and rebuild, never hand-edit them.
  `Fonts.xcassets` is generated and gitignored (several GB).
- `TypecaskUITests/`: `InstallTests` (install, uninstall, update, built-in) and `ApplePreviewRenderer`,
  which is a generator run as a test, not a test.
- `scripts/build-catalog.py`: `lock`, `build` and `apple-previews`. `scripts/publish-fonts.sh`:
  `build`, `archive`, `upload`. `fonts.lock.json` pins every cask's source.
- `.github/workflows/fonts.yml` builds, verifies in the simulator and publishes fonts;
  `testflight.yml` archives a `testflight-N` tag and uploads it, via `scripts/fetch-fonts-asset.sh`,
  `scripts/set-build-number.sh`, `scripts/prepare-export.sh` and `scripts/run-with-heartbeat.sh`.

## Checks

```sh
swiftlint --strict
uvx ruff format --check scripts && uvx ruff check scripts
uvx --from shellcheck-py shellcheck scripts/*.sh
uvx --from shfmt-py shfmt -d scripts
uvx --from actionlint-py actionlint
```

## The font pipeline

- `build` caches each cask under `.cache/built/<token>/<key>`, keyed by its locked source and
  `PIPELINE_VERSION`. Bump `PIPELINE_VERSION` when a change alters what a cask builds into (preview
  text, file selection, subsetting); bump `SKIP_VERSION` when a change could rescue skipped casks (a
  new license source). Otherwise cached casks silently keep the old behavior.
- A build must be reproducible from the lock: same lock, byte-identical `Catalog.json` and previews,
  on macOS or Linux. Sort with an explicit tie-break, never iterate a set where order reaches the
  output (hash seeds vary per run), open fonts with `recalcTimestamp=False` (fontTools otherwise
  stamps the build time into every saved font), and use `hashlib`, not `hash()`. Check with two
  builds under different `PYTHONHASHSEED` values.
- Keep a fonts PR's diff to what changed: shared asset packs are assigned by a hash of the token, so
  adding or removing a cask doesn't move the others.
- `lock` decides everything that depends on the network: it downloads each Google family's upstream
  release fresh, and falls back to google/fonts when it no longer matches Homebrew's hash. A build
  never makes that choice, or a Mac with an old copy in Homebrew's cache would build differently from
  CI.
- A cask is shipped only with a license. Apple's fonts are never shipped; `apple-previews` subsets
  only what the font's fsType embedding bits permit (the least restrictive bit wins, as in Font Book).
- `:no_check` downloads are hashed by `lock` and kept in `.cache/downloads/<sha256>`: some hosts
  (Input's) serve different bytes every request, so `build` must use the lock's own file.
- Apple allows 1000 On-Demand Resources packs; small casks share packs past 900. Every asset catalog
  group needs its own `Contents.json` or `actool` silently ships an empty pack.

## Signing

The project names no team: `Signing.xcconfig` includes an optional, gitignored
`Signing.local.xcconfig`, which the TestFlight workflow writes from the `APPLE_TEAM_ID` variable.
Don't set a team in Xcode's Signing & Capabilities pane, which writes it into the project for
everyone.

- Releases sign manually, and have to. `xcodebuild -allowProvisioningUpdates` with an App Store
  Connect API key signs distribution builds with Apple's cloud-managed certificates, which a key has
  no access to; it archived with a development certificate it minted itself and then couldn't export.
  The archive is ad-hoc (`CODE_SIGN_IDENTITY=-`) and the export re-signs from a stored certificate
  and profile.
- Check signing before the archive, never after. xcodebuild resolves it at the end of an export,
  after staging several GB of asset packs, so a bad certificate or profile takes about 40 minutes to
  report itself. `scripts/prepare-export.sh` is that check.
- An export writes almost nothing to stdout; the step-by-step detail is in the
  `.xcdistributionlogs` bundle it names on its first line (759 bytes against 31 MB once). That goes
  to the Darwin per-user temp directory, which setting `TMPDIR` does not move, so read the path back
  from the log rather than choosing it.
- Install the signed `.mobileprovision` itself, never the plist `security cms -D` gets out of it.
  Xcode decodes whatever is in `~/Library/MobileDevice/Provisioning Profiles`, and a plain plist
  fails as "Profile is missing the required UUID property" with the UUID plainly in the file.

## Running heavy scripts

- Run `build` and anything else that loads many fonts under the memory cap:
  `python3 scripts/memcap.py 14 scripts/publish-fonts.sh build`. A fontTools run once reached 26 GB
  and crashed the Mac; RSS-based watchdogs miss it because macOS RSS excludes compressed memory.
  Open fonts with `lazy=True` and read only the tables you need.
- On the Mac, never resolve a downloadable Apple font through Core Text (`CTFontCreateWithName`,
  descriptor matching): it triggers auto-activation, a "needs to download the font" dialog on the
  user's screen for every font. `ApplePreviewRenderer` downloads them in the simulator instead.
- Keep `.cache/` on the boot disk: the google/fonts clone's many small files crawl on a spinning
  external disk. `build` reuses downloads already in Homebrew's cache, checked against the lock.

## Files and renames

- The boot volume is case-insensitive APFS. A rename that only changes case is the same path: never
  save-to-new-then-delete-old (that deleted 102 generated fonts once). Write to a distinct temp name and
  `os.replace` it, and check the stored names after.
- Look before deleting or overwriting anything generated: a full rebuild is hours of downloads.

## Simulator and UI tests

- Erase the simulator before install tests: installed fonts outlive `simctl uninstall`, and a cask
  installed by an earlier run has no Install button.
- Tests decide a cask is installed by its Uninstall button, not the word "Installed", which the
  sidebar's Installed collection also shows.
- Fonts installed by the app survive app updates and reinstalls; the system keeps its own copy.
- A cask whose primary face iOS already ships under the same PostScript name (Noto Sans Armenian)
  can't be registered (Core Text error 305) and shows as "Built into iOS".
- For UI iteration, build a copy of the project with an empty `Fonts.xcassets`: the full one makes a
  3-4 GB debug app and a slow `actool` step.
- Driving the simulator by hand: screenshots lag taps by a second or two, input right after launch
  can be dropped, and a rotated device changes the tap coordinate space. Take a second screenshot
  before concluding a tap failed.
- In CI, boot the simulator and wait for `simctl bootstatus -b` before the first test; a cold first
  boot otherwise outlasts XCTest ("operation never finished bootstrapping").

## Working with Dave

- Ask before committing, pushing, publishing a release, or changing repository settings, and verify
  in the simulator before anything is published.
- Commit messages: sentence-case imperative subject, prose body explaining why, no AI attribution
  trailers.
