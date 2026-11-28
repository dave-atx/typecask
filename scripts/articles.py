#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["brotli==1.2.0", "fonttools==4.67.0", "lxml==6.0.2", "uharfbuzz==0.51.1"]
# ///
"""Writes Typecask/Articles.json, the getting-started articles, from the Markdown in articles/, and the fonts
their specimen lines are set in.

    scripts/articles.py fonts [--from XCASSETS]   # cut each specimen's font, then build
    scripts/articles.py build                     # write Typecask/Articles.json
    scripts/articles.py check                     # what CI runs: validate, and fail if anything is stale
    scripts/articles.py web FONTS                 # the site's copies of the cut fonts in FONTS, as WOFF2

The app's Start Here page and the site's /start/ pages both read Articles.json, so the two never disagree.
Each article is one file, articles/SLUG.md: front matter, then blocks separated by blank lines.

    ---
    title: Start here: a tasting flight
    summary: One line for the article's card.
    order: 1
    ---

    A paragraph, with **bold**, *italic* and links: [Serif](collection:serif), [Inter](font:font-inter),
    a term from the glossary ([x-height](term:x-height)), another article ([Workhorses](article:workhorses)),
    a foundry or a designer ([Arrow Type](foundry:arrow-type), [Stephen Nixon](designer:stephen-nixon)), or
    an https:// address, which only the site shows as a link: the app keeps to its own pages.

    ## A section heading

    @font-inter: A specimen line, set in the cask's own face
    @font-fraunces {wght=900 WONK=1 +ss01 -liga face=Fraunces-9ptBlackItalic}: Axis values, features on (+)
    or off (-), and a face other than the cask's primary one, by its asset name
    @font-amiri: مرحبا بالعالم
    = Hello, world (a line under a specimen, starting =, is its translation, set small in the system font)
    @apple:Papyrus: A line in an Apple family built into iOS, which isn't cut, and links as apple:Papyrus

articles/glossary.md isn't an article: it defines the type terms the articles link with term:, which the app
shows in a popover and the site in an <abbr>. Each term is a ## heading and one paragraph; the link names it
by its slug, the heading in lowercase with hyphens for anything else ("Slab serif" is term:slab-serif).

Every font a specimen or link names has to be in Typecask/Catalog.json, so a fonts release that drops a
cask fails this check rather than shipping an article that points at nothing. Collections are the ones
FontCollection in Typecask/DesignStyle.swift has.

A preview font holds only the gallery's sample, so a specimen line has a font of its own: the face subset
to the line's characters and the features they reach, instanced at its axis values, and renamed
TypecaskArticle-HASH (an OFL font's Reserved Font Name can't go on a modified copy), in
Typecask/ArticleFonts/. HASH is of the line and its settings, so editing one line recuts only its font.
`fonts` reads the full faces from a Fonts.xcassets, Typecask/Fonts.xcassets unless --from names another,
and shapes each line with HarfBuzz in both the full face and the cut, failing where they differ: a
ligature or alternate the cut lost. Run it under the memory cap, as the other font scripts:

    python3 scripts/memcap.py 14 scripts/articles.py fonts

Each cut carries its source's version string, and `check` warns when the catalog's has moved on, since
a fonts release can change a face; rerun `fonts` against that release to bring them up to date.
"""

import argparse
import functools
import hashlib
import itertools
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "articles"
GLOSSARY = SOURCE / "glossary.md"
OUTPUT = ROOT / "Typecask" / "Articles.json"
CATALOG = ROOT / "Typecask" / "Catalog.json"
FONTS = ROOT / "Typecask" / "ArticleFonts"
XCASSETS = ROOT / "Typecask" / "Fonts.xcassets"
APPLE_FONTS = ROOT / "Typecask" / "AppleFonts.json"
FONT_SUFFIXES = (".ttf", ".otf")

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
FACE = re.compile(r"face=(?P<name>\S+)")


class ArticleError(Exception):
    pass


def load_catalog():
    return {cask["token"]: cask for cask in json.loads(CATALOG.read_text(encoding="utf-8"))["casks"]}


@functools.cache
def apple_families():
    """The names of the Apple families built into iOS, which an article can set a line in or link with
    apple:NAME. A downloadable one isn't on the reader's device to draw with."""
    return frozenset(family["name"] for family in json.loads(APPLE_FONTS.read_text()) if family["builtIn"])


