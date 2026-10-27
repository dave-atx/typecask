#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["fonttools==4.67.0", "lxml==6.1.3"]  # lxml subsets OpenType-SVG color fonts
# ///
"""Builds Typecask's catalog and font assets from Homebrew's font casks and Google Fonts.

Two steps, so a build is repeatable, and a third that keeps it so when hosts change or go away:

  lock            resolves which casks to ship and pins each one's source in fonts.lock.json: a
                  google/fonts directory by its git tree, anything else by URL and SHA-256
  build           builds everything from fonts.lock.json, reusing whatever .cache/built/ already
                  holds for a cask whose locked source hasn't changed
  mirror          gathers the downloads from hosts other than GitHub that the font-sources release
                  lacks, for publish-fonts.sh upload to add

build writes into Typecask/:
  Catalog.json      gallery metadata, including each cask's design style, version and description
  Previews/         fonts subset to the sample text, for rendering the gallery before install
  Licenses.deflate  every license, from each cask's download, google/fonts, or its GitHub repository
  Fonts.xcassets/   fonts as data sets tagged for On-Demand Resources
and the same licenses as text into Licenses/, beside the app rather than in it, for review.

apple-previews subsets the previews of Apple's downloadable fonts; see docs/font-pipeline.md.
"""

import argparse
import base64
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date
from html.parser import HTMLParser
from pathlib import Path

from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib.instancer import instantiateVariableFont

# fontTools logs every table it drops while subsetting (FontForge's FFTM and PfEd, Graphite's Silt,
# ttfautohint's TTFA) and every quirk it reads past in a sloppy font: hundreds of lines a build, none
# of them about a preview. Only errors are worth seeing among the build's own warnings.
logging.getLogger("fontTools").setLevel(logging.ERROR)

ANALYTICS_URL = "https://formulae.brew.sh/api/analytics/cask-install/365d.json"
# The last month's installs, against the year's, for which casks are trending.
RECENT_ANALYTICS_URL = "https://formulae.brew.sh/api/analytics/cask-install/30d.json"
# Below this many installs in a month, a cask's trend is noise: two installs up from one isn't rising.
TRENDING_MIN_INSTALLS = 20
# Growth is noise for the long tail, where a small spike doubles a family's views, so a source's
# trend only counts for casks in this top share of it by yearly installs or views.
TRENDING_TOP_SHARE = 0.25
CASKS_URL = "https://formulae.brew.sh/api/cask.json"
DEFAULT_CATALOG_SIZE = 1000
EXCLUDED = {
    # Apple's license forbids redistribution.
    "font-sf-pro",
    "font-sf-mono",
    "font-sf-mono-nerd-font-ligaturized",
    # Draws every character as nothing, for testing font loading on the web: nothing to install.
    "font-adobe-blank",
    # Icons, symbols and emoji have nothing to preview.
    "font-symbols-only-nerd-font",
    "font-powerline-symbols",
    "font-fontawesome",
    "font-sketchybar-app-font",
    "font-noto-color-emoji",
    "font-noto-color-emoji-compat-test",
    # Bundles the faces of font-noto-sans-cjk-{sc,jp,kr}, which would collide.
    "font-noto-sans-cjk",
}
ALWAYS_INCLUDED = ["font-ioskeley-mono", "font-ioskeley-mono-term-nerd-font"]
# A file past this is a CJK collection or an Iosevka SuperTTC: hundreds of MB for one face, which
# dwarfs an asset pack and the CI download. Casks made only of these ship nothing and read as
# "not included in this build".
MAX_FILE_BYTES = 100 * 1024**2
# Below this a cask ships whatever its install count; it costs too little to be worth trimming.
NICHE_MIN_BYTES = 10_000_000
# Apple allows an app 1000 asset packs, and each On-Demand Resources tag is its own pack, so small casks
# share one. 900 leaves room for the count to grow between releases.
MAX_ASSET_PACKS = 900
# How many packs small casks share, by a hash of their token, so a cask keeps its pack as the line-up
# changes around it. Fixed so the hash doesn't reshuffle when the number of large casks changes.
SHARED_PACKS = 450
# Only casks under this are grouped, so installing a large font never drags others along with it.
SMALL_CASK_BYTES = 1_000_000
# A face's typographic subfamily, lowercased without spaces, mapped to the four core styles a cask
# ships. Old fonts call their upright Roman, Book, Normal or Plain.
CORE_STYLES = {
    "regular": "regular",
    "roman": "regular",
    "book": "regular",
    "normal": "regular",
    "plain": "regular",
    "italic": "italic",
    "oblique": "italic",
    "bold": "bold",
    "bolditalic": "bolditalic",
    "boldoblique": "bolditalic",
}
# Where a variable font's preview is instanced: its Regular, upright and at normal width, clamped to
# the font's range. Its default can be anything: Fira Code's is Light, Montserrat's Thin.
REGULAR_LOCATION = {"wght": 400, "wdth": 100, "ital": 0, "slnt": 0}
# Public, no API key. The leading characters before the first brace are XSSI padding.
GOOGLE_METADATA_URL = "https://fonts.google.com/metadata/fonts"
# Each family's views on Google Fonts, by year and by the last 30 days. The metadata's own
# `popularity` and `trending` are coarse buckets: Roboto, Open Sans and Lato all share popularity 2.
GOOGLE_STATS_URL = "https://fonts.google.com/metadata/stats"
GOOGLE_SPECIMEN = re.compile(r"fonts\.google\.com/specimen/([^/?#]+)")
# Casks that pull a single file out of google/fonts, rather than checking out the family directory.
GOOGLE_RAW_FILE = re.compile(r"github\.com/google/fonts/raw/[^/]+/(.+)/([^/]+)$")
GOOGLE_LICENSE_NAMES = ("OFL.txt", "LICENSE.txt", "UFL.txt", "LICENCE.txt")
GOOGLE_FONTS_URL = "https://github.com/google/fonts.git"
PANGRAM = "The quick brown fox jumps over the lazy dog"
SAMPLE_TEXT = PANGRAM + " 0123456789 {}[]()<>=!&|"
# A face that has fewer of PANGRAM's letters than this is previewed in its own script instead.
# Faces have all of them or none, bar a barcode font's 81%.
LATIN_COVERAGE = 0.8
# A line in each script, for a face with no Latin letters, tried in order: the same list as
# scriptSamples in TypecaskUITests/ApplePreviewRenderer.swift, which picks Apple's fonts' samples.
# Japanese comes before Chinese because Japanese fonts carry the kanji too.
SCRIPT_SAMPLES = [
    "いろはにほへと ちりぬるを",  # Japanese
    "天地玄黄 宇宙洪荒",  # Chinese
    "다람쥐 헌 쳇바퀴에 타고파",  # Korean
    "أبجد هوز حطي كلمن",  # Arabic
    "דג סקרן שט בים מאוכזב",  # Hebrew
    "नमस्ते दुनिया",  # Devanagari
    "বাংলা লিপি",  # Bengali
    "ਗੁਰਮੁਖੀ ਲਿਪੀ",  # Gurmukhi
    "ગુજરાતી લિપિ",  # Gujarati
    "ଓଡ଼ିଆ ଲିପି",  # Odia
    "தமிழ் எழுத்து",  # Tamil
    "తెలుగు లిపి",  # Telugu
    "ಕನ್ನಡ ಲಿಪಿ",  # Kannada
    "മലയാളം ലിപി",  # Malayalam
    "සිංහල අක්ෂර",  # Sinhala
    "สวัสดีชาวโลก",  # Thai
    "ສະບາຍດີ",  # Lao
    "សួស្តីពិភពលោក",  # Khmer
    "မင်္ဂလာပါ",  # Myanmar
    "བོད་ཡིག",  # Tibetan
    "ქართული დამწერლობა",  # Georgian
    "Հայերեն այբուբեն",  # Armenian
    "ግዕዝ ፊደል",  # Ethiopic
    "ᏣᎳᎩ ᎦᏬᏂᎯᏍᏗ",  # Cherokee
    "ᐃᓄᒃᑎᑐᑦ",  # Canadian syllabics
    "ᠮᠣᠩᠭᠣᠯ ᠪᠢᠴᠢᠭ",  # Mongolian
    "⠃⠗⠁⠊⠇⠇⠑",  # Braille
]
# Nerd Fonts icons the gallery shows under the sample: the Powerline branch, GitHub, git, Rust, Python,
# Node, a terminal, Apple, Linux, Arch, a folder, code, a bolt and a cog, which every Nerd Fonts v3
# cask in the catalog has. Powerline's rounded caps were dropped: on their own they're a black blob.
GLYPH_SAMPLE = "\ue0a0 \uf09b \ue702 \ue7a8 \ue73c \ue718 \ue795 \uf179 \uf17c \uf303 \uf07c \uf121 \uf0e7 \uf013"
# A face needs most of GLYPH_SAMPLE to count as patched. Fonts that happen to fill a few of the same
# private-use code points, like Material Icons or IBM Plex Sans TC, cover well under half.
GLYPH_COVERAGE = 0.8
# Google's own category for each family, which is far better than PANOSE at telling handwriting and
# display faces apart: most of them leave PANOSE empty and read as sans serif.
GOOGLE_CATEGORY_STYLES = {
    "Sans Serif": "sansSerif",
    "Serif": "serif",
    "Display": "display",
    "Handwriting": "handwriting",
    "Monospace": "monospaced",
}
GOOGLE_DESCRIPTIONS = ("DESCRIPTION.en_us.html", "article/ARTICLE.en_us.html")
# Apple's fonts, from AppleFonts.json, whose style the generator's PANOSE reading gets wrong: older
# script and decorative faces leave PANOSE empty, and CJK faces often claim fixed pitch. Families
# Google also publishes take Google's category instead, ahead of this.
APPLE_STYLES = {
    "handwriting": [
        "Bradley Hand",
        "Brush Script MT",
        "Corsiva Hebrew",
        "Dear Joe Four",
        "Hopper Script",
        "Kaiti SC",
        "Kaiti TC",
        "Klee",
        "Libian SC",
        "Libian TC",
        "Marker Felt",
        "Noteworthy",
        "PilGi",
        "BM Kirang Haerang",
        "Quotes Script",
        "Sauber Script",
        "Savoye LET",
        "SchoolHouse Cursive B",
        "SchoolHouse Printed A",
        "SignPainter",
        "Snell Roundhand",
        "STKaiti",
        "Xingkai SC",
        "Xingkai TC",
        "Wawati SC",
        "Wawati TC",
    ],
    "display": [
        "Apple Braille",
        "Apple Color Emoji",
        "Apple Symbols",
        "Bank Gothic",
        "Blackmoor LET",
        "Bodoni Ornaments",
        "Bodoni Ornaments ITC TT",
        "Bordeaux Roman Bold LET",
        "Braganza",
        "Capitals",
        "Forgotten Futurist",
        "Herculanum",
        "Jazz LET",
        "Luminari",
        "Mona Lisa Solid ITC TT",
        "Papyrus",
        "Party LET",
        "Phosphate",
        "PortagoITC TT",
        "Princetown LET",
        "Santa Fe LET",
        "Symbol",
        "Synchro LET",
        "Type Embellishments One LET",
        "Yuppy SC",
        "Yuppy TC",
    ],
    "serif": ["Brill", "Hoefler Text", "PCMyungjo"],
    "sansSerif": [
        "Lantinghei SC",
        "Lantinghei TC",
        "Tsukushi A Round Gothic",
        "Tsukushi B Round Gothic",
        "Yuanti SC",
        "Yuanti TC",
    ],
}
# Fonts Core Text needs for laying out math, which no one would pick from a gallery.
APPLE_HIDDEN = re.compile(r"^STIX(Integrals|Size|NonUnicode|Variants)")
COLLECTION_SUFFIXES = (".ttc", ".otc")
# What fontTools reads and Core Text registers from an asset catalog. A classic Mac .dfont is neither:
# Cozette's was being picked as its shortest-named file.
FONT_SUFFIXES = (".ttf", ".otf", *COLLECTION_SUFFIXES)
LICENSE_NAME = re.compile(r"licen[cs]e|\bofl\b|copying|copyright", re.IGNORECASE)
# OFL-FAQ.txt matches \bofl\b, and is 40 KB of questions rather than a license.
NOT_LICENSE_NAME = re.compile(r"faq", re.IGNORECASE)
LICENSE_SUFFIXES = ("", ".txt", ".md")
GITHUB_REPO = re.compile(r"github\.com/([^/]+)/([^/]+?)(?:\.git)?/")
CATALOG_INFO = {"info": {"author": "xcode", "version": 1}}
# Some hosts turn away clients that don't look like a browser or Homebrew.
USER_AGENT = "Homebrew/4.6 (Macintosh; arm64 Mac OS X 26.0) curl/8.7.1"
# Part of every built cask's cache key. Bump it when a change here alters what a cask builds into,
# such as the preview's text or which files are selected, so cached casks are rebuilt.
PIPELINE_VERSION = 7
# A cask skipped for want of a license or usable fonts is remembered rather than rebuilt every run.
# Bump this when a change might rescue some of them, such as a new place to find licenses: only the
# skipped casks are retried, not the whole line-up.
SKIP_VERSION = 2

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Typecask"
FONTS = APP / "Fonts.xcassets"
PREVIEWS = APP / "Previews"
# Each cask's license as text, for review: outside the app, which ships them all in LICENSE_BUNDLE.
LICENSES = ROOT / "Licenses"
# Every license in one JSON object by token, raw-deflated, which NSData decompresses as .zlib: 0.8 MB
# against 12.5 MB of text in 2,000-odd files, most of them the same OFL.
LICENSE_BUNDLE = APP / "Licenses.deflate"
APPLE_PREVIEWS = APP / "ApplePreviews"
LOCK = ROOT / "fonts.lock.json"
# Standard license texts, for google/fonts families that record theirs only in METADATA.pb.
LICENSE_TEXTS = ROOT / "scripts" / "licenses"
CACHE = ROOT / ".cache"
CLONE = CACHE / "google-fonts"
# One directory per cask and cache key: the GitHub Actions cache keeps it between runs.
BUILT = CACHE / "built"
# Downloads the lock hashed itself, kept by hash for the build to use: some hosts, like djr.com for
# Input, assemble a new zip for every request, so a second download would never match the lock.
DOWNLOADS = CACHE / "downloads"
WORK = CACHE / "work"
# Downloads from hosts less durable than GitHub are kept in this release, named by SHA-256, so a build
# from any lock still has them once the host is down or serves something else: gust.org.pl was down
# for all of one build, and int10h.org once served Ac437 with a different hash. Only casks in the
# catalog are mirrored, since those are the ones with a license to redistribute. Never delete its
# assets; old locks build from them.
MIRROR_REPO = "dave-atx/typecask"
MIRROR_TAG = "font-sources"
MIRROR_URL = f"https://github.com/{MIRROR_REPO}/releases/download/{MIRROR_TAG}/"
# Hosts as durable as the mirror, which is on GitHub too, so their downloads aren't copied into it.
# GitHub Pages sites aren't among them: a site's files change as freely as any other host's.
DURABLE_HOSTS = {"github.com", "raw.github.com"}
# What `mirror` gathers for publish-fonts.sh upload to add to the mirror.
MIRROR = CACHE / "mirror"


