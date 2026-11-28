# The site

[typecask.app](https://typecask.app) is a Hugo site in `site/`, deployed to Cloudflare Workers as
static assets. It describes the app, carries the privacy policy and support pages the App Store
listing points at, and publishes the whole font catalog, each family set in its own face.

## The catalog it shows

The site shows the version of the app the App Store has, not main's catalog, nor the newest TestFlight
build's. A fonts release merges into main on Mondays and TestFlight builds go out whenever a
`testflight-N` tag is pushed, so either would offer fonts people can't install yet, and say what a
version people don't have yet does.

So each version submitted for review gets a `release-VERSION` tag on the commit its build came from,
`release-1.1` on the commit `testflight-16` built, say. `scripts/site-catalog.sh` asks Apple's lookup API
which version is live and builds from that version's tag; if the lookup fails or the version has no tag,
the newest `release-*` tag stands in. The site rebuilds every three hours, so a release reaches it the
same day, with nothing to flip by hand. The site serves `release.json` too, and when a deploy moves it to
another version the Site workflow posts the version's release notes in Discussions, under Announcements,
which GitHub tells everyone watching the repository about. From the tag it copies:

| Written to | From the tag |
| --- | --- |
| `site/data/catalog.json` | `Typecask/Catalog.json` |
| `site/static/p/` | `Typecask/Previews/` |
| `site/licenses/` | `Licenses/` |
| `site/assets/icon.png` | `docs/icon/default.png`, the app icon as `scripts/icon.sh` renders it |
| `site/data/release.json` | the tag, version, build number (the `testflight-N` on the same commit), fonts release, commit and date |
| `site/data/notes.json` | release notes of every version up to the tag's, from main's `docs/release-notes/` so a line can be fixed after a release, for What's New |
| `site/data/webfonts.json` | Try It Out's manifest for the tag's fonts release, from R2 rather than the tag |
| `site/data/articles.json`, `site/static/a/` | `Typecask/Articles.json` and `Typecask/ArticleFonts/`, the getting-started articles under `/start/` (see [articles.md](articles.md#on-the-site)), when the tag has them |

All of it is gitignored. The script runs `git archive` against the tag, so it works from a checkout
of any revision, and it fetches the tag itself when the clone doesn't have one, which is what CI
does. Set `TYPECASK_RELEASE_TAG` to build against a particular tag, as for a look at an unreleased
version.

Try It Out on a font page reads `site/data/webfonts.json`, the manifest `scripts/web-fonts.py` put on R2
for the fonts release the tag pins (`fontsTag` in `release.json`), and loads the font's WOFF2 faces
from `webFontsURL`, fonts.typecask.app, only once someone presses the button (`assets/js/try.js`). A
release with no manifest yet leaves the section out. The bucket's CORS rule lets typecask.app, and the
preview URLs (below), load them.

A font page's On your computer section gives the cask's `brew install --cask` command, which Homebrew runs
on Linux too since 4.5, unless the catalog marks the cask `homebrew: false` (the `EXTRA_CASKS` Homebrew
doesn't have). Then, without Homebrew, where to download it, and how to install the files on a Mac, on
Windows, and on Linux. The download is a Google family's Google Fonts page, from `googleFamily`, else the
cask's own archive or font file, from `download`: `build-catalog.py` sets it only for a zip, a tarball, or a
font file, not an installer, a disk image, or a 7-Zip archive. Anything else gets the font's home page. A
catalog from before those fields offers the command for every cask, knows a Google family only by its
homepage, and has no downloads.

What depends on the version follows it too. What's New (`content/_content.gotmpl`) exists only once the
live version has notes. `_partials/released.html` says whether the live version is at least a given one,
which gates Open in Typecask on `deepLinksSince`. Templates and styles still deploy as soon as they're
pushed, so anything new that needs a newer app has to check the version that way.

## Building it

```sh
scripts/site-catalog.sh          # from the repository root
cd site && hugo server
```

Hugo 0.170 or later. A full build is about three seconds for some 3,000 pages: one per cask, design style,
foundry, and designer, the catalog, the home page, and the documents.

Pages come from `content/fonts/_content.gotmpl`, a content adapter that emits one page per cask
straight out of `catalog.json`. There are no per-font Markdown files to maintain; a fonts release
changes the catalog and the pages follow.

Designers and foundries are taxonomies too, from each cask's `designers` and `foundries`, with an index
of each at `/designers/` and `/foundries/`. A catalog from before `scripts/makers.json` lists Google's credits,
people and foundries together, under `designers`, so the content adapter makes no maker pages for a catalog
without `foundries` and lists the names on each font's page as before. Hugo would capitalize term titles
(dtinth as "Dtinth"), so `capitalizeListTitles` is off and each taxonomy's index takes its title from
`content/<taxonomy>/_index.md`. Templates find a maker's page by title through `_partials/maker-pages.html`:
`site.GetPage` with a urlized path misses names like Łukasz Dziedzic. A content adapter in each of
`content/designers/` and `content/foundries/` (`_partials/maker-term-pages.html`) sets every maker's page
at the slug the articles link it by, `_partials/maker-slug.html`, rather than Hugo's, which keeps the dot in
andrey-v.-panov and the + in M+: the app's Share sends a maker's page by that slug.

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
the state in the query string. Words in a search are alternatives, so `rubik gidole` lists both, and
search reads descriptions too, from `fonts/search.*.json`: each description's distinct words, about
1 MB (180 KB compressed), which the page fetches the first time someone searches rather than carrying
it. Names that match come before descriptions that do. Without JavaScript the whole catalog is still there in the system
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
requests that touch it (build only, no deploy), every three hours for the App Store's version and
rating, and from the Actions tab.

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

The build is about 5,100 files and 89 MB, against Cloudflare's limits of 20,000 files per version
on the free plan and 25 MiB per file. The largest file is the catalog page at 1.1 MB, 110 KB over
the wire.

### Previewing an unreleased version

Cloudflare's preview URLs show a version of the site without deploying it. Build against the version's
`testflight-N` tag with the preview's address as the base URL, and upload it under an alias:

```sh
TYPECASK_RELEASE_TAG=testflight-21 scripts/site-catalog.sh
cd site && hugo --gc --minify --baseURL https://v1-2-typecask-site.marquard-org.workers.dev/
npx wrangler versions upload --preview-alias v1-2
```

It serves at `https://ALIAS-typecask-site.marquard-org.workers.dev`, with `X-Robots-Tag: noindex`, and
typecask.app keeps the App Store's version: an upload makes a version without deploying it. Uploading again
with the same alias moves it to the new version. Never preview with `wrangler deploy`, which replaces
typecask.app.

- `preview_urls = true` in `site/wrangler.toml` keeps preview URLs on through CI's deploys, and
  `workers_dev = false` keeps the Worker's plain workers.dev address off.
- It runs locally, after `npx wrangler login`. The Site workflow only deploys.
- The fonts bucket's CORS rule allows `https://*.marquard-org.workers.dev`, so Try It Out works there too.
- `site-catalog.sh` takes the articles from the tag. To preview article edits a tag doesn't have yet, copy
  `Typecask/Articles.json` over `site/data/articles.json` before `hugo`; a changed specimen line also needs
  `scripts/articles.py web site/static/a` after copying `Typecask/ArticleFonts/` there.

## Things that are set, and where

`site/hugo.toml` holds the lot:

- `appStoreID` is 6826936046 and `appStoreLive` is true, so the download buttons are Apple's
  "Download on the App Store" badge (`assets/img/app-store-badge.svg`, from Apple's marketing tools,
  unaltered) and Safari shows its Smart App Banner. With it false they point at `testflightURL`, or
  read "Coming to the App Store" when that's empty, and never render a link to a listing that isn't
  public.
- `deepLinksSince` is the first version that opens `typecask://font/TOKEN`. Once the App Store has it,
  each font page offers Open in Typecask, on touch devices only; until then it says to search the app.
  The Smart App Banner needs no gate: it hands the app the page's own URL as `app-argument`, which 1.1
  opens and earlier versions ignore.
- `_partials/app-store.html` reads the app's US rating from Apple's lookup API
  (`itunes.apple.com/lookup`) at build time, which the three-hourly rebuild keeps current. The home page
  shows it under the badge once there is one, and a failed lookup only drops it, with a warning.
- `_partials/structured-data.html` writes JSON-LD for Google: `WebSite` and `MobileApplication`,
  with the rating as `aggregateRating`, on the home page, and `BreadcrumbList` on font and style
  pages. Google shows the app as a rich result only with a rating, and wants the rating visible on
  the page, which is why the home page shows it.
- The Smart App Banner passes the page's URL as `app-argument`. The app doesn't read it yet; when it
  does, a font page's banner can open that font.
- `cloudflareAnalyticsToken` is empty until the site is live. With it set, production builds load
  Cloudflare Web Analytics, which is cookieless and is what `/privacy/` describes. Local and preview
  builds load no script at all.
- `supportEmail` is empty, so `/support/` points at GitHub Issues only.

The site is dark only, from the app icon: near-black, cream, one orange. The chrome is set in the
system face, so the specimens are the only typography on the page and a site whose selling point is
that nothing is collected makes no third-party font request.