def maker_slug(name):
    """A foundry's or a designer's name as a link names it, "foundry:the-league-of-moveable-type": lower case,
    with each run of anything but letters and digits a hyphen. The app and the site's render-link.html slug
    names the same way to find the page."""
    return re.sub(r"[\W_]+", "-", name.lower()).strip("-")


@functools.cache
def maker_slugs():
    """Each kind of maker's slugs, from the catalog's foundries and designers."""
    casks = load_catalog().values()
    return {
        kind: {maker_slug(name) for cask in casks for name in cask.get(field, [])}
        for kind, field in (("foundry", "foundries"), ("designer", "designers"))
    }


def term_slug(term):
    return re.sub(r"[^a-z0-9]+", "-", term.lower()).strip("-")


def read_glossary(tokens):
    """The glossary's terms by slug, each its name and its definition, in inline Markdown."""
    if not GLOSSARY.exists():
        return {}
    terms, problems = {}, []
    for number, chunk in chunks(GLOSSARY.read_text(encoding="utf-8").splitlines(), 0):
        head = chunk[0]
        if head.startswith("# ") and not terms and number == 1:
            continue  # the page's own title
        if head.startswith("## "):
            if len(chunk) > 1:
                problems.append(f"line {number}: a term's heading is one line, with its definition after a blank line")
                continue
            name = head[3:].strip()
            slug = term_slug(name)
            if slug in terms:
                problems.append(f"line {number}: {name!r} is defined twice")
            terms[slug] = {"term": name, "definition": None}
            continue
        last = next(reversed(terms), None)
        if last is None or terms[last]["definition"] is not None:
            problems.append(f"line {number}: a definition needs a ## heading naming its term before it")
            continue
        try:
            # A definition sits in a popover, so it links nowhere.
            text = inline(" ".join(chunk), tokens, {})
            if LINK.search(text):
                raise ArticleError("a definition takes no links")
            terms[last]["definition"] = text
        except ArticleError as error:
            problems.append(f"line {number}: {error}")
    problems += [f"{entry['term']!r} has no definition" for entry in terms.values() if entry["definition"] is None]
    if problems:
        raise ArticleError("\n".join(f"{GLOSSARY.name}: {problem}" for problem in problems))
    return dict(sorted(terms.items()))