def fetch_json(url, headers=None):
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def github_headers():
    """Authenticates the GitHub API when a token is around: unauthenticated it allows 60 requests an
    hour, and a catalog of any size needs hundreds of license lookups."""
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    return {"Authorization": f"Bearer {token}"} if token else {}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def git(*arguments, **options):
    return subprocess.run(
        ["git", "-C", CLONE, *arguments], check=True, capture_output=True, text=True, **options
    ).stdout


# MARK: - Locking


def rank_casks(analytics, casks_by_token):
    """Returns every eligible font cask with its install count, most-installed first."""
    installs = {}
    for item in analytics["items"]:
        token = item["cask"]
        if token.startswith("font-") and token in casks_by_token and token not in EXCLUDED:
            installs.setdefault(token, int(item["count"].replace(",", "")))
    return [(casks_by_token[token], installs[token]) for token in sorted(installs, key=installs.get, reverse=True)]


def google_families(casks_by_token):
    """Every Google Fonts family, most popular first, each with the cask that installs it or None.

    Homebrew's ranking is a different axis: it is dominated by Nerd Fonts and coding faces, and only
    nine of its top hundred are Google Fonts, so the families most people have actually heard of have
    to be asked for by name. Google's own metadata endpoint carries a popularity rank and a category
    and needs no API key. (fontsource repackages the same fonts with useful metadata, but publishes
    no popularity, so it cannot order them.)

    A family is matched to a cask by its specimen homepage, then by the google/fonts directory the
    cask checks out, then by the name itself: fonts that originated elsewhere, like Inter and JetBrains
    Mono, keep their upstream homepage and are only found by the later two.
    """
    with urllib.request.urlopen(GOOGLE_METADATA_URL) as response:
        raw = response.read().decode()
    families = json.loads(raw[raw.index("{") :])["familyMetadataList"]
    families.sort(key=lambda family: (family["popularity"], family["family"]))

    by_specimen, by_directory = {}, {}
    for token, cask in casks_by_token.items():
        if specimen := GOOGLE_SPECIMEN.search(cask.get("homepage") or ""):
            name = urllib.parse.unquote(specimen.group(1)).replace("+", " ").lower()
            by_specimen.setdefault(name, token)
        if only_path := (cask.get("url_specs") or {}).get("only_path", ""):
            by_directory.setdefault(only_path.rsplit("/", 1)[-1].lower(), token)

    matched = []
    for family in families:
        name = family["family"]
        by_name = "font-" + re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        token = (
            by_specimen.get(name.lower())
            or by_directory.get(re.sub(r"[^a-z0-9]", "", name.lower()))
            or (by_name if by_name in casks_by_token else None)
        )
        matched.append((family, token))
    return matched


