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
([Serif](collection:serif)), a font ([Inter](font:font-inter)) or an https:// address.

## A section heading

@font-inter: The font you’ll forget you picked
@font-fraunces {wght=900 WONK=1 +ss01 -liga}: Wonky, warm and a little goofy
@font-inter {face=InterVariableItalic}: A face other than the cask's primary one
```

- `order` sets the order on the Start Here page. The articles are evergreen, so nothing rotates.
- A specimen line is `@TOKEN: text`, on its own between blank lines. Settings in braces pick axis
  values (`wght=900`), turn features on or off (`+ss01`, `-liga`), and pick a face by its asset name.
- Collections are FontCollection's cases, spelled as in Swift: `monospaced`, `sansSerif`, `legibility`,
  `nerdFonts`, `halloween` and so on.
- No lists, quotes, code, images or HTML. The app draws inline Markdown only, so anything more would look
  different in the app and on the site, and `check` refuses it.

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
checkout's from a worktree. It shapes each line with HarfBuzz in both the full face and the cut and fails
where they differ, which is a ligature or alternate the cut lost. Each cut keeps its source's version
string, and `check` warns when the catalog's has moved on: rerun `fonts` against that fonts release.

## In the app

The app opens on Start Here the first time: the articles as cards, each showing its first few lines. On
iPad it's the sidebar's first row. After that the app reopens where it was, the root and every page
pushed over it, saved as `lastPage` in user defaults (`start|article:start-here|font:font-inter`), as
far as it can still find them. The UI tests pass `-lastPage collection:allFonts` so they begin on All Fonts.

A specimen line sits in a shaded box with the font's name inside it, and the box opens the font's page.
So does the font's first mention in the paragraph after it, which `build` links by itself (`font:` link,
bold kept outside it, since SwiftUI drops bold inside a link), unless the paragraph already links the font. A `collection:` link shows that collection, a `font:` link pushes
the font's page over the article, and an https:// link opens in Safari.