def parse(path, tokens, terms, slugs):
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
            blocks.append(block(chunk, tokens, terms, slugs))
        except ArticleError as error:
            problems.append(f"line {number}: {error}")
    if not any(b["kind"] == "specimen" for b in blocks):
        problems.append("no specimens: an article is for showing fonts")
    if problems:
        raise ArticleError("\n".join(f"{path.name}: {problem}" for problem in problems))
    return {
        "slug": slug,
        "title": meta["title"],
        "summary": inline(meta["summary"], tokens, terms, slugs),
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


def block(chunk, tokens, terms, slugs):
    head = chunk[0]
    if head.startswith("#"):
        if len(chunk) > 1 or not head.startswith("## ") or head.startswith("###"):
            raise ArticleError("a heading is one line starting ## (the title is the front matter's)")
        return {"kind": "heading", "text": inline(head[3:].strip(), tokens, terms, slugs)}
    if head.startswith("@"):
        if len(chunk) > 2 or (len(chunk) == 2 and not chunk[1].startswith("= ")):
            raise ArticleError("a specimen is one line, and maybe its translation (= ...), with a blank line after")
        result = specimen(head, tokens)
        if len(chunk) == 2:
            # Plain text: it sits under the line in the system font, and the font's cut doesn't need it.
            result["gloss"] = chunk[1][2:].strip()
            if not result["gloss"] or re.search(r"[*_\[\]<`]", result["gloss"]):
                raise ArticleError("a translation is plain text, with no Markdown")
        return result
    if any(line.startswith(("@", "#")) for line in chunk[1:]):
        raise ArticleError("a heading or specimen needs a blank line before it")
    if re.match(r"([-*+>]|\d+[.)])\s", head):
        raise ArticleError("a list or quote, which the site would draw and the app wouldn't")
    return {"kind": "paragraph", "text": inline(" ".join(chunk), tokens, terms, slugs)}


def specimen(line, tokens):
    match = SPECIMEN.fullmatch(line)
    if not match:
        raise ArticleError("a specimen reads @TOKEN: text, or @TOKEN {settings}: text")
    token, text = match["token"], match["text"].strip()
    if token.startswith("apple:"):
        # Set in the family's own face, which the device already has: nothing to cut, and no settings.
        family = token.removeprefix("apple:")
        if family not in apple_families():
            raise ArticleError(f"{family} isn't one of the Apple families built into iOS")
        if match["settings"]:
            raise ArticleError("an Apple family's line takes no settings")
        return {"kind": "specimen", "token": token, "apple": family, "text": text}
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
        elif face := FACE.fullmatch(setting):
            result["face"] = face["name"]
        else:
            raise ArticleError(f"{setting!r} is neither an axis (wght=700), a feature (+ss01, -liga) nor face=NAME")
    if axes:
        result["axes"] = dict(sorted(axes.items()))
    if features:
        result["features"] = dict(sorted(features.items()))
    key = json.dumps(result, ensure_ascii=False, sort_keys=True)
    result["font"] = "TypecaskArticle-" + hashlib.sha256(key.encode()).hexdigest()[:12]
    return result


def inline(text, tokens, terms, slugs=frozenset()):
    """Text the app's AttributedString(markdown:) and Hugo's markdownify both read the same way: bold,
    italic and links, and nothing that one of them would draw differently."""
    for target in (match["target"] for match in LINK.finditer(text)):
        scheme, _, rest = target.partition(":")
        if scheme == "collection" and rest not in COLLECTIONS:
            raise ArticleError(f"no collection {rest!r}; collections are {', '.join(sorted(COLLECTIONS))}")
        if scheme == "font" and rest not in tokens:
            raise ArticleError(f"{rest} isn't in the catalog")
        if scheme == "apple" and rest not in apple_families():
            raise ArticleError(f"{rest} isn't one of the Apple families built into iOS")
        if scheme == "term" and rest not in terms:
            raise ArticleError(f"no term {rest!r} in {GLOSSARY.name}")
        if scheme == "article" and rest not in slugs:
            raise ArticleError(f"no article {rest!r} in {SOURCE.name}/")
        if scheme in {"foundry", "designer"} and rest not in maker_slugs()[scheme]:
            raise ArticleError(f"no {scheme} {rest!r} in the catalog")
        if scheme not in {"collection", "font", "apple", "term", "article", "foundry", "designer", "https"}:
            raise ArticleError(
                f"link to {target}: links go to collection:, font:, apple:, term:, article:, foundry:, designer: "
                "or https://"
            )
    bare = LINK.sub(r"\g<text>", text)
    if "](" in bare or "![" in text:
        raise ArticleError("a link that doesn't parse, or an image")
    if re.search(r"<[A-Za-z/!]", bare):
        raise ArticleError("HTML, which the app wouldn't draw")
    if "`" in bare or bare.count("**") % 2:
        raise ArticleError("code, or an unclosed **")
    return text


def read_articles(catalog, terms):
    articles, problems = [], []
    paths = [path for path in sorted(SOURCE.glob("*.md")) if path != GLOSSARY]
    slugs = frozenset(path.stem for path in paths)
    for path in paths:
        try:
            articles.append(parse(path, catalog.keys(), terms, slugs))
        except ArticleError as error:
            problems.append(str(error))
    orders = sorted(article["order"] for article in articles)
    problems += [f"two articles have order {order}" for order in sorted(set(orders)) if orders.count(order) > 1]
    if problems:
        raise ArticleError("\n".join(problems))
    for article in articles:
        link_first_mentions(article, catalog)
    return sorted(articles, key=lambda article: (article["order"], article["slug"]))


def link_first_mentions(article, catalog):
    """Links the font's first mention in the paragraph after its specimen line to the font, so its name
    opens its page as the line does, in the app and on the site. A paragraph that already links the font,
    or doesn't name it, is left alone."""
    blocks = article["blocks"]
    for item, following in itertools.pairwise(blocks):
        if item["kind"] != "specimen" or following["kind"] != "paragraph":
            continue
        if "apple" in item:
            name, target = item["apple"], f"apple:{item['apple']}"
        else:
            name, target = catalog[item["token"]]["name"], f"font:{item['token']}"
        text = following["text"]
        if f"({target})" in text:
            continue
        links = [match.span() for match in LINK.finditer(text)]
        for mention in (f"**{name}**", name):
            start = next(
                (i for i in find_all(text, mention) if not any(a <= i < b for a, b in links)),
                None,
            )
            if start is not None:
                end = start + len(mention)
                # Bold outside the link: SwiftUI drops bold inside a link's text.
                link = f"**[{name}]({target})**" if mention.startswith("**") else f"[{name}]({target})"
                following["text"] = f"{text[:start]}{link}{text[end:]}"
                break


def find_all(text, part):
    start = text.find(part)
    while start >= 0:
        yield start
        start = text.find(part, start + 1)


def specimens(articles):
    """The specimen lines that have a cut font of their own: all but those set in an Apple family."""
    return [b for article in articles for b in article["blocks"] if b["kind"] == "specimen" and "apple" not in b]


def font_file(name):
    """The cut's file, .ttf or .otf, which depends on its source's outlines; None if it hasn't been cut."""
    return next((path for suffix in FONT_SUFFIXES if (path := FONTS / (name + suffix)).exists()), None)


def render(articles, terms):
    """Articles.json, with each specimen's font named by its file. A specimen with no cut yet is an error:
    the app would draw it in the system font."""
    missing = []
    for item in specimens(articles):
        if path := font_file(item["font"]):
            item["font"] = path.name
        else:
            missing.append(f"{item['token']}: {item['text']!r}")
    if missing:
        raise ArticleError(
            "no font cut for these lines; run scripts/articles.py fonts:\n" + "\n".join(f"  {m}" for m in missing)
        )
    return json.dumps({"articles": articles, "terms": terms}, ensure_ascii=False, indent=2) + "\n"


def source_face(xcassets, cask, face):
    """The full face's file and the face's number in it, from the asset catalog's dataset."""
    from fontTools.ttLib import TTCollection

    dataset = xcassets / cask["token"] / f"{face}.dataset"
    contents = dataset / "Contents.json"
    if not contents.exists():
        raise ArticleError(f"{cask['token']}: no {face} in {xcassets}; faces are {', '.join(sorted(cask['assets']))}")
    path = dataset / json.loads(contents.read_text())["data"][0]["filename"]
    if path.suffix.lower() not in {".ttc", ".otc"}:
        return path, 0
    # A collection's dataset is named by its first face, as build-catalog.py names the cask's assets.
    with TTCollection(path, lazy=True) as collection:
        for number, font in enumerate(collection.fonts):
            if font["name"].getDebugName(6) == face:
                return path, number
    return path, 0


def shaped(path, number, text, axes, features):
    """How HarfBuzz sets the line: each glyph's cluster and advance, which a lost ligature or alternate
    changes, though glyph ids differ between a face and its cut."""
    import uharfbuzz

    font = uharfbuzz.Font(uharfbuzz.Face(uharfbuzz.Blob.from_file_path(str(path)), number))
    if axes:
        font.set_variations(axes)
    buffer = uharfbuzz.Buffer()
    buffer.add_str(text)
    buffer.guess_segment_properties()
    uharfbuzz.shape(font, buffer, features)
    return [(info.cluster, position.x_advance) for info, position in zip(buffer.glyph_infos, buffer.glyph_positions)]


def cut(item, cask, xcassets):
    """Subsets the specimen's face to its line and writes it to FONTS; returns the file."""
    from fontTools.subset import Options, Subsetter
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    name = item["font"]
    path, number = source_face(xcassets, cask, item.get("face", cask["primaryFont"]))
    text, features = item["text"], item.get("features", {})
    with TTFont(path, fontNumber=number, lazy=True, recalcTimestamp=False) as font:
        version = (font["name"].getDebugName(5) or "").strip()
        location = {}
        if "fvar" in font:
            unknown = set(item.get("axes", {})) - {axis.axisTag for axis in font["fvar"].axes}
            if unknown:
                raise ArticleError(f"{cask['token']} has no axis {', '.join(sorted(unknown))}")
            location = {a.axisTag: item.get("axes", {}).get(a.axisTag, a.defaultValue) for a in font["fvar"].axes}
        elif item.get("axes"):
            raise ArticleError(f"{cask['token']} isn't variable, so it takes no axis values")
        options = Options()
        options.layout_features += sorted(tag for tag, on in features.items() if on)
        # As the previews: no hinting, which Core Text doesn't run, except in a CFF2 variable font, whose
        # stripped hints the instancer fails on.
        options.hinting = "CFF2" in font and "fvar" in font
        options.name_IDs = ["*"]
        options.drop_tables += ["BASE"]
        subsetter = Subsetter(options)
        subsetter.populate(text=text)
        subsetter.subset(font)
        if location:
            instantiateVariableFont(font, location, inplace=True)
        if "STAT" in font:
            del font["STAT"]
        font["name"].names = []
        for name_id, value in ((1, name), (2, "Regular"), (4, name), (5, version), (6, name)):
            font["name"].setName(value, name_id, 3, 1, 0x409)
        if "CFF " in font:
            font["CFF "].cff.fontNames = [name]
        destination = FONTS / f"{name}{'.otf' if 'CFF ' in font or 'CFF2' in font else '.ttf'}"
        font.save(destination)
    if shaped(path, number, text, location, features) != shaped(destination, 0, text, {}, features):
        raise ArticleError(f"{cask['token']}: {text!r} shapes differently in the cut than in the full face")
    return destination


def cut_fonts(xcassets):
    catalog = load_catalog()
    articles = read_articles(catalog, read_glossary(catalog.keys()))
    FONTS.mkdir(exist_ok=True)
    wanted = set()
    for item in specimens(articles):
        destination = cut(item, catalog[item["token"]], xcassets)
        wanted.add(destination.name)
        print(f"{destination.name}  {destination.stat().st_size:>7,} bytes  {item['token']}: {item['text']}")
    for path in sorted(FONTS.iterdir()):
        if path.name not in wanted:
            path.unlink()
            print(f"removed {path.name}, which no line uses")


def check(articles, catalog):
    """Fails where a line's font is missing, stray, or lacks one of its characters; warns where the face it
    was cut from is older than the catalog's."""
    from fontTools.ttLib import TTFont

    problems = []
    wanted = set()
    for item in specimens(articles):
        path = FONTS / item["font"]
        wanted.add(path.name)
        with TTFont(path, lazy=True) as font:
            cmap = font.getBestCmap() or {}
            if absent := sorted({c for c in item["text"] if ord(c) not in cmap}):
                problems.append(f"{path.name} lacks {''.join(absent)!r} for {item['token']}: {item['text']!r}")
            version = font["name"].getDebugName(5)
        if not item.get("face") and version != catalog[item["token"]].get("fontVersion"):
            print(
                f"warning: {item['token']} was cut from {version!r}, and the catalog has a newer face", file=sys.stderr
            )
    problems += [f"{path.name} isn't any line's font" for path in sorted(FONTS.glob("*")) if path.name not in wanted]
    if problems:
        raise ArticleError("\n".join(problems))


def web_fonts(directory):
    """Rewrites each cut font in the directory, the site's copy of a release's, as WOFF2 and removes the
    original: site/static/a/, from scripts/site-catalog.sh. Brotli takes a third to a half off a TrueType
    cut; the app bundles the plain files, which Core Text reads directly."""
    from fontTools.ttLib import TTFont

    for path in sorted(p for p in directory.iterdir() if p.suffix in FONT_SUFFIXES):
        with TTFont(path, recalcTimestamp=False) as font:
            font.flavor = "woff2"
            font.save(path.with_suffix(".woff2"), reorderTables=False)
        path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    fonts = commands.add_parser("fonts", help="cut each specimen line's font, then write Articles.json")
    fonts.add_argument("--from", dest="xcassets", type=pathlib.Path, default=XCASSETS, help="a Fonts.xcassets")
    commands.add_parser("build", help="write Typecask/Articles.json")
    commands.add_parser("check", help="validate the articles, their fonts, and that Articles.json is current")
    web = commands.add_parser("web", help="rewrite the cut fonts in a directory as WOFF2, for the site")
    web.add_argument("directory", type=pathlib.Path)
    arguments = parser.parse_args()
    if arguments.command == "web":
        web_fonts(arguments.directory)
        return
    try:
        if arguments.command == "fonts":
            cut_fonts(arguments.xcassets)
        catalog = load_catalog()
        terms = read_glossary(catalog.keys())
        articles = read_articles(catalog, terms)
        text = render(articles, terms)
        if arguments.command == "check":
            check(articles, catalog)
    except ArticleError as error:
        sys.exit(str(error))
    if arguments.command == "check":
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != text:
            sys.exit(f"{OUTPUT.relative_to(ROOT)} doesn't match articles/: run scripts/articles.py build")
    else:
        OUTPUT.write_text(text, encoding="utf-8")
        print(f"wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