def update_clone(commit=None):
    """Brings the google/fonts clone to `commit`, or to the tip of main, and returns the commit.

    Blobs are fetched only for the paths checked out: the whole repository is tens of thousands of
    files, and a build needs a handful of families at a time. It replaces hundreds of separate clones,
    one per cask, with one, and each family's licence and description sit beside its fonts.
    """
    if not (CLONE / ".git").is_dir():
        shutil.rmtree(CLONE, ignore_errors=True)
        CLONE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "--filter=blob:none",
                "--sparse",
                "--no-checkout",
                "--quiet",
                GOOGLE_FONTS_URL,
                CLONE,
            ],
            check=True,
        )
    # GitHub serves any commit by hash, so a locked one can be fetched on its own.
    git("fetch", "--depth", "1", "--filter=blob:none", "--quiet", "origin", commit or "main")
    return git("rev-parse", "FETCH_HEAD").strip()


def checkout(commit, directories):
    """Checks out just `directories` of google/fonts at `commit`."""
    git("sparse-checkout", "set", "--no-cone", "--stdin", input="\n".join(f"/{d}/" for d in sorted(directories)))
    git("checkout", "--quiet", "--force", commit)


def google_trees(commit):
    """The git tree of every directory in google/fonts, which changes only when its family does."""
    trees = {}
    for line in git("ls-tree", "-r", "-d", commit).splitlines():
        meta, path = line.split("\t", 1)
        trees[path] = meta.split()[2]
    return trees


def google_directory_of(family, cask, family_directories):
    only_path = (cask.get("url_specs") or {}).get("only_path", "") if cask else ""
    return only_path or family_directories.get(re.sub(r"[^a-z0-9]", "", family["family"].lower()))


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def homebrew_download(url):
    """A copy Homebrew has already downloaded, which a local run can use instead of fetching again.
    Homebrew names a download by the SHA-256 of its URL; the content is checked against the lock."""
    cache = Path(os.environ.get("HOMEBREW_CACHE") or (Path.home() / "Library/Caches/Homebrew"))
    prefix = hashlib.sha256(url.encode()).hexdigest() + "--"
    return next((path for path in (cache / "downloads").glob(prefix + "*") if path.is_file()), None)


def download(url, destination, referer=None, fresh=False):
    """Downloads `url` to `destination` with curl, or reuses Homebrew's copy unless `fresh`."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not fresh and (cached := homebrew_download(url)) is not None:
        shutil.copy(cached, destination)
        return destination
    # Retries every error, not just the ones curl deems transient, and gives up on a stalled transfer
    # rather than waiting it out: a host timing out or answering 503 for a minute shouldn't cost a cask.
    command = [
        "curl", "-fsSL", "--retry", "5", "--retry-all-errors", "--retry-delay", "5", "--connect-timeout", "30",
        "--speed-limit", "1000", "--speed-time", "60", "-A", USER_AGENT, "-o", destination, url,
    ]  # fmt: skip
    if referer:
        command[1:1] = ["-e", referer]
    subprocess.run(command, check=True)
    return destination


def mirrorable(source):
    return "url" in source and urllib.parse.urlparse(source["url"]).hostname not in DURABLE_HOSTS


def mirrored_hashes():
    """The SHA-256 of every download in the mirror. Empty when GitHub can't say, so the build falls back
    on the upstream hosts rather than failing."""
    api = f"https://api.github.com/repos/{MIRROR_REPO}/releases"
    try:
        release = fetch_json(f"{api}/tags/{MIRROR_TAG}", github_headers())
        names, page = set(), 1
        while batch := fetch_json(f"{api}/{release['id']}/assets?per_page=100&page={page}", github_headers()):
            names |= {asset["name"] for asset in batch}
            page += 1
    except urllib.error.URLError as error:
        print(f"can't list the {MIRROR_TAG} mirror ({error}); downloading from upstream hosts")
        return set()
    return names


def upstream_matches(source):
    """Whether `source`'s URL serves the file its hash pins, downloaded fresh, as CI would: Homebrew's
    cache can hold a copy from before the host changed it. A match is kept for the build to use."""
    if (DOWNLOADS / source["sha256"]).is_file():
        return True
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=DOWNLOADS) as scratch:
        try:
            fetched = download(source["url"], Path(scratch) / "download", source.get("referer"), fresh=True)
        except subprocess.CalledProcessError:
            return False
        if sha256_of(fetched) != source["sha256"]:
            return False
        fetched.replace(DOWNLOADS / source["sha256"])
    return True


def lock_source(cask, trees, commit):
    """Where a cask's files come from, pinned. None for a source this pipeline can't pin."""
    url = cask["url"]
    specs = cask.get("url_specs") or {}
    if url == GOOGLE_FONTS_URL:
        directory = specs.get("only_path", "")
        return {"google": directory, "tree": trees[directory]} if directory in trees else None
    if match := GOOGLE_RAW_FILE.search(url):
        directory = urllib.parse.unquote(match.group(1))
        return {"google": directory, "tree": trees[directory]} if directory in trees else None
    if url.endswith(".git"):
        branch = specs.get("branch") or "HEAD"
        output = subprocess.run(["git", "ls-remote", url, branch], check=False, capture_output=True, text=True).stdout
        if not output:
            return None
        return {"git": url, "commit": output.split()[0], "path": specs.get("only_path", "")}
    sha256 = cask.get("sha256")
    if not sha256 or sha256 == "no_check":
        # Homebrew doesn't pin these, so the lock does: what was there when it was written is what a
        # build will accept, and the build uses this very file.
        DOWNLOADS.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=DOWNLOADS) as scratch:
            try:
                fetched = download(url, Path(scratch) / "download", specs.get("referer"))
            except subprocess.CalledProcessError:
                return None
            sha256 = sha256_of(fetched)
            fetched.replace(DOWNLOADS / sha256)
    source = {"url": url, "sha256": sha256}
    if specs.get("referer"):
        source["referer"] = specs["referer"]
    return source


def lock(count, google_top):
    """`lock`: resolves the line-up and pins each cask's source in fonts.lock.json."""
    previous = {entry["token"]: entry for entry in json.loads(LOCK.read_text())["casks"]} if LOCK.is_file() else {}
    casks_by_token = {cask["token"]: cask for cask in fetch_json(CASKS_URL)}
    ranked = rank_casks(fetch_json(ANALYTICS_URL), casks_by_token)
    families = google_families(casks_by_token)
    commit = update_clone()
    trees = google_trees(commit)
    family_directories = {}
    for path in trees:
        parts = path.split("/")
        if len(parts) == 2 and parts[0] in ("ofl", "apache", "ufl"):
            family_directories.setdefault(parts[1], path)

    with urllib.request.urlopen(GOOGLE_STATS_URL) as response:
        raw = response.read().decode()
    views = {stats["family"]: stats["viewsByDateRange"] for stats in json.loads(raw[raw.index("[") :])}
    google_by_token = {token: family for family, token in families if token}
    # A family matches one cask, but several can install it: Hind's specimen page belongs to another
    # cask, and font-hind downloads from upstream with no license, which google/fonts then supplies.
    for family, _ in families:
        by_name = "font-" + re.sub(r"[^a-z0-9]+", "-", family["family"].lower()).strip("-")
        if by_name in casks_by_token:
            google_by_token.setdefault(by_name, family)
    if google_top != 0:
        top = families[:google_top]
        if missing := [family["family"] for family, token in top if not token]:
            print(
                f"no cask for {len(missing)} Google Fonts families, which have no files in google/fonts "
                f"under those names either: {', '.join(missing)}"
            )
        required = [token for _, token in top if token and token not in EXCLUDED]
    else:
        required = []
    required += ALWAYS_INCLUDED
    # Homebrew's analytics leave out casks nobody installed in a year; required ones go on the end.
    installs = {cask["token"]: count for cask, count in ranked}
    recent = {item["cask"]: int(item["count"].replace(",", "")) for item in fetch_json(RECENT_ANALYTICS_URL)["items"]}
    tokens = list(dict.fromkeys([cask["token"] for cask, _ in ranked[:count]] + required))
    exempt = set(required)

    planned = []
    for token in tokens:
        cask = casks_by_token[token]
        family = google_by_token.get(token)
        directory = family and google_directory_of(family, cask, family_directories)
        planned.append((token, cask, family, directory, lock_source(cask, trees, commit)))
    # A Google family is the same family in google/fonts, which serves when its upstream download can't
    # be had (paratype.com refuses PT Sans and PT Serif to anything but a browser) or no longer matches
    # Homebrew's hash (Atkinson Hyperlegible). The check downloads each of these 70-odd casks, eight at
    # a time: GitHub serves archives at about 1 MB/s each, and Chiron Sung HK's is over a gigabyte.
    checked = [source for *_, directory, source in planned if directory in trees and source and "url" in source]
    # A cask only moves to a new download once it has been had and matches its hash, so a host that's
    # down or serving something else holds back an update instead of dropping the cask from the build.
    # What's fetched is kept for the build, which then needn't download it again.
    changed = [
        source
        for token, *_, source in planned
        if source and "url" in source and source != (previous.get(token) or {}).get("source")
    ]
    checked = list({source["sha256"]: source for source in checked + changed}.values())
    with ThreadPoolExecutor(8) as pool:
        matches = dict(zip((source["sha256"] for source in checked), pool.map(upstream_matches, checked)))

    entries, unpinned, held = [], [], []
    for token, cask, family, directory, source in planned:
        artifacts = [artifact["font"][0] for artifact in cask["artifacts"] if "font" in artifact]
        if directory in trees and (source is None or ("url" in source and not matches[source["sha256"]])):
            source = {"google": directory, "tree": trees[directory]}
            artifacts = [
                name.rsplit("/", 1)[-1]
                for name in git("ls-tree", "--name-only", commit, f"{directory}/").splitlines()
                if name.lower().endswith((".ttf", ".otf"))
            ]
            print(f"{token}: upstream download unavailable or changed; using google/fonts {directory}")
        version = str(cask.get("version") or "")
        if source is None or ("url" in source and not matches.get(source["sha256"], True)):
            if not (kept := previous.get(token)):
                unpinned.append(token)
                continue
            source, artifacts, version = kept["source"], kept["artifacts"], kept["version"]
            held.append(f"{token} ({version or 'unversioned'})")
        entry = {
            "token": token,
            "name": cask["name"][0],
            "homepage": cask["homepage"],
            "version": version,
            "installs": installs.get(token, 0),
            "recentInstalls": recent.get(token, 0),
            "exempt": token in exempt,
            "artifacts": artifacts,
            "source": source,
        }
        if family:
            google = {
                "family": family["family"],
                "category": family["category"],
                "designers": family.get("designers") or [],
                "views": views.get(family["family"], {}).get("year", {}).get("views", 0),
                "recentViews": views.get(family["family"], {}).get("30day", {}).get("views", 0),
            }
            if directory in trees:
                google |= {"directory": directory, "tree": trees[directory]}
            entry["google"] = google
        entries.append(entry)
    if unpinned:
        print(f"warning: {len(unpinned)} casks have a source that can't be pinned: {', '.join(unpinned)}")
    report("kept at their locked version: the new download can't be had or doesn't match its hash", held)

    write_json(
        LOCK,
        {
            "generated": date.today().isoformat(),
            "googleFonts": commit,
            # Every family's category, for Apple's fonts that Google also publishes.
            "googleCategories": {family["family"]: family["category"] for family, _ in families},
            "casks": entries,
        },
    )
    print(f"locked {len(entries)} casks at google/fonts {commit[:12]}")


