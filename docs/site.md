# The site

[typecask.app](https://typecask.app) is a Hugo site in `site/`, deployed to Cloudflare Workers as
static assets. It describes the app, carries the privacy policy and support pages the App Store
listing points at, and publishes the whole font catalog, each family set in its own face.

## The catalog it shows

The site shows the catalog the shipping app carries, not main's. A fonts release merges into main on
Mondays and the app that ships it goes out whenever a `testflight-N` tag is pushed, so main's
`Catalog.json` routinely lists fonts that no installed copy of the app has. A site built from main
would offer people fonts they can't install.

`scripts/site-catalog.sh` reads the most recent `testflight-N` tag and copies that tag's
`Catalog.json`, `Previews/`, `Licenses/` and app icon into `site/`, where Hugo picks them up:

| Written to | From the tag |
| --- | --- |
| `site/data/catalog.json` | `Typecask/Catalog.json` |
| `site/static/p/` | `Typecask/Previews/` |
| `site/licenses/` | `Licenses/` |
| `site/assets/icon.png` | the app icon |
| `site/data/release.json` | the tag, build number, commit and date |

All of it is gitignored. The script runs `git archive` against the tag, so it works from a checkout
of any revision, and it fetches the tag itself when the clone doesn't have one, which is what CI
does. Set `TYPECASK_RELEASE_TAG` to build against a particular tag, or `TYPECASK_RELEASE_TAGS` to
change the pattern; point it at `release-*` once the App Store, rather than TestFlight, is what
people get.

## Building it

```sh
scripts/site-catalog.sh          # from the repository root
cd site && hugo server
```

Hugo 0.168 or later. A full build is about three seconds for 2,208 pages: one per cask, one per
design style, the catalog, the home page and the documents.

Pages come from `content/fonts/_content.gotmpl`, a content adapter that emits one page per cask
straight out of `catalog.json`. There are no per-font Markdown files to maintain; a fonts release
changes the catalog and the pages follow.

## How the specimens work

Every specimen on the site is the preview file the app ships: the cask's primary face subset to the
gallery's sample text, renamed `TypecaskPreview-<cask>`, roughly fifty glyphs. That's the whole
Latin lowercase, the digits, a capital T and the sample's punctuation, which is enough for the
sample line and nothing else. A font's own name can't be set in its own face, and neither can
anything a visitor might type. Serving wider subsets would mean a new `build-catalog.py`
subcommand and something like 60 - 120 MB of woff2.

The catalog page carries all 2,193 rows. The first 24 get a `@font-face` rule in the page's head;
the rest load as they come near the viewport, in `assets/js/catalog.js`, so a visit downloads the
dozen faces it actually shows instead of 34 MB. Rows use `content-visibility: auto` so the browser
doesn't lay out what nobody has scrolled to. Search, filtering and sorting are over the DOM, with
the state in the query string. Without JavaScript the whole catalog is still there in the system
face, and every font still has its own page.

Apple's fonts aren't on the site. The app lists them, but `apple-previews` subsets Apple's own font
files, and publishing those on a website is a different kind of distribution from shipping them
inside an iOS app.

## Screenshots

The home page's pictures of the app are real screenshots, in `site/assets/screens/`, and Hugo serves
them as WebP at 1x and 2x through `layouts/_partials/screenshot.html`. They're checked in, since the
site builds on Linux, where there's no simulator. To retake them:

```sh
scripts/screenshots.sh
```

It runs `TypecaskUITests/SiteScreenshots` on an iPhone 18 Pro and an iPad Pro 13-inch (M5) at once,
in dark appearance with the status bar at 9:41, from a copy of the project without
`Fonts.xcassets`, and takes about five minutes. Each test drives the app to one screen and attaches
it under the name the page uses:

- `iphone-samples`: All Fonts by Trending, as sample lines, scrolled to start at the first
  handwriting font. The top of Trending is mostly monospaced fonts, which look alike; the test reads
  the catalog to find that font, so the shot keeps up as Trending changes.
- `iphone-detail`: Caveat's page. A handwriting font, the style least like the rest.
- `ipad-gallery`: All Fonts by Trending, in landscape.

To add one, add a test that snaps a new name, then use that name in the page.
`TYPECASK_SCREENSHOT_PHONE` and `TYPECASK_SCREENSHOT_PAD` pick other simulators, and
`TEST_RUNNER_TYPECASK_SCREENSHOT_CASK` another cask for the detail page. A failing test leaves the
screenshots as they were, prints why, and keeps `Screenshots.xcresult` (gitignored), with a screen
recording and the UI hierarchy at the failure.

Nothing needs installing beyond Xcode: `simctl` sets the appearance and status bar and `xcresulttool`
exports the attachments. `oxipng` shrinks the PNGs, as it does the previews.

## Deploying

`.github/workflows/site.yml` builds and deploys. It runs when a **TestFlight** run succeeds, which
is the point of the whole arrangement, and also on a push to main that touches `site/`, on pull
requests that touch it (build only, no deploy), and from the Actions tab.

Cloudflare Workers Builds would have been less machinery, but it only triggers on branch pushes and
this has to trigger on a tag. If the trigger ever becomes a branch, the build moves there with
little change: `HUGO_VERSION` is the same variable Workers Builds reads.

It needs these in the repository's Actions settings:

| Name | What it is |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | a token with Workers Scripts:Edit on the account |
| `CLOUDFLARE_ACCOUNT_ID` | the account the Worker lives in |

`site/wrangler.toml` names the Worker and points it at `site/public`. There's no Worker script:
unmatched paths get Hugo's `404.html` with a 404.

The build is about 4,400 files and 77 MB, against Cloudflare's limits of 20,000 files per version
on the free plan and 25 MiB per file. The largest file is the catalog page at 1.1 MB, 110 KB over
the wire.

## Things that are set, and where

`site/hugo.toml` holds the lot:

- `appStoreID` is 6826936046. `appStoreLive` is false while the app is TestFlight-only; the download
  buttons read "Coming to the App Store" until either it's true or `testflightURL` is set, and they
  never render a link to a listing that isn't public.
- `cloudflareAnalyticsToken` is empty until the site is live. With it set, production builds load
  Cloudflare Web Analytics, which is cookieless and is what `/privacy/` describes. Local and preview
  builds load no script at all.
- `supportEmail` is empty, so `/support/` points at GitHub Issues only.

The site is dark only, from the app icon: near-black, cream, one orange. The chrome is set in the
system face, so the specimens are the only typography on the page and a site whose selling point is
that nothing is collected makes no third-party font request.
