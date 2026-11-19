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
scripts/articles.py build    # after changing anything in articles/
scripts/articles.py check    # what CI runs
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
```

- `order` sets the order on the Start Here page. The articles are evergreen, so nothing rotates.
- A specimen line is `@TOKEN: text`, on its own between blank lines. Settings in braces pick axis
  values (`wght=900`) and turn features on or off (`+ss01`, `-liga`).
- Collections are FontCollection's cases, spelled as in Swift: `monospaced`, `sansSerif`, `legibility`,
  `nerdFonts`, `halloween` and so on.
- No lists, quotes, code, images or HTML. The app draws inline Markdown only, so anything more would look
  different in the app and on the site, and `check` refuses it.

`check` fails when a specimen or link names a cask the catalog doesn't have. It runs on fonts pull
requests too, so a fonts release that drops a featured font fails Checks: swap the font in the article,
rebuild, and push to the fonts branch.