# MARK: - Fonts


@dataclass(frozen=True)
class Face:
    path: Path
    number: int  # index within a collection
    postscript_name: str
    # Typographic family and subfamily (name IDs 16 and 17), or the legacy ones (1 and 2) where only
    # those name a core style, the subfamily as one of CORE_STYLES or None for any other style.
    family: str
    style: str | None
    weight: int
    width: int  # OS/2 width class, 5 for normal
    italic: bool
    variable: bool
    # Families named for it, which their names say more reliably than their tables: DejaVu Sans
    # carries a MATH table, and Libertinus Mono doesn't set isFixedPitch.
    mono: bool  # Liberation Mono, Red Hat Mono
    math: bool  # STIX Two Math, Libertinus Math

    @property
    def regular(self):
        return self.style == "regular"


def read_faces(path):
    """Reads only the tables that name and describe each face. Collections share glyph tables between
    faces, so loading faces eagerly reads the shared data once per face: tens of GB for Iosevka's
    324-face SuperTTC."""

    def core_style(subfamily):
        return CORE_STYLES.get(re.sub(r"[\s_-]+", "", subfamily.lower()))

    def face(number, font):
        names = font["name"]
        family = names.getDebugName(16) or names.getDebugName(1) or ""
        subfamily = names.getDebugName(17) or names.getDebugName(2) or ""
        # EB Garamond's typographic subfamilies carry the optical size, "08 Regular" and "12 Italic",
        # which left no face Regular and made the capitals-only Initials its primary face. Its legacy
        # names are plain Regular and Italic, of the families EB Garamond 08 and 12.
        if not core_style(subfamily) and core_style(legacy := names.getDebugName(2) or ""):
            family, subfamily = names.getDebugName(1) or "", legacy
        subfamily = subfamily.lower()
        os2 = font.get("OS/2")
        italic = bool(
            (os2 is not None and os2.fsSelection & 1)
            or ("head" in font and font["head"].macStyle & 2)
            or "italic" in subfamily
            or "oblique" in subfamily
        )
        weight = os2.usWeightClass if os2 is not None else 400
        width = os2.usWidthClass if os2 is not None else 5
        style = core_style(subfamily)
        variable = "fvar" in font
        if variable:
            # A variable font is its whole weight and width range, whatever its default instance is called.
            axes = {axis.axisTag: axis for axis in font["fvar"].axes}
            if "wght" not in axes or axes["wght"].minValue <= 400 <= axes["wght"].maxValue:
                weight = 400
            if "wdth" not in axes or axes["wdth"].minValue <= 100 <= axes["wdth"].maxValue:
                width = 5
            style = "italic" if italic else "regular"
        postscript_name = names.getDebugName(6) or ""
        mono = bool(re.search(r"mono(?![a-z])", family, re.IGNORECASE))  # FreeMono too
        math = bool(re.search(r"\bmath\b", family, re.IGNORECASE))
        return Face(path, number, postscript_name, family, style, weight, width, italic, variable, mono, math)

    if path.suffix.lower() in COLLECTION_SUFFIXES:
        with TTCollection(path, lazy=True) as collection:
            return [face(number, font) for number, font in enumerate(collection.fonts)]
    with TTFont(path, lazy=True) as font:
        return [face(0, font)]


def select_files(faces):
    """The files worth shipping out of a cask, which often carries far more than anyone installs.

    Chosen by what each face says about itself, not by its filename: Cascadia Code, Charter and
    Linux Libertine name their files in ways no filename rule reads, and shipped only Regular, only
    Bold and only the capitals-only Initials.

    A variable font covers the whole weight axis in one file, so where a cask has one it is the whole
    answer rather than a reduced set. Failing that, the four core styles of a single family are kept:
    Nerd Fonts ship Mono and Propo spacing variants of every weight, so Noto alone is 399 files, and
    the family is the primary face's.

    Where none of that matches, the primary face's file is kept rather than all of them. Shipping
    everything on an unrecognised naming scheme is how Iosevka Comfy's 126 files, a gigabyte,
    slipped through. Files come back in the order given, so a face shipped as both TTF and OTF keeps
    whichever the cask lists first.
    """
    paths = list(dict.fromkeys(face.path for face in faces))
    if variable := {face.path for face in faces if face.variable}:
        return [path for path in paths if path in variable]
    primary = primary_face(faces)
    # The primary face's own file too, whatever it's called: Terminus and Scientifica name their
    # Regular "Medium", and shipped only Bold and the italics.
    core = {face.path for face in faces if face.style and face.family == primary.family} | {primary.path}
    return [path for path in paths if path in core]


def primary_face(faces):
    """The face a cask is previewed in and recognised as installed by: a text face, not math, upright
    and Regular, nearest 400 in weight and normal in width, not a family named Mono beside the cask's
    others, then the shortest family and name, which skips Nerd Fonts' Mono and Propo variants.

    Without the width, Noto's Nerd Font previewed its condensed face, whose legacy family name is the
    shorter; without the Mono rule, Liberation and Red Hat their Mono families, which sort first. It
    goes by the name rather than the spacing, so Input, Myrica and Sudo keep their monospaced faces
    over their proportional ones.
    """
    return min(
        faces,
        key=lambda face: (
            face.math,
            face.italic,
            not face.regular,
            abs(face.weight - 400),
            abs(face.width - 5),
            face.mono,
            len(face.family),
            len(face.postscript_name),
            face.postscript_name,
            str(face.path),
            face.number,
        ),
    )


# PANOSE serif styles 11-15 are the sans-serif ones: normal, obtuse and perpendicular sans, plus flared
# and rounded, which are sans designs too (Lato and Carlito both declare 15). 2-10 are the true serif brackets.
PANOSE_SANS_SERIF = range(11, 16)
PANOSE_MONOSPACED = 9


def classify(font):
    """The font's design style, from PANOSE and the OS/2 family class.

    Read before subsetting, from the cask's own primary face. Falls back through PANOSE to sFamilyClass
    because plenty of fonts fill in only one of them.
    """
    os2 = font.get("OS/2")
    panose = getattr(os2, "panose", None)
    family_class = (os2.sFamilyClass >> 8) if os2 is not None else 0
    family_type = getattr(panose, "bFamilyType", 0)
    serif_style = getattr(panose, "bSerifStyle", 0)

    post = font.get("post")
    if (post is not None and post.isFixedPitch) or getattr(panose, "bProportion", 0) == PANOSE_MONOSPACED:
        return "monospaced"
    if family_type == 3 or family_class == 10:
        return "handwriting"
    if family_type in (4, 5) or family_class in (9, 12):
        return "display"
    if family_type == 2 and serif_style:
        return "sansSerif" if serif_style in PANOSE_SANS_SERIF else "serif"
    if 1 <= family_class <= 7:
        return "serif"
    return "sansSerif"


@dataclass(frozen=True)
class Preview:
    file: str
    style: str
    glyphs: bool
    # The face's own version string (name ID 5), which the app compares with an installed copy's to
    # offer an update.
    font_version: str


# Tables a preview can do without, dropped on a second attempt when a font's copy of one is too
# malformed for fontTools to read: Dream Han Sans's variation store, for one.
OPTIONAL_TABLES = ["BASE", "GDEF", "GPOS", "GSUB", "JSTF", "MATH", "HVAR", "VVAR", "MVAR"]


