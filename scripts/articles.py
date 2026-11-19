#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Writes Typecask/Articles.json, the getting-started articles, from the Markdown in articles/.

    scripts/articles.py build     # write Typecask/Articles.json
    scripts/articles.py check     # validate, and fail if Articles.json is out of date

The app's Start Here page and the site's /start/ pages both read Articles.json, so the two never disagree.
Each article is one file, articles/SLUG.md: front matter, then blocks separated by blank lines.

    ---
    title: Start here: a tasting flight
    summary: One line for the article's card.
    order: 1
    ---

    A paragraph, with **bold**, *italic* and links: [Serif](collection:serif), [Inter](font:font-inter),
    or an https:// address.

    ## A section heading

    @font-inter: A specimen line, set in the cask's own face
    @font-fraunces {wght=900 WONK=1 +ss01 -liga}: Axis values, and features on (+) or off (-)

Every font a specimen or link names has to be in Typecask/Catalog.json, so a fonts release that drops a
cask fails this check rather than shipping an article that points at nothing. Collections are the ones
FontCollection in Typecask/DesignStyle.swift has.
"""

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "articles"
OUTPUT = ROOT / "Typecask" / "Articles.json"
CATALOG = ROOT / "Typecask" / "Catalog.json"

# FontCollection's cases, by the raw values of DesignStyle and Holiday for the ones that take them.
STYLES = {"monospaced", "serif", "sansSerif", "display", "handwriting"}
HOLIDAYS = {"lunarNewYear", "valentinesDay", "halloween", "diwali", "christmas"}
COLLECTIONS = (
    {"allFonts", "installed", "nerdFonts", "ligatures", "legibility", "symbols", "appleFonts"} | STYLES | HOLIDAYS
)

FRONT_MATTER = {"title", "summary", "order"}
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
SPECIMEN = re.compile(r"@(?P<token>\S+?)(?:\s+\{(?P<settings>[^}]*)\})?:\s+(?P<text>.+)")
LINK = re.compile(r"\[(?P<text>[^\]]+)\]\((?P<target>[^)\s]+)\)")
AXIS = re.compile(r"(?P<tag>[A-Za-z0-9]{4})=(?P<value>-?\d+(?:\.\d+)?)")
FEATURE = re.compile(r"(?P<sign>[+-])(?P<tag>[A-Za-z0-9]{4})")


class ArticleError(Exception):
    pass


def parse(path, tokens):
    """One article, as Articles.json carries it, or ArticleError naming every problem in the file."""
    problems = []
    slug = path.stem
    if not SLUG.fullmatch(slug):
        problems.append(f"the file name {path.name} isn't a slug: lowercase letters, digits and hyphens")
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        raise ArticleError(f"{path.name}: no front matter between --- lines")
    end = lines.index("---", 1)
    meta = {}
    for number, line in enumerate(lines[1:end], start=2):
        key, separator, value = line.partition(": ")
        if not separator or key not in FRONT_MATTER:
            problems.append(f"line {number}: front matter takes {', '.join(sorted(FRONT_MATTER))}, one per line")
        elif key in meta:
            problems.append(f"line {number}: {key} given twice")
        else:
            meta[key] = value.strip()
    problems += [f"front matter has no {key}" for key in sorted(FRONT_MATTER - meta.keys())]
    if "order" in meta and not meta["order"].isdigit():
        problems.append(f"order is {meta['order']!r}, not a whole number")

    blocks = []
    for number, chunk in chunks(lines, end + 1):
        try:
            blocks.append(block(chunk, tokens))
        except ArticleError as error:
            problems.append(f"line {number}: {error}")
    if not any(b["kind"] == "specimen" for b in blocks):
        problems.append("no specimens: an article is for showing fonts")
    if problems:
        raise ArticleError("\n".join(f"{path.name}: {problem}" for problem in problems))
    return {
        "slug": slug,
        "title": meta["title"],
        "summary": inline(meta["summary"], tokens),
        "order": int(meta["order"]),
        "blocks": blocks,
    }


def chunks(lines, start):
    """The body's blocks, each with the number of its first line, split at blank lines."""
    chunk, first = [], None
    for number, line in enumerate(lines[start:], start=start + 1):
        if line.strip():
            if not chunk:
                first = number
            chunk.append(line.strip())
        elif chunk:
            yield first, chunk
            chunk = []
    if chunk:
        yield first, chunk


