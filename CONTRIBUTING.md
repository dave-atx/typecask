# Contributing to Typecask

## Issues

Use [GitHub Issues](https://github.com/dave-atx/typecask/issues) for bugs, and to ask for a font to
be added or corrected (a wrong license, design style or preview). For a bug, include your device, iOS
version and the font involved.

## Building the app

Requires Xcode 27.2 and [uv](https://docs.astral.sh/uv/). `Catalog.json`, the previews and the licenses
are checked in; the fonts themselves (`Typecask/Fonts.xcassets`) are not, and you have three options for
them:

- **None.** Open `Typecask.xcodeproj` and run. The gallery, previews and detail pages all work;
  installing fails. This is the fastest way to work on the UI.
- **A few casks, built locally:**

  ```sh
  ./scripts/build-catalog.py build --fonts font-departure-mono-nerd-font font-roboto font-d2coding
  ```

  This builds font assets only for the casks named (a static, a variable and a collection font), but
  rebuilds the catalog and previews for every cask, which downloads all of them the first time.
- **Every cask**, from the published release: `scripts/fetch-fonts-asset.sh`. That's a 1.4 GB download
  and a 3 - 4 GB debug app, with a slow `actool` step.

Simulator builds need no signing team. To build for a device, put yours in `Signing.local.xcconfig`,
which git ignores. Setting it in Xcode's Signing & Capabilities pane writes it into the project for
everyone.

```sh
echo 'DEVELOPMENT_TEAM = ABCDE12345' > Signing.local.xcconfig
```

## Checks

Run these before opening a pull request:

```sh
swiftlint --strict
uvx ruff format --check scripts && uvx ruff check scripts
uvx --from shellcheck-py shellcheck scripts/*.sh
uvx --from shfmt-py shfmt -d scripts
uvx --from actionlint-py actionlint
```

The UI tests install a cask (accepting the system consent sheet) and check it's still installed after a
relaunch, uninstall one, update one marked outdated, and check that a cask iOS already ships offers no
Install button. They need that cask's fonts built (see above), and an erased simulator, since installed
fonts outlive `simctl uninstall`:

```sh
xcrun simctl erase 'iPad Pro 11-inch (M5)'
TEST_RUNNER_TYPECASK_CASK=font-roboto xcodebuild test -project Typecask.xcodeproj -scheme Typecask \
    -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -only-testing:TypecaskUITests/InstallTests
```

## Changing the font pipeline

Read [the font pipeline](docs/font-pipeline.md) first. In short: don't hand-edit generated files, keep
builds reproducible from the lock, bump `PIPELINE_VERSION` when a change alters what a cask builds into,
and run full builds under `scripts/memcap.py`.

## Pull requests

Keep a pull request to one change, and a fonts pull request's diff to what changed. Commit messages
have a sentence-case imperative subject ("Skip casks with no license") and a body that explains why
the change is needed, in prose.