def write_preview(face, token, directory, text=SAMPLE_TEXT):
    """Subsets the face to `text`, renamed so it can't clash with an installed font."""
    try:
        return subset_preview(face, token, directory, text, drop=["BASE"])
    except Exception as error:  # noqa: BLE001 - any table fontTools chokes on
        print(f"{token}: subsetting failed ({type(error).__name__}: {error}); trying without layout tables")
        return subset_preview(face, token, directory, text, drop=OPTIONAL_TABLES)


def subset_preview(face, token, directory, text, drop):
    postscript_name = "TypecaskPreview-" + re.sub(r"[^A-Za-z0-9-]", "_", token)
    # recalcTimestamp=False keeps the source's modified date. Otherwise every save stamps the time of the
    # build into the head table, and every preview changes on every rebuild of the same font.
    with TTFont(face.path, fontNumber=face.number, lazy=True, recalcTimestamp=False) as font:
        style = classify(font)
        glyphs = has_glyph_sample(font)
        font_version = font_version_of(font)
        # Subsetting first leaves the instancer a few dozen glyphs instead of the whole font.
        options = Options()
        # fontTools' default features, which are the ones Core Text applies unasked, shaping included.
        # Every feature ("*") kept every alternate the sample's letters reach through aalt, salt and
        # the stylistic sets, which no preview draws: Iosevka's came to 1,900 glyphs and 318 KB.
        # Hinting goes too, since Core Text doesn't run it; together they halve the previews. Except
        # in a CFF2 variable font, whose stripped hints fontTools' instancer then fails on, and which
        # carries little hinting anyway: Source Han Sans VF, Cantarell.
        options.hinting = "CFF2" in font and "fvar" in font
        options.name_IDs = ["*"]
        # BASE, baseline offsets for mixing scripts on a line, which a one-line sample doesn't need,
        # is always dropped: fontTools can't parse Google Sans Code Nerd Font's.
        options.drop_tables += drop
        subsetter = Subsetter(options)
        subsetter.populate(text=text + (GLYPH_SAMPLE if glyphs else ""))
        subsetter.subset(font)
        if "fvar" in font:
            instantiateVariableFont(font, regular_location(font["fvar"].axes), inplace=True)
        if "STAT" in font:
            del font["STAT"]
        font["name"].names = []
        for name_id, value in ((1, postscript_name), (2, "Regular"), (4, postscript_name), (6, postscript_name)):
            font["name"].setName(value, name_id, 3, 1, 0x409)
        if "CFF " in font:
            font["CFF "].cff.fontNames = [postscript_name]
        file_name = f"{postscript_name}.{'otf' if 'CFF ' in font or 'CFF2' in font else 'ttf'}"
        font.save(directory / file_name)
    return Preview(file_name, style, glyphs, font_version)


def regular_location(axes):
    """Each axis pinned at REGULAR_LOCATION within its range, and any other axis at its default."""
    return {
        axis.axisTag: (
            min(max(REGULAR_LOCATION[axis.axisTag], axis.minValue), axis.maxValue)
            if axis.axisTag in REGULAR_LOCATION
            else None
        )
        for axis in axes
    }


def sample_for(face):
    """What the face is previewed with: SAMPLE_TEXT where it has the Latin letters, else the first of
    SCRIPT_SAMPLES it covers, else None."""
    with TTFont(face.path, fontNumber=face.number, lazy=True) as font:
        cmap = font.getBestCmap() or {}
    letters = {ord(character) for character in PANGRAM if not character.isspace()}
    if len(letters & cmap.keys()) >= LATIN_COVERAGE * len(letters):
        return SAMPLE_TEXT
    return next(
        (sample for sample in SCRIPT_SAMPLES if all(ord(char) in cmap for char in sample if not char.isspace())),
        None,
    )


def font_version_of(font):
    return (font["name"].getDebugName(5) or "").strip()


def cask_version(version, font_version):
    """The version shown for a cask: Homebrew's, or for a cask that always takes the latest — every
    google/fonts one — the version its font declares."""
    if version and version != "latest":
        return version.split(",")[0]
    match = re.search(r"\d+(?:\.\d+)+", font_version)
    return match.group(0) if match else font_version or None


def has_glyph_sample(font):
    """Whether the face carries Nerd Fonts' icons, which the gallery then previews too."""
    cmap = font.getBestCmap() or {}
    wanted = {ord(character) for character in GLYPH_SAMPLE if not character.isspace()}
    return len(wanted & cmap.keys()) >= GLYPH_COVERAGE * len(wanted)


# MARK: - Licenses and descriptions


class RateLimited(Exception):
    """The GitHub API refused a license lookup for quota, not because the repository has no license."""


def github_license(owner, repo):
    try:
        response = fetch_json(f"https://api.github.com/repos/{owner}/{repo}/license", github_headers())
    except urllib.error.HTTPError as error:
        # 404 means the repository really has no license. Quota refusals look nothing like that, and
        # swallowing them drops casks that do have one: a run without a token lost 218 that way.
        if error.code in (403, 429):
            raise RateLimited(
                f"GitHub API rate limit reached looking up {owner}/{repo}; "
                "set GITHUB_TOKEN to raise the limit from 60 an hour to 5000"
            ) from error
        return None
    return f"License of github.com/{owner}/{repo}:\n\n" + base64.b64decode(response["content"]).decode()


def google_fonts_license(directory):
    """The licence sitting next to a family in google/fonts, from the clone.

    A cask that downloads one .ttf straight out of the repository brings no licence with it, and a
    Google family whose cask downloads from its upstream project often has none there either: PT Sans
    and PT Serif, from paratype.com, and Rajdhani, Tinos and Kalam were all dropped for want of one.
    """
    for name in GOOGLE_LICENSE_NAMES:
        if (path := CLONE / directory / name).is_file():
            return f"License of github.com/google/fonts/{directory}:\n\n{path.read_text(errors='replace')}"
    # Ten families, Tinos and M PLUS Rounded 1c among them, have no license file and record it in
    # METADATA.pb instead: the license's name, and the copyright of each font.
    metadata = CLONE / directory / "METADATA.pb"
    if not metadata.is_file():
        return None
    text = metadata.read_text(errors="replace")
    license = re.search(r'^license: "(\w+)"', text, re.MULTILINE)
    standard = license and LICENSE_TEXTS / f"{license.group(1)}.txt"
    if not standard or not standard.is_file():
        return None
    copyrights = "\n".join(dict.fromkeys(re.findall(r'copyright: "(.*)"', text)))
    return (
        f"License of github.com/google/fonts/{directory}, from its METADATA.pb:\n\n"
        f"{copyrights}\n\n{standard.read_text()}"
    )


def find_license(root, url, google_directory=None):
    paths = sorted(
        path
        for path in root.rglob("*")
        if path.suffix.lower() in LICENSE_SUFFIXES
        and LICENSE_NAME.search(path.stem)
        and not NOT_LICENSE_NAME.search(path.stem)
        and path.is_file()
    )
    if paths:
        return "\n\n".join(path.read_text(errors="replace") for path in paths)
    if google_directory and (license := google_fonts_license(google_directory)):
        return license
    repo = GITHUB_REPO.search((url or "") + "/")
    return repo and github_license(*repo.groups())


class DescriptionParser(HTMLParser):
    """Turns a google/fonts description into the Markdown subset SwiftUI's Text renders: paragraphs,
    links, emphasis and list items. Images, rules and anything else are dropped."""

    def __init__(self):
        super().__init__()
        self.paragraphs, self.current, self.links = [], [], []

    def flush(self):
        if text := re.sub(r"\s+", " ", "".join(self.current)).strip():
            self.paragraphs.append(text)
        self.current = []

    def handle_starttag(self, tag, attrs):
        if tag in ("p", "div", "h1", "h2", "h3", "h4", "ul", "ol", "blockquote"):
            self.flush()
        elif tag == "li":
            self.flush()
            self.current.append("- ")
        elif tag == "br":
            self.flush()
        elif tag in ("em", "i"):
            self.current.append("*")
        elif tag in ("strong", "b"):
            self.current.append("**")
        elif tag == "a":
            self.links.append(dict(attrs).get("href"))
            self.current.append("[" if self.links[-1] else "")

    def handle_endtag(self, tag):
        if tag in ("p", "div", "h1", "h2", "h3", "h4", "li", "blockquote"):
            self.flush()
        elif tag in ("em", "i"):
            self.current.append("*")
        elif tag in ("strong", "b"):
            self.current.append("**")
        elif tag == "a" and self.links:
            href = self.links.pop()
            self.current.append(f"]({href})" if href else "")

    def handle_data(self, data):
        self.current.append(data.replace("[", "\\[").replace("]", "\\]"))


def describe(html):
    parser = DescriptionParser()
    parser.feed(html)
    parser.close()
    parser.flush()
    # Emphasis markers left dangling by tags wrapped around whitespace would show up as literal asterisks.
    paragraphs = [re.sub(r"\*\*\s*\*\*|(?<!\*)\*\s*\*(?!\*)", " ", text).strip() for text in parser.paragraphs]
    return "\n\n".join(text for text in paragraphs if text) or None


