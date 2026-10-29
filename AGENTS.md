# Typecask: notes for agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) for building, checks and commit message style, and
[docs/](docs) for how the app, font pipeline and releases work. These are the rules that cost time to
learn.

## Checks

```sh
swiftlint --strict
uvx ruff format --check scripts && uvx ruff check scripts
uvx --from shellcheck-py shellcheck scripts/*.sh
uvx --from shfmt-py shfmt -d scripts
uvx --from actionlint-py actionlint
scripts/build-catalog.py check-licenses
```

## Generated files

- Never hand-edit `Typecask/Catalog.json`, `Previews/`, `Licenses.deflate`, `AppleFonts.json`,
  `ApplePreviews/` or `Fonts.xcassets`, or the root `Licenses/`; change `scripts/build-catalog.py`
  and rebuild.
- Look before deleting or overwriting anything generated: a full rebuild is hours of downloads.
- The boot volume is case-insensitive. For a case-only rename, write to a distinct temp name and
  `os.replace` it, never save-new-then-delete-old, and check the stored names after.
- `docs/icon/` and the About screen's `AboutIcon.imageset` are renders of `Typecask/AppIcon.icon`.
  Edit the icon in Icon Composer, then rerun `scripts/icon.sh`; see [docs/icon.md](docs/icon.md).

## Font pipeline

- Bump `PIPELINE_VERSION` when a change alters what a cask builds into, and `SKIP_VERSION` when it
  could rescue skipped casks; otherwise cached casks keep the old behavior.
- Builds must be byte-identical from the same lock on macOS and Linux: sort with explicit tie-breaks,
  don't iterate sets into output, open fonts with `recalcTimestamp=False`, use `hashlib` not `hash()`.
  Verify with two builds under different `PYTHONHASHSEED` values.
- Only `lock` touches the network to decide sources; `build` uses the lock's files (`.cache/downloads/`
  for `:no_check` casks), never re-resolving.
- Never delete assets of the `font-sources` release: it mirrors non-GitHub downloads by SHA-256, and old
  locks build from it. Mirror only casks in the catalog, which have a license.
- Shared packs are assigned by a hash of the token, so adding or removing a cask doesn't move others.
  Stay under 900 packs (Apple's cap is 1000).
- Every asset catalog group needs its own `Contents.json`, or `actool` silently ships an empty pack.
- Ship a cask only with a license. Never ship Apple's fonts; `apple-previews` subsets only what fsType
  permits (least restrictive bit wins).
- Never ship a GPL or AGPL font: Apple's App Store terms conflict with GPL section 6, and a font
  exception doesn't cover it. Add it to `EXCLUDED`.
- A license found through the GitHub API is the repository's, not the fonts': that's how Consolas
  got in under someone else's BSD license. Check a cask whose license came from there.
- Run font-heavy scripts under the cap, `python3 scripts/memcap.py 14 <command>`, and open fonts with
  `lazy=True`: fontTools has reached 26 GB and crashed the Mac, invisibly to RSS.
- On the Mac, never resolve a downloadable Apple font through Core Text; it pops a download dialog per
  font. `ApplePreviewRenderer` downloads them in the simulator.
- Keep `.cache/` on the boot disk.

## The site

- `site/` reads the catalog of the latest `testflight-N` tag, not main's: `scripts/site-catalog.sh`
  writes `site/data/`, `site/static/p/` and `site/licenses/`, all gitignored. Run it before `hugo`.
- Previews hold about fifty glyphs, so nothing on the site can be set in a font but the sample line.
- Apple's fonts stay off the site; `apple-previews` subsets Apple's own files.
- A `define` in a page template reaches a `block` in `baseof.html` only, never one inside a partial.
- Hugo's taxonomy map keys multi-word terms with spaces, so look a term page up with `site.GetPage`
  and a urlized path rather than `.Taxonomies.styles.Get`.
- JSON numbers arrive as float64: `printf "%d"` needs an `int` cast first.
- The app screenshots in `site/assets/screens/` come from `scripts/screenshots.sh`; retake them, don't
  edit them. `XCUIScreen` captures in portrait whichever way the device is held, so `SiteScreenshots`
  turns landscape shots upright itself.

## Signing and releases

- Verify in the simulator before publishing fonts or a release.
- Never set a team in Xcode's Signing & Capabilities pane; it goes in the gitignored
  `Signing.local.xcconfig`.
- Releases sign manually: ad-hoc archive, then export with the stored certificate and profile.
  `-allowProvisioningUpdates` with an API key can't use cloud-managed distribution certificates.
- Check signing before the archive (`scripts/prepare-export.sh`), never after; xcodebuild reports
  signing errors only once it reaches signing.
- Export detail is in the `.xcdistributionlogs` bundle named on the export's first line, in the
  Darwin per-user temp directory (`TMPDIR` doesn't move it). Read the path from the log.
- Install the signed `.mobileprovision`, never the plist `security cms -D` decodes from it.

## Simulator and UI tests

- Erase the simulator before install tests: installed fonts outlive `simctl uninstall`.
- A cask is installed when it shows an Uninstall button, not the word "Installed" (the sidebar has
  an Installed collection).
- A cask whose primary face iOS already ships under the same PostScript name can't register (Core Text
  error 305) and shows "Built into iOS".
- For UI work, build a copy of the project without `Fonts.xcassets`; the full one makes a 3 - 4 GB
  debug app.
- Screenshots lag taps by a second or two, input right after launch can be dropped, and rotation
  changes tap coordinates. Take a second screenshot before deciding a tap failed.
- In CI, wait for `simctl bootstatus -b` before the first test; a cold boot outlasts XCTest.