def block(chunk, tokens):
    head = chunk[0]
    if head.startswith("#"):
        if len(chunk) > 1 or not head.startswith("## ") or head.startswith("###"):
            raise ArticleError("a heading is one line starting ## (the title is the front matter's)")
        return {"kind": "heading", "text": inline(head[3:].strip(), tokens)}
    if head.startswith("@"):
        if len(chunk) > 1:
            raise ArticleError("a specimen is one line, with a blank line after it")
        return specimen(head, tokens)
    if any(line.startswith(("@", "#")) for line in chunk[1:]):
        raise ArticleError("a heading or specimen needs a blank line before it")
    if re.match(r"([-*+>]|\d+[.)])\s", head):
        raise ArticleError("a list or quote, which the site would draw and the app wouldn't")
    return {"kind": "paragraph", "text": inline(" ".join(chunk), tokens)}


def specimen(line, tokens):
    match = SPECIMEN.fullmatch(line)
    if not match:
        raise ArticleError("a specimen reads @TOKEN: text, or @TOKEN {settings}: text")
    token, text = match["token"], match["text"].strip()
    if token not in tokens:
        raise ArticleError(f"{token} isn't in the catalog")
    result = {"kind": "specimen", "token": token, "text": text}
    axes, features = {}, {}
    for setting in (match["settings"] or "").split():
        if axis := AXIS.fullmatch(setting):
            value = float(axis["value"])
            axes[axis["tag"]] = int(value) if value.is_integer() else value
        elif feature := FEATURE.fullmatch(setting):
            features[feature["tag"]] = feature["sign"] == "+"
        else:
            raise ArticleError(f"{setting!r} is neither an axis (wght=700) nor a feature (+ss01, -liga)")
    if axes:
        result["axes"] = dict(sorted(axes.items()))
    if features:
        result["features"] = dict(sorted(features.items()))
    return result


def inline(text, tokens):
    """Text the app's AttributedString(markdown:) and Hugo's markdownify both read the same way: bold,
    italic and links, and nothing that one of them would draw differently."""
    for target in (match["target"] for match in LINK.finditer(text)):
        scheme, _, rest = target.partition(":")
        if scheme == "collection" and rest not in COLLECTIONS:
            raise ArticleError(f"no collection {rest!r}; collections are {', '.join(sorted(COLLECTIONS))}")
        if scheme == "font" and rest not in tokens:
            raise ArticleError(f"{rest} isn't in the catalog")
        if scheme not in {"collection", "font", "https"}:
            raise ArticleError(f"link to {target}: links go to collection:, font: or https://")
    bare = LINK.sub(r"\g<text>", text)
    if "](" in bare or "![" in text:
        raise ArticleError("a link that doesn't parse, or an image")
    if re.search(r"<[A-Za-z/!]", bare):
        raise ArticleError("HTML, which the app wouldn't draw")
    if "`" in bare or bare.count("**") % 2:
        raise ArticleError("code, or an unclosed **")
    return text


def build():
    tokens = {cask["token"] for cask in json.loads(CATALOG.read_text(encoding="utf-8"))["casks"]}
    articles, problems = [], []
    for path in sorted(SOURCE.glob("*.md")):
        try:
            articles.append(parse(path, tokens))
        except ArticleError as error:
            problems.append(str(error))
    orders = sorted(article["order"] for article in articles)
    problems += [f"two articles have order {order}" for order in sorted(set(orders)) if orders.count(order) > 1]
    if problems:
        raise ArticleError("\n".join(problems))
    articles.sort(key=lambda article: (article["order"], article["slug"]))
    return json.dumps({"articles": articles}, ensure_ascii=False, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("build", help="write Typecask/Articles.json")
    commands.add_parser("check", help="validate the articles, and that Articles.json matches them")
    command = parser.parse_args().command
    try:
        text = build()
    except ArticleError as error:
        sys.exit(str(error))
    if command == "build":
        OUTPUT.write_text(text, encoding="utf-8")
        print(f"wrote {OUTPUT.relative_to(ROOT)}")
    elif not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != text:
        sys.exit(f"{OUTPUT.relative_to(ROOT)} doesn't match articles/: run scripts/articles.py build")


if __name__ == "__main__":
    main()