def google_description(directory):
    for name in GOOGLE_DESCRIPTIONS:
        if (path := CLONE / directory / name).is_file():
            return describe(path.read_text(errors="replace"))
    return None


# MARK: - Building one cask


def cache_key(entry):
    """What a cask builds from: its pinned source, its files, its google/fonts directory (licence and
    description) and this pipeline's version. Install counts and the like aren't in it, so they change
    without a rebuild."""
    material = {key: entry.get(key) for key in ("source", "artifacts", "google")}
    if material["google"]:
        material["google"] = {k: v for k, v in material["google"].items() if k in ("directory", "tree")}
    material["pipeline"] = PIPELINE_VERSION
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()[:20]


def extract(archive, destination):
    """Unpacks by content rather than name: a few casks download from URLs with no extension."""
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as file:
            file.extractall(destination)
    elif tarfile.is_tarfile(archive):
        with tarfile.open(archive) as file:
            file.extractall(destination, filter="data")
    elif archive.read_bytes()[:6] == b"7z\xbc\xaf\x27\x1c":
        # bsdtar reads 7z on macOS; Linux runners have 7z instead.
        if seven := shutil.which("7z") or shutil.which("7zz"):
            subprocess.run([seven, "x", "-y", f"-o{destination}", archive], check=True, capture_output=True)
        else:
            subprocess.run(["tar", "-xf", archive, "-C", destination], check=True)
    else:
        return False
    return True


def stage(entry, work, mirrored=frozenset()):
    """Returns the directory that the cask's artifact paths are relative to. A download comes from what
    the lock kept, then the mirror, then its host; `mirrored` is what the mirror holds."""
    source = entry["source"]
    if "google" in source:
        return CLONE / source["google"]
    if "git" in source:
        repository = work / "repository"
        subprocess.run(["git", "init", "--quiet", repository], check=True)
        subprocess.run(
            ["git", "-C", repository, "fetch", "--depth", "1", "--quiet", source["git"], source["commit"]], check=True
        )
        subprocess.run(["git", "-C", repository, "checkout", "--quiet", "FETCH_HEAD"], check=True)
        return repository / source["path"]
    name = urllib.parse.unquote(urllib.parse.urlparse(source["url"]).path.rsplit("/", 1)[-1]) or "download"
    archive = work / "download" / name
    archive.parent.mkdir()
    if (kept := DOWNLOADS / source["sha256"]).is_file():
        shutil.copy(kept, archive)
    elif source["sha256"] in mirrored:
        try:
            download(MIRROR_URL + source["sha256"], archive, fresh=True)
        except subprocess.CalledProcessError:
            download(source["url"], archive, source.get("referer"))
    else:
        download(source["url"], archive, source.get("referer"))
    if (actual := sha256_of(archive)) != source["sha256"]:
        raise ValueError(f"SHA-256 is {actual}, but the lock pins {source['sha256']}")
    if mirrorable(source) and not kept.is_file():
        # Kept for `mirror`, so a download the mirror lacks isn't fetched twice.
        DOWNLOADS.mkdir(parents=True, exist_ok=True)
        partial = DOWNLOADS / f"{source['sha256']}.{os.getpid()}"
        shutil.copy(archive, partial)
        partial.replace(kept)
    staged = work / "staged"
    staged.mkdir()
    if not extract(archive, staged):
        shutil.copy(archive, staged / name)
    return staged


class Skip(Exception):
    """A cask that can never build from its locked source, which is cached so it isn't retried."""


def build_cask(entry, destination, mirrored=frozenset()):
    """Builds one cask into `destination`: its shipped fonts, preview, licence and entry.json."""
    token = entry["token"]
    work = WORK / token
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    try:
        root = stage(entry, work, mirrored)
        google = entry.get("google") or {}
        url = entry["source"].get("url") or entry["source"].get("git")
        if not (license := find_license(root, url, google.get("directory"))):
            # Without a license to ship alongside the fonts, there's no basis for redistributing them.
            raise Skip("no license found")
        paths = [
            root / artifact
            for artifact in dict.fromkeys(entry["artifacts"])
            if Path(artifact).suffix.lower() in FONT_SUFFIXES and (root / artifact).is_file()
        ]
        faces_by_path = {}
        for path in paths:
            try:
                faces_by_path[path] = read_faces(path)
            except Exception as error:  # noqa: BLE001 - one unreadable file shouldn't cost the cask
                print(f"{token}: can't read {path.name} ({type(error).__name__}: {error}); leaving it out")
        if not (candidates := [face for faces in faces_by_path.values() for face in faces]):
            raise Skip("no usable font files")
        selected = select_files(candidates)
        (destination / "fonts").mkdir(parents=True)
        files, shipped_faces, all_faces = [], [], []
        for path in selected:
            size = path.stat().st_size
            shippable = size <= MAX_FILE_BYTES
            faces = faces_by_path[path]
            if shippable:
                shutil.copy(path, destination / "fonts" / path.name)
                shipped_faces += faces
            else:
                # A cask made only of oversize files still belongs in the catalog, browsable and
                # previewed but shipping nothing; dropping it would hide Iosevka and Sarasa Gothic.
                print(f"{token}: not shipping {path.name}, {size / 1e6:.0f} MB")
            all_faces += faces
            # Named by PostScript name, which unlike family names is unique per file.
            files.append({"file": path.name, "asset": faces[0].postscript_name, "bytes": size, "shippable": shippable})
        # The app decides a cask is installed by resolving primaryFont, so it has to be a face that ships.
        primary = primary_face(shipped_faces or all_faces)
        sample = sample_for(primary)
        if sample is None:
            # Icon, emoji and music fonts draw none of the samples: a card would show the system font.
            raise Skip("draws none of the sample text")
        preview = write_preview(primary, token, destination, sample)
        (destination / "license.txt").write_text(license)
        built = {
            "files": files,
            "primaryFont": primary.postscript_name,
            "style": preview.style,
            "previewFile": preview.file,
            "glyphs": preview.glyphs,
            "fontVersion": preview.font_version,
        }
        if sample != SAMPLE_TEXT:
            built["sample"] = sample
        if google.get("directory") and (description := google_description(google["directory"])):
            built["description"] = description
        write_json(destination / "entry.json", built)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def build_job(job):
    """Runs in a worker process: builds into a temporary directory and moves it into place, so an
    interrupted run never leaves a half-built cask in the cache."""
    entry, destination, mirrored = job
    partial = destination.with_name(destination.name + ".partial")
    shutil.rmtree(partial, ignore_errors=True)
    partial.mkdir(parents=True)
    try:
        build_cask(entry, partial, mirrored)
    except Skip as reason:
        shutil.rmtree(partial)
        partial.mkdir()
        write_json(partial / "entry.json", {"skip": str(reason), "skipVersion": SKIP_VERSION})
    except Exception as error:  # noqa: BLE001 - a dead URL or bad file costs one cask, not the release
        shutil.rmtree(partial, ignore_errors=True)
        return entry["token"], f"{type(error).__name__}: {error}"
    shutil.rmtree(destination, ignore_errors=True)
    partial.rename(destination)
    return entry["token"], None


# MARK: - Assembling the catalog


def write_dataset(path, asset, token):
    group = FONTS / token
    dataset = group / f"{asset}.dataset"
    dataset.mkdir(parents=True)
    # actool skips a group folder with no Contents.json, which leaves the cask's asset pack empty: the tag
    # downloads fine and registration then fails with "could not be found in an asset catalog". No
    # provides-namespace, so the assets keep the bare PostScript names Catalog.json records.
    group_contents = group / "Contents.json"
    if not group_contents.exists():
        write_json(group_contents, CATALOG_INFO)
    try:
        os.link(path, dataset / path.name)
    except OSError:
        shutil.copy(path, dataset / path.name)
    write_json(
        dataset / "Contents.json",
        CATALOG_INFO
        | {
            "data": [{"filename": path.name, "idiom": "universal"}],
            "properties": {"on-demand-resource-tags": [token]},
        },
    )


def assign_packs(weights):
    """Maps each shipped cask to the On-Demand Resources tag its fonts download under.

    A cask of SMALL_CASK_BYTES or more is its own tag. Smaller casks share SHARED_PACKS tags, a cask
    going to the one its token hashes to: installing one downloads its pack-mates too, but only
    registers its own fonts, so the cost is a few hundred KB of extra download. Assigning by hash
    rather than position keeps a cask's pack, and the PR that ships a new line-up, unchanged when
    casks are added or removed elsewhere.
    """
    alone = sum(weight >= SMALL_CASK_BYTES for weight in weights.values())
    if alone + SHARED_PACKS > MAX_ASSET_PACKS:
        sys.exit(
            f"{alone} casks over {SMALL_CASK_BYTES / 1e6:.0f} MB need a pack each, which with "
            f"{SHARED_PACKS} shared packs is past the {MAX_ASSET_PACKS} allowed; trim the line-up"
        )
    packs = {}
    for token, weight in weights.items():
        if weight >= SMALL_CASK_BYTES:
            packs[token] = token
        else:
            bucket = int.from_bytes(hashlib.sha256(token.encode()).digest()[:8], "big") % SHARED_PACKS
            packs[token] = f"pack-{bucket + 1:03d}"
    return packs


