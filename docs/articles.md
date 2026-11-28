# Articles

The getting-started articles, like "Start here: a tasting flight", introduce a handful of fonts at a time,
each set in its own face. The app opens on them the first time it's launched, and the site publishes the
same articles under `/start/`.

## Where they live

Each article is a Markdown file in `articles/`, named by its slug: `articles/start-here.md` becomes
`/start/start-here/` on the site. Drafts can start anywhere, Claude Docs included, but the file in the
repository is the article. `scripts/articles.py build` turns the lot into `Typecask/Articles.json`, which the
app bundles and the site reads from the release tag, so both show the articles of the version people have.

```sh
python3 scripts/memcap.py 14 scripts/articles.py fonts   # after changing a specimen line
scripts/articles.py build                                # after changing only prose
scripts/articles.py check                                # what CI runs
```

## The format

```markdown
---
title: Start here: a tasting flight
summary: One line for the article's card.
order: 1
---

A paragraph. Lines wrap freely; a blank line ends it. **Bold**, *italic*, and links to a collection
([Serif](collection:serif)), a font ([Inter](font:font-inter)), a type term ([x-height](term:x-height)),
another article ([Workhorses](article:workhorses)), a foundry or a designer
([Arrow Type](foundry:arrow-type), [Stephen Nixon](designer:stephen-nixon)), or an https:// address.

## A section heading

@font-inter: The font you’ll forget you picked
@font-fraunces {wght=900 WONK=1 +ss01 -liga}: Wonky, warm and a little goofy
@font-inter {face=InterVariableItalic}: A face other than the cask's primary one

@font-amiri: مرحبا بالعالم
= Hello, world

@apple:Papyrus: A line in a family built into iOS
```

- `order` sets the order on the Start Here page. The articles are evergreen, so nothing rotates.
- A specimen line is `@TOKEN: text`, on its own between blank lines. Settings in braces pick axis
  values (`wght=900`), turn features on or off (`+ss01`, `-liga`), and pick a face by its asset name.
- `@apple:NAME:` sets a line in one of Apple's families built into iOS, by its name in `AppleFonts.json`, and
  `[Papyrus](apple:Papyrus)` links one. The device has the face, so nothing is cut and the line takes no
  settings. The app draws it in that face and opens the family's page; the site, which keeps Apple's fonts
  off, asks for the reader's own copy and links nothing.
- A line starting `=` right under a specimen is its translation, for a line in another language. It's
  plain text, set small under the line in the system font, so the line's font doesn't need its letters.
- A foundry or designer link names the maker as the catalog does, by a slug: the name in lower case, with
  each run of anything but letters and digits a hyphen, so Paul D. Hunt is `designer:paul-d-hunt`. Both open
  the maker's page, in the app and on the site. Link a maker's first mention in an article; a name inside a
  font's own, like the Intel of Intel One Mono, stays plain.
- An https:// link is for the site alone, like the Wikipedia page of a classic typeface. The app draws its
  words as plain text, so every link there stays in the app: to a font, a collection, a maker, another
  article, or a term.
- Collections are FontCollection's cases, spelled as in Swift: `monospaced`, `sansSerif`, `legibility`,
  `nerdFonts`, `halloween` and so on.
- No lists, quotes, code, images or HTML. The app draws inline Markdown only, so anything more would look
  different in the app and on the site, and `check` refuses it.

## The glossary

`articles/glossary.md` isn't an article: it defines the type terms the articles use, each a `## Term` heading
and one paragraph, with no links. A `term:` link names a term by its slug, the heading in lowercase with
hyphens for anything else, so `## Slab serif` is `term:slab-serif`. `build` writes the terms into
`Articles.json` beside the articles, and `check` fails on a link to a term the glossary doesn't define.

In the app a term link has a dotted underline, like an `<abbr>`, and shows the definition in a popover
pointing at it, a popover on iPhone too, so the reader stays in the article. A popover on the paragraph's
Text would point at the paragraph, so each term link carries a `TextAttribute`, and a clear view laid over
its run in the text layout carries its popover (`ArticleParagraph`). The site draws it as an `<abbr>` with
the definition as its title, plus a popover a tap opens, since touch screens never show a title.

`check` fails when a specimen or link names a cask the catalog doesn't have. It runs on fonts pull
requests too, so a fonts release that drops a featured font fails Checks: swap the font in the article,
rebuild, and push to the fonts branch.

## The specimen fonts

A preview font holds only the gallery's sample, about fifty glyphs, so it can't set a line like "The font
you'll forget you picked". `articles.py fonts` cuts a font for each line instead: the face subset to the
line's characters and the features they reach, instanced at its axis values, and renamed
`TypecaskArticle-HASH`, since an OFL font's Reserved Font Name can't go on a modified copy. HASH is of the
line and its settings, so editing a line recuts only its font, and a font no line uses is removed. They go
in `Typecask/ArticleFonts/`, a few KB each, and are checked in.

`fonts` reads the full faces from `Typecask/Fonts.xcassets`, or `--from` another, such as the main
checkout's from a worktree. It needs the faces of the fonts release the catalog pins: an older
`Fonts.xcassets` lacks the casks added since. It shapes each line with HarfBuzz in both the full face and the cut and fails
where they differ, which is a ligature or alternate the cut lost. Each cut keeps its source's version
string, and `check` warns when the catalog's has moved on: rerun `fonts` against that fonts release.

## In the app

The app opens on Start Here the first time: the articles as cards, each its title and summary. On
iPad it's the sidebar's first row. After that the app reopens where it was, the root and every page
pushed over it, saved as `lastPage` in user defaults (`start|article:start-here|font:font-inter`), as
far as it can still find them. The UI tests pass `-lastPage collection:allFonts` so they begin on All Fonts.

A specimen line sits in a shaded box with the font's name inside it, above the line, and the box opens the font's page.
So does the font's first mention in the paragraph after it, which `build` links by itself (`font:` link,
bold kept outside it, since SwiftUI drops bold inside a link), unless the paragraph already links the font. A `collection:` link shows that collection, a `font:` or `article:` link pushes
that page over the article, and an https:// link is plain text. `typecask://start/SLUG` and
typecask.app/start/SLUG/, which the Smart App Banner hands the app, open an article over Start Here, and
`typecask://start` opens Start Here itself; an article the app doesn't have yet opens Start Here.

## On the site

`scripts/site-catalog.sh` copies `Articles.json` and `ArticleFonts/` from the release tag, as it does the
catalog, into `site/data/articles.json` and `site/static/a/`. `content/start/_content.gotmpl` makes
`/start/` and a page per article from them, and `layouts/start/` lays them out as the app does: shaded
boxes, the font's name above its line and a link to its page, and the translation under it. The cut fonts
are served as WOFF2, which `articles.py web` makes of the release's cuts, a few KB each. A release from before the articles has none, so `/start/` and its
link in the header appear with the first App Store version that has them, and Open in Typecask needs no
version check of its own.

`layouts/_markup/render-link.html` turns the articles' links into the site's: `font:` to the font's page,
`article:` to another article, `collection:` to a design style's page or Nerd Fonts (the app's other
collections, like Legibility, have no page, so their words stay plain), and `term:` to an `<abbr>` whose
title is the definition, which `assets/js/terms.js` shows in a popover on a tap.