def retag_datasets(token, tag):
    """Moves a cask's datasets onto a shared On-Demand Resources tag."""
    for contents in (FONTS / token).glob("*.dataset/Contents.json"):
        manifest = json.loads(contents.read_text())
        manifest["properties"]["on-demand-resource-tags"] = [tag]
        write_json(contents, manifest)


def restyle_apple_fonts(categories):
    """Corrects the styles in AppleFonts.json, which ApplePreviewRenderer classified from the fonts
    alone, and drops the math layout fonts and their previews."""
    path = APP / "AppleFonts.json"
    if not path.exists():
        return
    apple = json.loads(path.read_text())
    overrides = {name: style for style, names in APPLE_STYLES.items() for name in names}
    kept = []
    for family in apple:
        if APPLE_HIDDEN.match(family["name"]):
            for name in (family.get("previewFile"), *APPLE_PREVIEWS.glob(f"{family.get('preview') or '-'}-*.png")):
                if name:
                    (APPLE_PREVIEWS / Path(name).name).unlink(missing_ok=True)
            continue
        google = GOOGLE_CATEGORY_STYLES.get(categories.get(family["name"]))
        if google and family["style"] != "monospaced":
            family["style"] = google
        family["style"] = overrides.get(family["name"], family["style"])
        kept.append(family)
    write_json(path, kept)
    print(f"{len(kept)} Apple font families")


def rank_popularity(catalog, entries):
    """Ranks the catalog by popularity and by trend, 1 first, into each record's `popularity` and
    `trending`.

    Homebrew and Google measure different crowds: Homebrew's installs are dominated by Nerd Fonts
    and coding faces, and undercount Google families most people get from Google. So each cask is
    placed by percentile within each source that has it, Homebrew's yearly installs and Google's
    yearly views, and ranked by the better of the two. Trending is the same with the last 30 days
    against the yearly rate, among the top TRENDING_TOP_SHARE of each source.
    """
    locked = {entry["token"]: entry for entry in entries}
    by_token = {record["token"]: locked[record["token"]] for record in catalog}
    records = {record["token"]: record for record in catalog}
    sources = {
        "homebrew": lambda entry: (entry["installs"], entry.get("recentInstalls", 0)),
        "google": lambda entry: (
            (entry.get("google") or {}).get("views", 0),
            (entry.get("google") or {}).get("recentViews", 0),
        ),
    }

    def percentiles(scores):
        """Each token's share of the others it beats, from 1 for the highest score down toward 0. Ties
        go by token, so the same lock always ranks the same way."""
        ordered = sorted(scores, key=lambda token: (-scores[token], token))
        return {token: 1 - index / len(ordered) for index, token in enumerate(ordered)}

    popular, trending = {}, {}
    for measure in sources.values():
        yearly = {token: measure(entry)[0] for token, entry in by_token.items() if measure(entry)[0]}
        ranked = percentiles(yearly)
        busy = [token for token, share in ranked.items() if share > 1 - TRENDING_TOP_SHARE]
        growth = percentiles({token: measure(by_token[token])[1] * 12 / yearly[token] for token in busy})
        for token, share in ranked.items():
            popular[token] = max(popular.get(token, 0), share)
        for token, share in growth.items():
            trending[token] = max(trending.get(token, 0), share)
    for key, scores in (("popularity", popular), ("trending", trending)):
        for rank, token in enumerate(sorted(scores, key=lambda token: (-scores[token], token)), 1):
            records[token][key] = rank


def report(title, items):
    """A summary line and its items, one to a line: folded into a collapsible group in a GitHub
    Actions log, where hundreds of casks on one line wrapped into an unreadable block."""
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::group::{title} ({len(items)})")
        print("\n".join(items) or "-")
        print("::endgroup::")
    else:
        print(f"{title} ({len(items)}): {', '.join(items) or '-'}")


def build(only=None, max_mb_per_install=None, jobs=1):
    """`build`: builds the catalog, previews, licences and font assets from fonts.lock.json.

    Every cask builds into .cache/built/<token>/<key>, keyed by its locked source, so a cask whose
    source hasn't changed since the last run is reused rather than downloaded and subset again; in CI
    that directory is kept by the Actions cache. Then everything is assembled in rank order: a face
    two casks share goes to the higher-ranked, heavy niche casks are left out of the assets, and small
    casks share On-Demand Resources tags once there are more casks than Apple allows packs.

    `only` limits the font assets to those casks, for a quick local or fallback build; the catalog
    lists every cask either way. max_mb_per_install trims casks over NICHE_MIN_BYTES that cost more
    than that per yearly install, except the Google families and ALWAYS_INCLUDED: Homebrew counts
    undercount fonts most people get from Google.
    """
    locked = json.loads(LOCK.read_text())
    entries = locked["casks"]
    keys = {entry["token"]: cache_key(entry) for entry in entries}
    destinations = {token: BUILT / token / key for token, key in keys.items()}

    def cached(token):
        path = destinations[token] / "entry.json"
        if not path.is_file():
            return False
        built = json.loads(path.read_text())
        return "skip" not in built or built.get("skipVersion") == SKIP_VERSION

    pending = [entry for entry in entries if not cached(entry["token"])]
    print(f"{len(entries) - len(pending)} of {len(entries)} casks cached; building {len(pending)}")

    failed = {}
    if pending:
        update_clone(locked["googleFonts"])
        directories = {entry["source"]["google"] for entry in pending if "google" in entry["source"]}
        directories |= {
            entry["google"]["directory"] for entry in pending if (entry.get("google") or {}).get("directory")
        }
        checkout(locked["googleFonts"], directories)
        mirrored = (
            frozenset(mirrored_hashes()) if any(mirrorable(entry["source"]) for entry in pending) else frozenset()
        )
        with ProcessPoolExecutor(max_workers=jobs) as pool:
            queued = [(entry, destinations[entry["token"]], mirrored) for entry in pending]
            for done, (token, error) in enumerate(pool.map(build_job, queued), 1):
                if error:
                    failed[token] = error
                    print(f"{token}: {error}; retrying once the rest are built")
                if done % 100 == 0:
                    print(f"built {done} of {len(pending)}")
        # Again one at a time, after the rest: by then a host that was briefly down, or swamped by several
        # downloads at once, may answer.
        for entry in [entry for entry in pending if entry["token"] in failed]:
            token, error = build_job((entry, destinations[entry["token"]], mirrored))
            if error:
                failed[token] = error
                # An annotation in GitHub Actions, so it shows on the run's summary page.
                prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") else "warning: "
                print(f"{prefix}{token}: {error}")
            else:
                del failed[token]
        if failed:
            report("failed to build, retried next run", list(failed))

    # Only what this lock uses stays, so the Actions cache doesn't grow without bound.
    for directory in BUILT.glob("*/*"):
        if destinations.get(directory.parent.name) != directory:
            shutil.rmtree(directory)
    for directory in BUILT.glob("*"):
        if directory.is_dir() and not any(directory.iterdir()):
            directory.rmdir()

    for directory in (FONTS, PREVIEWS, LICENSES):
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir(parents=True)
    write_json(FONTS / "Contents.json", CATALOG_INFO)

    catalog, owners, weights, licenses = [], {}, {}, {}
    skipped, trimmed, unshippable, shadowed = {}, {}, {}, {}
    for entry in entries:
        token, destination = entry["token"], destinations[entry["token"]]
        if not (destination / "entry.json").is_file():
            continue
        built = json.loads((destination / "entry.json").read_text())
        if "skip" in built:
            skipped[token] = built["skip"]
            continue
        # Two casks can carry the same face; the higher-ranked one keeps it.
        files, faces = [], set()
        for file in built["files"]:
            if file["asset"] in owners:
                print(f"{token}: {file['asset']!r} already comes from {owners[file['asset']]}")
            # A cask shipping the same face twice, as TTF and OTF, keeps the first quietly.
            elif file["asset"] not in faces:
                faces.add(file["asset"])
                files.append(file)
        if not files:
            shadowed[token] = sorted({owners[file["asset"]] for file in built["files"]})
            continue
        shipping = [file for file in files if file["shippable"]]
        weight = sum(file["bytes"] for file in shipping)
        if (
            max_mb_per_install
            and not entry["exempt"]
            and weight > NICHE_MIN_BYTES
            and weight / 1e6 / max(entry["installs"], 1) > max_mb_per_install
        ):
            trimmed[token] = f"{weight / 1e6:.0f} MB, {entry['installs']:,} installs"
            shipping = []
        if only is not None and token not in only:
            shipping = []
        elif not shipping:
            # Left out altogether rather than listed with nothing to install, and without claiming
            # its faces, so a lower-ranked cask that has them can still ship them.
            if token not in trimmed:
                unshippable[token] = f"every file is over {MAX_FILE_BYTES // 1024**2} MB"
            continue
        owners.update(dict.fromkeys(faces, token))
        for file in shipping:
            write_dataset(destination / "fonts" / file["file"], file["asset"], token)
        if shipping:
            weights[token] = weight
        shutil.copy(destination / built["previewFile"], PREVIEWS / built["previewFile"])
        shutil.copy(destination / "license.txt", LICENSES / f"{token}.txt")
        licenses[token] = (destination / "license.txt").read_text()

        google = entry.get("google") or {}
        style = built["style"]
        # PANOSE and the OS/2 family class are all a font says about itself, and most Google families
        # fill in neither, so Nothing You Could Do read as sans serif. Fixed pitch, which a font does
        # state reliably, still wins: a monospaced face stays in Fixed Width whatever Google says.
        if (google_style := GOOGLE_CATEGORY_STYLES.get(google.get("category"))) and style != "monospaced":
            style = google_style
        record = {
            "token": token,
            "name": entry["name"],
            "homepage": entry["homepage"],
            "installs": entry["installs"],
            "bytes": sum(file["bytes"] for file in files),
            "fonts": len(files),
            "assets": [file["asset"] for file in shipping],
            "primaryFont": built["primaryFont"],
            "style": style,
            "previewFile": built["previewFile"],
            "glyphs": built["glyphs"],
            "version": cask_version(entry["version"], built["fontVersion"]),
            "fontVersion": built["fontVersion"],
        }
        if "sample" in built:
            record["sample"] = built["sample"]
        if "description" in built:
            record["description"] = built["description"]
            # Google's descriptions are often the designer's own words, in the first person.
            if designers := google.get("designers"):
                record["designers"] = designers
        catalog.append(record)

    rank_popularity(catalog, entries)
    packs = assign_packs(weights)
    for record in catalog:
        if pack := packs.get(record["token"]):
            record["pack"] = pack
            if pack != record["token"]:
                retag_datasets(record["token"], pack)

    write_json(
        APP / "Catalog.json",
        {
            "source": "Homebrew cask install analytics, 365 days, and every Google Fonts family",
            "generated": locked["generated"],
            "sampleText": SAMPLE_TEXT,
            "glyphSample": GLYPH_SAMPLE,
            "casks": catalog,
        },
    )
    write_license_bundle(licenses)
    restyle_apple_fonts(locked["googleCategories"])
    report("skipped", [f"{token} ({reason})" for token, reason in skipped.items()])
    report("trimmed heavy niche casks", [f"{token} ({reason})" for token, reason in trimmed.items()])
    report("left out, too large to ship", list(unshippable))
    # Why a locked cask is missing from the catalog or ships nothing, for scripts/fonts-changelog.py.
    write_json(
        CACHE / "build-report.json",
        {"failed": failed, "skipped": skipped, "trimmed": trimmed, "unshippable": unshippable, "shadowed": shadowed},
    )
    print(
        f"{len(catalog)} casks; {len(weights)} ship {sum(len(r['assets']) for r in catalog)} fonts "
        f"in {len(set(packs.values()))} asset packs"
    )


def write_license_bundle(licenses):
    """Writes LICENSE_BUNDLE. Sorted and compact, so the same licenses always deflate to the same bytes."""
    text = json.dumps(licenses, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    # Negative window bits make raw DEFLATE, with no zlib header, which is what Apple's .zlib reads.
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    LICENSE_BUNDLE.write_bytes(compressor.compress(text.encode()) + compressor.flush())


def mirror():
    """`mirror`: gathers in .cache/mirror/ each download the mirror lacks for a cask in the catalog,
    checked against the lock, for publish-fonts.sh upload to add to it. Downloads that build or lock kept
    aren't fetched again."""
    catalog = {cask["token"] for cask in json.loads((APP / "Catalog.json").read_text())["casks"]}
    have = mirrored_hashes()
    wanted = {}
    for entry in json.loads(LOCK.read_text())["casks"]:
        source = entry["source"]
        if entry["token"] in catalog and mirrorable(source) and source["sha256"] not in have:
            wanted.setdefault(source["sha256"], (entry["token"], source))
    shutil.rmtree(MIRROR, ignore_errors=True)
    MIRROR.mkdir(parents=True)
    missing = []
    for sha256, (token, source) in sorted(wanted.items()):
        if upstream_matches(source):
            shutil.copy(DOWNLOADS / sha256, MIRROR / sha256)
        else:
            missing.append(token)
    if missing:
        report("not mirrored: the download can't be had or doesn't match, retried next run", missing)
    print(f"{len(wanted) - len(missing)} downloads to add to the {MIRROR_TAG} mirror, which has {len(have)}")


# MARK: - Apple's fonts


def embedding(font):
    """The OS/2 fsType embedding permission. Old fonts often set several bits, and the OpenType spec
    has the least restrictive win, as Font Book shows it: Lucida Grande's 0x6 is preview and print."""
    flags = font["OS/2"].fsType if "OS/2" in font else 0
    if not flags & 0xE:
        return "installable"
    if flags & 0x8:
        return "editable"
    if flags & 0x4:
        return "preview & print"
    return "restricted"


def apple_previews():
    """`apple-previews`: subsets each of Apple's downloadable families into ApplePreviews/, in place of
    the image ApplePreviewRenderer drew, from the copy of the font the simulator downloaded for it.

    The simulator's copies are iOS's own, which is what the app previews, and reading them from disk
    needs no Core Text on the Mac: there, even matching a downloadable font that isn't downloaded yet
    triggers auto-activation, a "needs to download the font" dialog for each one.

    A family keeps its image when the simulator gave no file for it, or it was erased since, when the
    font restricts embedding (the least restrictive fsType bit counts), or when its sample needs
    shaping only Apple's AAT tables do: fontTools drops morx when it subsets, so an Arabic or Indic
    face with no OpenType layout of its own would draw unjoined. Built-in families need neither, since
    the device draws them itself.
    """
    path = APP / "AppleFonts.json"
    apple = json.loads(path.read_text())
    downloadable = [family for family in apple if not family["builtIn"]]
    kept = {"no font file": [], "restricted": [], "AAT shaping only": [], "subsetting failed": []}
    for family in downloadable:
        name = family["name"]
        # A path on this Mac only, so it doesn't belong in the committed JSON.
        file = Path(family.pop("fontFile", None) or "/nonexistent")
        face = (
            next((face for face in read_faces(file) if face.postscript_name == family["previewFace"]), None)
            if file.is_file()
            else None
        )
        if face is None:
            kept["no font file"].append(name)
            continue
        with TTFont(face.path, fontNumber=face.number, lazy=True) as font:
            if embedding(font) == "restricted":
                kept["restricted"].append(name)
                continue
            if family.get("sample") and "morx" in font and "GSUB" not in font:
                kept["AAT shaping only"].append(name)
                continue
        token = "apple-" + re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-").lower()
        try:
            preview = write_preview(face, token, APPLE_PREVIEWS, family.get("sample") or SAMPLE_TEXT)
        except Exception as error:  # noqa: BLE001 - e.g. an EBLC bitmap table fontTools can't read
            kept["subsetting failed"].append(f"{name} ({type(error).__name__})")
            continue
        family["previewFile"] = preview.file
        for image in APPLE_PREVIEWS.glob(f"{family.pop('preview', None) or '-'}-*.png"):
            image.unlink()
    write_json(path, apple)
    print(f"{sum('previewFile' in f for f in apple)} of {len(downloadable)} downloadable families subset")
    for reason, names in kept.items():
        print(f"kept the image, {reason} ({len(names)}): {', '.join(names) or '-'}")
    restyle_apple_fonts(json.loads(LOCK.read_text())["googleCategories"])


def main():
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    lock_command = commands.add_parser("lock", help="pin the line-up's sources in fonts.lock.json")
    lock_command.add_argument(
        "--count",
        type=int,
        default=DEFAULT_CATALOG_SIZE,
        metavar="N",
        help=f"how many of Homebrew's most-installed casks to include; casks "
        f"without a license are dropped when building (default {DEFAULT_CATALOG_SIZE})",
    )
    lock_command.add_argument(
        "--google-top",
        type=int,
        metavar="N",
        help="include only the N most popular Google Fonts families, whatever their "
        "Homebrew rank, rather than every family; 0 for none",
    )

    build_command = commands.add_parser("build", help="build everything from fonts.lock.json")
    build_command.add_argument("--fonts", nargs="+", metavar="TOKEN", help="write font assets only for these casks")
    build_command.add_argument(
        "--max-mb-per-install",
        type=float,
        metavar="MB",
        help="leave out casks over 10 MB that cost more than this per yearly install; "
        "Google families and ALWAYS_INCLUDED are never trimmed",
    )
    build_command.add_argument(
        "--jobs",
        type=int,
        default=max(2, (os.cpu_count() or 2) // 2),
        metavar="N",
        help="build this many casks at once (default: half the cores); subsetting a CJK collection takes over a GB",
    )

    commands.add_parser("mirror", help="gather the downloads the mirror lacks, after build")
    commands.add_parser(
        "apple-previews", help="subset Apple's downloadable fonts' previews; run right after ApplePreviewRenderer"
    )
    arguments = parser.parse_args()
    if arguments.command == "lock":
        lock(arguments.count, arguments.google_top)
    elif arguments.command == "build":
        build(
            only=set(arguments.fonts) if arguments.fonts else None,
            max_mb_per_install=arguments.max_mb_per_install,
            jobs=arguments.jobs,
        )
    elif arguments.command == "mirror":
        mirror()
    else:
        apple_previews()


if __name__ == "__main__":
    sys.exit(main())
