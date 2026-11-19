#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["fonttools==4.67.0", "lxml==6.1.3", "uharfbuzz==0.51.1"]  # lxml subsets OpenType-SVG color fonts
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
check-licenses fails if Licenses.deflate isn't what Licenses/ deflates to, for CI.
"""

import argparse
import base64
import csv
import functools
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
from collections import Counter
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from pathlib import Path

import uharfbuzz
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
    # Input is free for personal use only. Its license forbids redistribution, embedding in an app
    # and self-hosted webfonts, each of which needs a license bought from the publisher, and bars
    # distributing modified copies, which a subset preview is.
    "font-input",
    # Microsoft's Consolas with Powerline glyphs patched in, as CONSOLA-Powerline.ttf and its
    # siblings. The repository's BSD-2 license covers the patching; Consolas ships with Windows and
    # isn't redistributable. github_license() finds a repository's license without being able to
    # tell that it doesn't cover the fonts beside it, which is how this one got in.
    "font-consolas-for-powerline",
    # GPL and AGPL fonts, which Typecask doesn't ship at all. Apple's App Store terms impose device
    # limits and DRM that conflict with GPL section 6; that's what got VLC and GNU Go pulled, and
    # these fonts go to Apple as On-Demand Resources like everything else. A font exception, which
    # fandol and urw-base35 carry, covers embedding a font in a document and says nothing about
    # this. Any other GPL cask belongs here too.
    "font-average-mono",
    "font-fandol",
    "font-freefont",
    "font-nimbus-sans-l",
    "font-urw-base35",
    "font-urw-core35",
    # Fontshare's fonts, under ITF's Free Font License, which doesn't allow redistributing them through
    # an app. EXCLUDED_HOSTS keeps out any other cask that downloads from Fontshare.
    "font-satoshi",
    # Draws every character as nothing, for testing font loading on the web: nothing to install.
    "font-adobe-blank",
    # Icons, symbols and emoji have nothing to preview.
    "font-symbols-only-nerd-font",
    "font-powerline-symbols",
    "font-fontawesome",
    # Maps a-z to glyphs of a single point, for typing an icon's name that a ligature replaces.
    "font-material-icons",
    "font-sketchybar-app-font",
    "font-noto-color-emoji",
    "font-noto-color-emoji-compat-test",
    # Bundles the faces of font-noto-sans-cjk-{sc,jp,kr}, which would collide.
    "font-noto-sans-cjk",
    # Renamed Asta Sans on Google Fonts, which font-asta-sans installs. Homebrew still has the old
    # cask, pointing at a specimen page that's gone.
    "font-42dot-sans",
}
# Files left out of a cask, by name prefix, for faults the App Store's font validation rejects
# (ITMS-90792) and that re-saving doesn't mend, or that the face draws wrong. Leaving a face out moves
# primary_face() to the next.
LEFT_OUT_FILES = {
    # EB Garamond 0.016's 8-point optical size draws its fraction slash as an empty glyph a full em
    # wide, so its fractions came out as figures with a gap between them. The 12-point size, the one
    # made for text, draws it, and has more glyphs and features besides.
    "font-eb-garamond": ["EBGaramond08", "EBGaramondSC08"],
    # Nerd Fonts 3.5.1's GohuFont 11 has a malformed bitmap strike ("'sbit' embedded bitmap
    # structure"). Its uni11 sibling is the same 11 px design covering more of Unicode, and leaving
    # out the 14 px files too makes it the primary face rather than GohuFont 14.
    "font-gohufont-nerd-font": ["GohuFont11", "GohuFont14"],
}
# Hosts whose fonts don't allow redistribution, so no cask that downloads from one ships.
EXCLUDED_HOSTS = {"fontshare.com"}
ALWAYS_INCLUDED = [
    "font-ioskeley-mono",
    "font-ioskeley-mono-term-nerd-font",
    "font-geist-serif",
    "font-dinish",
    "font-comic-shanns-mono",
    "font-opendyslexic",
    # Every font The League of Moveable Type publishes on GitHub, which a Typecask article holds up as one
    # of the first open-source foundries; several sit near the install cutoff. All but The Neue Black,
    # whose 1.007 release is corrupt.
    "font-blackout",
    "font-chunk",
    "font-fanwood-text",
    "font-goudy-bookletter-1911",
    "font-junction",
    "font-knewave",
    "font-league-gothic",
    "font-league-mono",
    "font-league-script",
    "font-league-spartan",
    "font-linden-hill",
    "font-orbitron",
    "font-ostrich-sans",
    "font-prociono",
    "font-raleway",
    "font-sniglet",
    "font-sorts-mill-goudy",
]
# Casks Homebrew doesn't have yet, or has only disabled, in its API's shape, from the upstream release.
# Homebrew's own working cask takes over once it has one, and lock says so, for the entry to go.
EXTRA_CASKS = [
    {
        # Homebrew has only font-comic-shanns-mono-nerd-font. Upstream ships the Regular alone; the Bold
        # in Nerd Fonts' copy is their own addition.
        "token": "font-comic-shanns-mono",
        "name": ["Comic Shanns Mono"],
        "homepage": "https://github.com/jesusmgg/comic-shanns-mono",
        "url": "https://github.com/jesusmgg/comic-shanns-mono/releases/download/v1.3.0/comic-shanns-mono-v1.3.0.zip",
        "version": "1.3.0",
        "sha256": "3cc8abae7b8fab7d41c2b03a3fad974998994998bfb24bfc9544fc826a582460",
        "artifacts": [{"font": ["ComicShannsMono-Regular.otf"]}],
    },
    {
        # Homebrew disabled its cask when forge.hackers.town went unreachable. The archived GitHub repo
        # still has the last release, OFL (the Bitstream Vera license covers only the older 2.x fonts).
        "token": "font-opendyslexic",
        "name": ["OpenDyslexic"],
        "homepage": "https://opendyslexic.org/",
        "url": "https://github.com/antijingoist/opendyslexic/releases/download/v0.91.12/opendyslexic-0.910.12-rc2-2019.10.17.zip",
        "version": "0.91.12",
        "sha256": "b92d7fcb9409f2bcfd23b65ac71647256eb49c429f4fbb1cc870381fc93eb486",
        "artifacts": [
            {"font": [f"OpenDyslexic-{style}.otf"]} for style in ("Regular", "Italic", "Bold", "Bold-Italic")
        ],
    },
    {
        # The League of Moveable Type's slab, never cut as a release; pinned to the repository's last commit.
        "token": "font-chunk",
        "name": ["Chunk"],
        "homepage": "https://www.theleagueofmoveabletype.com/chunk",
        "url": "https://github.com/theleagueof/chunk/archive/12a243f3fb7c7a68844901023f7d95d6eaf14104.tar.gz",
        "version": "2021-03-03",
        "sha256": "78985b4effbe6e434a33e81fe544064a73f83c31a9981480b5b371d69113014f",
        "artifacts": [
            {"font": [f"chunk-12a243f3fb7c7a68844901023f7d95d6eaf14104/{name}.otf"]}
            for name in ("ChunkFive-Regular", "Chunk Five Print")
        ],
    },
]
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
# google/fonts tags families by mood and use, each tag scored 0 - 100, including the holidays a family
# suits under /Seasonal/. The lock keeps every family's seasonal tags; the build picks the holidays.
GOOGLE_TAGS = "tags/all/families.csv"
GOOGLE_SEASONAL_TAG = "/Seasonal/"
# The app's holiday collections, by Google's seasonal tag, and the catalog's name for each.
HOLIDAYS = {
    "Lunar New Year": "lunarNewYear",
    "Valentine's Day": "valentinesDay",
    "Halloween": "halloween",
    "Diwali": "diwali",
    "Christmas": "christmas",
}
# Below this a seasonal tag is a stretch: Google tags Google Sans for Diwali at 60.
HOLIDAY_MIN_SCORE = 80
# Google tags only its own families, so casks from elsewhere are added by hand.
HOLIDAY_CASKS = {
    "lunarNewYear": ["font-lxgw-wenkai", "font-smiley-sans"],
}
# The app's Legibility collection: fonts their designers made to be easy to read. Atkinson Hyperlegible
# for the Braille Institute's low-vision readers, Lexend and its Arabic sibling Readex Pro for reading
# fluency, OpenDyslexic for dyslexia, Andika for beginning readers, B612 for Airbus's cockpit displays,
# Intel One Mono for low-vision developers, and Inclusive Sans and Lexica Ultralegible for accessibility
# generally. Picked by hand; the catalog marks each `legible`.
LEGIBLE_CASKS = {
    "font-andika",
    "font-atkinson-hyperlegible",
    "font-atkinson-hyperlegible-mono",
    "font-atkinson-hyperlegible-next",
    "font-atkynson-mono-nerd-font",
    "font-b612",
    "font-b612-mono",
    "font-inclusive-sans",
    "font-intel-one-mono",
    "font-lexend",
    "font-lexend-deca",
    "font-lexend-exa",
    "font-lexend-giga",
    "font-lexend-mega",
    "font-lexend-peta",
    "font-lexend-tera",
    "font-lexend-zetta",
    "font-lexica-ultralegible",
    "font-opendyslexic",
    "font-opendyslexic-nerd-font",
    "font-readex-pro",
}
# Nerd Font casks whose plain cask pair_nerd_fonts() can't find by name, or finds wrongly, by token:
# the plain cask to show it with, or None for none.
NERD_FONT_PAIRS = {
    # Nerd Fonts renamed Terminus, and its cask names it after the bitmap original's TTF.
    "font-terminess-ttf-nerd-font": "font-terminus",
    # Microsoft and GitHub publish their own Nerd Font builds, from the same release as the plain font and
    # under its name, so those are the ones paired; Nerd Fonts' renamed patches stay cards of their own.
    "font-caskaydia-cove-nerd-font": None,
    "font-caskaydia-mono-nerd-font": None,
    "font-monaspice-nerd-font": None,
}
# Google families with no description of their own, by token: the google/fonts directory of a family
# whose description covers them too.
DESCRIPTION_DIRECTORIES = {
    # Kumar One's description is of both Kumar fonts, the Outline included.
    "font-kumar-one-outline": "ofl/kumarone",
    # The same Rounded M+ 1c, under the directory Google listed it in before.
    "font-m-plus-rounded-1c": "ofl/roundedmplus1c",
}
# Nerd Font and Powerline casks whose names don't give the original family, or give it badly, by token:
# the original's name, for their description.
PATCHED_ORIGINALS = {
    "font-anonymice-powerline": "Anonymous Pro",
    "font-delugia-mono-powerline": "Cascadia Mono",
    "font-delugia-powerline": "Cascadia Code",
    "font-fira-mono-nerd-font": "Fira Mono",
    "font-hackgen-nerd": "HackGen",
    "font-ioskeley-mono-term-nerd-font": "Ioskeley Mono",
    "font-liberation-mono-for-powerline": "Liberation Mono",
    "font-m+-nerd-font": "M+",
    "font-martian-mono-nerd-font": "Martian Mono",
    "font-monocraft-nerd-font": "Monocraft",
    "font-ubuntu-mono-derivative-powerline": "Ubuntu Mono",
}
# The app's Symbols collection: fonts typed on an ordinary keyboard that draw something other than
# letters. Redacted's scribbles and Flow's blocks stand in for text in wireframes, Yarndings draws
# knitting symbols, and the Charted fonts draw their letters as stitches on a grid. Google classifies
# most of them Symbols, which otherwise keeps a family out of the line-up (barcodes, Linefont), so this
# list keeps them in too. Picked by hand; the catalog marks each `symbols`.
SYMBOL_CASKS = {
    "font-flow-block",
    "font-flow-circular",
    "font-flow-rounded",
    "font-jacquard-12-charted",
    "font-jacquard-24-charted",
    "font-jacquarda-bastarda-9-charted",
    "font-jersey-20-charted",
    "font-micro-5-charted",
    "font-redacted",
    "font-redacted-script",
    "font-yarndings-12",
    "font-yarndings-12-charted",
    "font-yarndings-20",
    "font-yarndings-20-charted",
}
# Casks that pull a single file out of google/fonts, rather than checking out the family directory.
GOOGLE_RAW_FILE = re.compile(r"github\.com/google/fonts/raw/[^/]+/(.+)/([^/]+)$")
# A download from a GitHub release, or a tag's source archive: the release says when it was published.
GITHUB_RELEASE_FILE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/")
GITHUB_TAG_ARCHIVE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/archive/refs/tags/(.+)\.(?:zip|tar\.gz)$")
# A branch's archive or one of its files: the last commit to touch it says when it changed.
GITHUB_BRANCH_ARCHIVE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/archive/refs/heads/(.+)\.(?:zip|tar\.gz)$")
GITHUB_BRANCH_FILE = re.compile(
    r"^https://(?:raw\.)?github\.com/([^/]+)/([^/]+)/(?:raw|blob)/(?:refs/(?:heads|tags)/)?([^/]+)/(.+)$"
)
GITHUB_REPOSITORY = re.compile(r"^https://github\.com/([^/]+)/([^/.]+)(?:\.git)?$")
GOOGLE_LICENSE_NAMES = ("OFL.txt", "LICENSE.txt", "UFL.txt", "LICENCE.txt")
GOOGLE_FONTS_URL = "https://github.com/google/fonts.git"
PANGRAM = "The quick brown fox jumps over the lazy dog"
SAMPLE_TEXT = PANGRAM + " 0123456789 {}[]()<>=!&|"
# What has_coding_ligatures() shapes, and the sample a face with them shows instead, so its card and page
# draw them. Sequences of punctuation only: a cursive face's contextual alternates join "www", and nearly
# every text face has "fi", neither of which is what a coding face's ligatures mean.
CODING_LIGATURES = ("->", "=>", "!=", "===", "<=", ">=", "|>", "::")
# A face has coding ligatures when shaping this many of CODING_LIGATURES with liga, calt and clig turned
# off changes their glyphs. Fira Code, Cascadia Code and JetBrains Mono change all eight or nearly, a
# handwriting face none, and an Arabic face's required ligatures none.
CODING_LIGATURES_MIN = 3
LIGATURE_SAMPLE_TEXT = PANGRAM + " 0123456789 " + " ".join(CODING_LIGATURES)
# A face that has fewer of PANGRAM's letters than this has no Latin. Faces have all of them or
# none, bar a barcode font's 81%.
LATIN_COVERAGE = 0.8
# A line in each script, for a face previewed in its own: the same list as scriptSamples in
# TypecaskUITests/ApplePreviewRenderer.swift, which picks Apple's fonts' samples. Keyed by ISO 15924
# code, as google/fonts names a family's primary script, and tried in order for a face with no Latin.
SCRIPT_SAMPLES = {
    "Jpan": "いろはにほへと ちりぬるを",  # Japanese
    "Hans": "天地玄黄 宇宙洪荒",  # Chinese, simplified
    "Hant": "天地玄黃 宇宙洪荒",  # Chinese, traditional
    "Kore": "다람쥐 헌 쳇바퀴에 타고파",  # Korean
    "Arab": "أبجد هوز حطي كلمن",  # Arabic
    "Hebr": "דג סקרן שט בים מאוכזב",  # Hebrew
    "Deva": "नमस्ते दुनिया",  # Devanagari
    "Beng": "বাংলা লিপি",  # Bengali
    "Guru": "ਗੁਰਮੁਖੀ ਲਿਪੀ",  # Gurmukhi
    "Gujr": "ગુજરાતી લિપિ",  # Gujarati
    "Orya": "ଓଡ଼ିଆ ଲିପି",  # Odia
    "Taml": "தமிழ் எழுத்து",  # Tamil
    "Telu": "తెలుగు లిపి",  # Telugu
    "Knda": "ಕನ್ನಡ ಲಿಪಿ",  # Kannada
    "Mlym": "മലയാളം ലിപി",  # Malayalam
    "Sinh": "සිංහල අක්ෂර",  # Sinhala
    "Thai": "สวัสดีชาวโลก",  # Thai
    "Laoo": "ສະບາຍດີ",  # Lao
    "Khmr": "សួស្តីពិភពលោក",  # Khmer
    "Mymr": "မင်္ဂလာပါ",  # Myanmar
    "Tibt": "བོད་ཡིག",  # Tibetan
    "Geor": "ქართული დამწერლობა",  # Georgian
    "Armn": "Հայերեն այբուբեն",  # Armenian
    "Ethi": "ግዕዝ ፊደል",  # Ethiopic
    "Cher": "ᏣᎳᎩ ᎦᏬᏂᎯᏍᏗ",  # Cherokee
    "Cans": "ᐃᓄᒃᑎᑐᑦ",  # Canadian syllabics
    "Mong": "ᠮᠣᠩᠭᠣᠯ ᠪᠢᠴᠢᠭ",  # Mongolian
    "Syrc": "ܠܫܢܐ ܣܘܪܝܝܐ",  # Syriac
    "Mtei": "ꯃꯤꯇꯩ ꯃꯌꯦꯛ",  # Meetei Mayek
    "Olck": "ᱚᱞ ᱪᱤᱠᱤ",  # Ol Chiki
    "Brai": "⠃⠗⠁⠊⠇⠇⠑",  # Braille
}
CJK_SCRIPTS = ("Jpan", "Hans", "Hant", "Kore")
# google/fonts' names for scripts this list has under another.
SCRIPT_ALIASES = {"Hira": "Jpan", "Kana": "Jpan", "Hrkt": "Jpan", "Hang": "Kore", "Hani": "Hans"}
# A CJK family's region, as its name gives it: Noto Sans CJK JP and KR carry the same characters.
CJK_REGIONS = {"Jpan": "JP", "Kore": "KR", "Hans": "SC|CN|GB", "Hant": "TC|HK|MO|TW"}
# What a family's name calls each script: October Gujarati and Kigelia Arabic carry Devanagari or the
# scripts of Europe as well as their own.
SCRIPT_NAMES = {
    "Arab": "Arabic|Urdu|Kufi|Naskh|Nastaliq",
    "Hebr": "Hebrew",
    "Deva": "Devanagari",
    "Beng": "Bangla|Bengali",
    "Guru": "Gurmukhi",
    "Gujr": "Gujarati",
    "Orya": "Odia|Oriya",
    "Taml": "Tamil",
    "Telu": "Telugu",
    "Knda": "Kannada",
    "Mlym": "Malayalam",
    "Sinh": "Sinhala",
    "Thai": "Thai",
    "Laoo": "Lao",
    "Khmr": "Khmer",
    "Mymr": "Myanmar",
    "Tibt": "Tibetan",
    "Geor": "Georgian",
    "Armn": "Armenian",
    "Ethi": "Ethiopic",
    "Cher": "Cherokee",
    "Cans": "Canadian Aboriginal|UCAS",
    "Mong": "Mongolian",
    "Syrc": "Syriac",
    "Mtei": "Meetei Mayek",
    "Olck": "Ol Chiki",
}
# The lowercase alphabets that make a face Greek or Cyrillic too, for filtering by script: Latin's is
# PANGRAM, and the others are SCRIPT_SAMPLES.
EUROPEAN_ALPHABETS = {"Grek": (0x03B1, 0x03C9), "Cyrl": (0x0430, 0x044F)}
# A face for another script mostly carries Latin, Greek or Cyrillic only to set beside its own, as Noto
# Sans CJK and D2Coding do, so the filter lists it under those only where its own script is Latin or
# that one. These are Latin families whatever their own script: google/fonts calls them Devanagari.
LATIN_TOO = {"font-poppins", "font-teko"}
# Scripts Latin faces carry beside Greek or Cyrillic alone, as Rubik and Amatic SC carry Hebrew; a
# Thai or Indic face may carry Cyrillic itself, as Thonburi does.
BESIDE_EUROPE = ("Hebr", "Arab", "Armn", "Geor")
# Kanji made in Japan, which Chinese character sets lack though they carry the kana.
JAPANESE_KANJI = "込働畑"
# The characters own_script() counts to tell a face's script.
SCRIPT_RANGES = {
    "kana": (0x3040, 0x30FF),
    "han": (0x4E00, 0x9FFF),
    "hangul": (0xAC00, 0xD7A3),
    "greek": (0x0391, 0x03C9),
    "cyrillic": (0x0410, 0x044F),
}

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
# Casks whose PANOSE reading gets their style wrong and that Google has no category for (yet).
CASK_STYLES = {
    # PANOSE says sans serif.
    "font-geist-serif": "serif",
    # Doesn't set isFixedPitch, and a few glyphs stray from its 600 advance.
    "font-comic-shanns-mono": "monospaced",
    # PANOSE says sans serif; it's an ultra-bold slab.
    "font-chunk": "serif",
}
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
# The League of Moveable Type's older repositories name theirs "Open Font License.markdown". Read only when
# nothing above turns up, so casks that already have a license build as before.
FALLBACK_LICENSE_SUFFIXES = (".markdown",)
GITHUB_REPO = re.compile(r"github\.com/([^/]+)/([^/]+?)(?:\.git)?/")
CATALOG_INFO = {"info": {"author": "xcode", "version": 1}}
# Some hosts turn away clients that don't look like a browser or Homebrew.
USER_AGENT = "Homebrew/4.6 (Macintosh; arm64 Mac OS X 26.0) curl/8.7.1"
# Part of every built cask's cache key. Bump it when a change here alters what a cask builds into,
# such as the preview's text or which files are selected, so cached casks are rebuilt.
PIPELINE_VERSION = 12
# A cask skipped for want of a license or usable fonts is remembered rather than rebuilt every run.
# Bump this when a change might rescue some of them, such as a new place to find licenses: only the
# skipped casks are retried, not the whole line-up.
SKIP_VERSION = 3

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Typecask"
FONTS = APP / "Fonts.xcassets"
# The few casks' fonts a debug build carries, from scripts/debug-fonts.py.
DEBUG_FONTS = APP / "DebugFonts.xcassets"
PREVIEWS = APP / "Previews"
CATALOG = APP / "Catalog.json"
# Each cask's license as text, for review: outside the app, which ships them all in LICENSE_BUNDLE.
LICENSES = ROOT / "Licenses"
# Every license in one JSON object by token, raw-deflated, which NSData decompresses as .zlib: 0.8 MB
# against 12.5 MB of text in 2,000-odd files, most of them the same OFL.
LICENSE_BUNDLE = APP / "Licenses.deflate"
APPLE_PREVIEWS = APP / "ApplePreviews"
LOCK = ROOT / "fonts.lock.json"
# Descriptions drafted from READMEs and homepages by scripts/descriptions.py and reviewed by hand, for
# casks with none from google/fonts.
DRAFTED_DESCRIPTIONS = ROOT / "scripts" / "descriptions.json"
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


def is_excluded(token, url):
    """Whether a cask is in EXCLUDED, or downloads from one of EXCLUDED_HOSTS or a subdomain of one."""
    host = urllib.parse.urlparse(url or "").hostname or ""
    return token in EXCLUDED or any(host == name or host.endswith("." + name) for name in EXCLUDED_HOSTS)


def is_retired(cask):
    """Whether Homebrew has disabled the cask, for any reason, or deprecated it as discontinued: its font
    is finished, and a download that still works is living on borrowed time (OpenDyslexic's host went
    down months before Homebrew disabled it)."""
    return bool(cask.get("disabled")) or (cask.get("deprecated") and cask.get("deprecation_reason") == "discontinued")


def successor(token, casks_by_token):
    """The cask standing in for `token`: itself, or for a retired cask the one Homebrew names to replace
    it, followed until one isn't retired. None for a retired cask with no replacement."""
    seen = set()
    while (cask := casks_by_token.get(token)) and is_retired(cask):
        if token in seen:
            return None
        seen.add(token)
        token = cask.get("disable_replacement_cask") or cask.get("deprecation_replacement_cask")
    return token if cask else None


def rank_casks(analytics, casks_by_token):
    """Returns every eligible font cask with its install count, most-installed first, then by token: Homebrew
    lists equal counts in no particular order. A retired cask's installs count for its replacement, whose
    users they mostly are now."""
    counts = {}
    for item in analytics["items"]:
        counts.setdefault(item["cask"], int(item["count"].replace(",", "")))
    installs = {}
    for token, count in counts.items():
        heir = successor(token, casks_by_token)
        eligible = heir and heir.startswith("font-") and not is_excluded(heir, casks_by_token[heir]["url"])
        if token.startswith("font-") and eligible:
            installs[heir] = installs.get(heir, 0) + count
    return [(casks_by_token[token], installs[token]) for token in sorted(installs, key=lambda t: (-installs[t], t))]


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
            or by_directory.get(simplified(name))
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


def google_directories(entries):
    """The google/fonts directories these casks build from: their fonts, licences and descriptions."""
    directories = {entry["source"]["google"] for entry in entries if "google" in entry["source"]}
    directories |= {entry["google"]["directory"] for entry in entries if (entry.get("google") or {}).get("directory")}
    return directories | {
        DESCRIPTION_DIRECTORIES[entry["token"]] for entry in entries if entry["token"] in DESCRIPTION_DIRECTORIES
    }


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


def google_seasons(commit):
    """Each family's seasonal tags in google/fonts at `commit`, by holiday, with their scores. Rows
    naming a location on the family's axes score one instance, which a holiday never does."""
    seasons = {}
    for family, location, tag, score in csv.reader(git("show", f"{commit}:{GOOGLE_TAGS}").splitlines()):
        if tag.startswith(GOOGLE_SEASONAL_TAG) and not location:
            seasons.setdefault(family, {})[tag.removeprefix(GOOGLE_SEASONAL_TAG)] = round(float(score or 0))
    return seasons


def simplified(name):
    """A family name lowercased to its letters and digits, as google/fonts names its directories."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def google_directory_of(family, cask, family_directories):
    only_path = (cask.get("url_specs") or {}).get("only_path", "") if cask else ""
    return only_path or family_directories.get(simplified(family["family"]))


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
    for cask in EXTRA_CASKS:
        if cask["token"] in casks_by_token and not is_retired(casks_by_token[cask["token"]]):
            print(f"{cask['token']}: Homebrew has a working cask now; take it out of EXTRA_CASKS")
        else:
            casks_by_token[cask["token"]] = cask
    ranked = rank_casks(fetch_json(ANALYTICS_URL), casks_by_token)
    families = google_families(casks_by_token)
    commit = update_clone()
    trees = google_trees(commit)
    seasons = google_seasons(commit)
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
        required = [token for _, token in top if token]
    else:
        required = []
    required = [
        heir
        for token in required + ALWAYS_INCLUDED
        if (heir := successor(token, casks_by_token)) and not is_excluded(heir, casks_by_token[heir]["url"])
    ]
    report(
        "retired by Homebrew, so out of the line-up (→ its replacement)",
        [
            f"{token} → {heir}" if (heir := successor(token, casks_by_token)) else token
            for token, cask in sorted(casks_by_token.items())
            if token.startswith("font-") and is_retired(cask)
        ],
    )
    # Homebrew's analytics leave out casks nobody installed in a year; required ones go on the end.
    installs = {cask["token"]: count for cask, count in ranked}
    recent = {item["cask"]: int(item["count"].replace(",", "")) for item in fetch_json(RECENT_ANALYTICS_URL)["items"]}
    # Casks tied with the last of the top `count` come too: which side of the cut a tie fell on was
    # arbitrary, so a cask whose installs hadn't moved could drop out when others climbed past it.
    if 0 < count < len(ranked):
        last = ranked[count - 1][1]
        while count < len(ranked) and ranked[count][1] == last:
            count += 1
    # Google files barcodes, Linefont's and Wavefont's charts, Unicode's music and other symbols and the
    # like under Symbols: nothing to set text in, and on iOS no way to type most of them. The Symbols
    # collection's casks (SYMBOL_CASKS) are the exceptions.
    symbols = {
        token
        for token, family in google_by_token.items()
        if "Symbols" in family.get("classifications", []) and token not in SYMBOL_CASKS
    }
    tokens = [
        token
        for token in dict.fromkeys([cask["token"] for cask, _ in ranked[:count]] + required)
        if token not in symbols
    ]
    report("classified Symbols by Google, so out of the line-up", sorted(symbols & (installs.keys() | set(required))))
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
        homepage = cask["homepage"]
        # Google takes down the specimen page of a family it delists or renames, as it did 42dot Sans,
        # though its files stay in google/fonts; Homebrew's cask still points at the page.
        if not family and GOOGLE_SPECIMEN.search(homepage) and "google" in source:
            homepage = f"https://github.com/google/fonts/tree/main/{source['google']}"
        entry = {
            "token": token,
            "name": cask["name"][0],
            "homepage": homepage,
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
            if tags := seasons.get(family["family"]):
                google["seasons"] = dict(sorted(tags.items()))
            entry["google"] = google
        entries.append(entry)
    if unpinned:
        print(f"warning: {len(unpinned)} casks have a source that can't be pinned: {', '.join(unpinned)}")
    # A cask in the previous lock is never unpinned (it keeps its pin), so anything gone left the line-up.
    locked = {entry["token"] for entry in entries}
    cutoff = ranked[count - 1][1] if 0 < count <= len(ranked) else None
    left = {
        token: departure(token, casks_by_token, installs, cutoff, symbols) for token in sorted(previous.keys() - locked)
    }
    report("kept at their locked version: the new download can't be had or doesn't match its hash", held)
    date_entries(entries, previous, google_by_token)
    # The rank is the line-up's order, which build keeps when two casks carry the same face. The file is
    # in token order, so a week's new install counts change a line in each entry rather than moving most
    # of them, which made a fonts pull request's diff of the lock tens of thousands of lines.
    for rank, entry in enumerate(entries, 1):
        entry["rank"] = rank
    entries.sort(key=lambda entry: entry["token"])

    write_json(
        LOCK,
        {
            "generated": date.today().isoformat(),
            "googleFonts": commit,
            # Every family's category, for Apple's fonts that Google also publishes.
            "googleCategories": {family["family"]: family["category"] for family, _ in families},
            "casks": entries,
            # Why each cask in the previous lock isn't in this one, for the fonts pull request to say.
            "left": left,
        },
    )
    print(f"locked {len(entries)} casks at google/fonts {commit[:12]}")


def source_date(source, family):
    """When a source's files were published, as an ISO date, or None when it doesn't say.

    Google's metadata dates each family's last change; GitHub dates a release, a tag and a commit; any
    other host gets its download's Last-Modified header, which some send. A release's date is the whole
    release's, so a repository that ships several families dates them all when it changes one.
    """
    try:
        if "google" in source:
            return (family or {}).get("lastModified")
        if "git" in source:
            if match := GITHUB_REPOSITORY.match(source["git"]):
                owner, repo = match.groups()
                commit = fetch_json(
                    f"https://api.github.com/repos/{owner}/{repo}/commits/{source['commit']}", github_headers()
                )
                return commit["commit"]["committer"]["date"][:10]
            return None
        url = source["url"]
        if match := GITHUB_RELEASE_FILE.match(url) or GITHUB_TAG_ARCHIVE.match(url):
            owner, repo, tag = match.groups()
            tag = urllib.parse.quote(urllib.parse.unquote(tag), safe="")
            try:
                release = fetch_json(
                    f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}", github_headers()
                )
                return release["published_at"][:10]
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
            # A tag with no release: the date of the commit it names.
            commit = fetch_json(f"https://api.github.com/repos/{owner}/{repo}/commits/{tag}", github_headers())
            return commit["commit"]["committer"]["date"][:10]
        if match := GITHUB_BRANCH_ARCHIVE.match(url) or GITHUB_BRANCH_FILE.match(url):
            owner, repo, branch, *path = match.groups()
            query = urllib.parse.urlencode(
                {"sha": urllib.parse.unquote(branch), "per_page": 1}
                | ({"path": urllib.parse.unquote(path[0])} if path else {})
            )
            commits = fetch_json(f"https://api.github.com/repos/{owner}/{repo}/commits?{query}", github_headers())
            return commits[0]["commit"]["committer"]["date"][:10] if commits else None
        headers = {"User-Agent": USER_AGENT}
        if source.get("referer"):
            headers["Referer"] = source["referer"]
        request = urllib.request.Request(url, headers=headers, method="HEAD")
        with urllib.request.urlopen(request, timeout=30) as response:
            modified = response.headers.get("Last-Modified")
        return parsedate_to_datetime(modified).date().isoformat() if modified else None
    except (urllib.error.URLError, OSError, KeyError, IndexError, TypeError, ValueError) as error:
        print(f"no date for {source.get('url') or source.get('git') or source.get('google')}: {error}")
        return None


def date_entries(entries, previous, google_by_token):
    """Gives each entry an `updated` date: its source's, kept from the previous lock while the source is
    unchanged, so dates are looked up only for what moved.

    A source that doesn't say is null, unless a lock that dated it saw the source change: then the change
    is this lock's, and today's date says so. Dating every such cask today the first time would list the
    lot as just updated.
    """
    today = date.today().isoformat()
    stale = [
        entry
        for entry in entries
        if not ((kept := previous.get(entry["token"])) and "updated" in kept and kept["source"] == entry["source"])
    ]
    with ThreadPoolExecutor(8) as pool:
        dates = list(pool.map(lambda entry: source_date(entry["source"], google_by_token.get(entry["token"])), stale))
    found = {entry["token"]: day for entry, day in zip(stale, dates)}
    for entry in entries:
        kept = previous.get(entry["token"]) or {}
        if entry["token"] not in found:
            entry["updated"] = kept["updated"]
        elif day := found[entry["token"]]:
            # Never later than today: a server's clock, or a date it makes up, can run ahead.
            entry["updated"] = min(day, today)
        else:
            entry["updated"] = today if "updated" in kept else None
    print(f"dated {len(stale)} casks whose source changed; {dates.count(None)} don't say when")


def departure(token, casks_by_token, installs, cutoff, symbols):
    """Why a cask that was in the line-up isn't any more, in a few words for the fonts pull request."""
    if not (cask := casks_by_token.get(token)):
        return "Homebrew removed its cask"
    if is_retired(cask):
        if cask.get("disabled"):
            because = cask.get("disable_reason")
            reason = f"Homebrew disabled it: {because.replace('_', ' ')}" if because else "Homebrew disabled it"
        else:
            reason = "Homebrew discontinued it"
        heir = successor(token, casks_by_token)
        return f"{reason}; `{heir}` replaces it" if heir else reason
    if token in symbols:
        return "Google classifies it as a symbols font, not text"
    if token in EXCLUDED:
        return "excluded by hand (see `EXCLUDED`)"
    if is_excluded(token, cask["url"]):
        return f"downloads from {urllib.parse.urlparse(cask['url']).hostname}, which is excluded"
    if token not in installs:
        return "no Homebrew installs in the last year"
    if cutoff is not None and installs[token] < cutoff:
        return f"{installs[token]} installs in the last year, below the line-up's {cutoff}"
    return "no longer in the line-up"


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
        mono = "mono" in family.lower()  # FreeMono and JetBrainsMonoNL too
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
        # A symbol font, like Wingdings, maps its glyphs only in a 3.0 symbol cmap, at U+F020-F0FF,
        # where Core Text looks up the sample's ASCII. The subsetter neither keeps that cmap by default
        # nor reads it for the text, which left these previews no cmap at all: drawn in the system font,
        # and rejected by the App Store's font validation.
        symbol = None if font.getBestCmap() else next((t for t in font["cmap"].tables if t.isSymbol()), None)
        options.symbol_cmap = symbol is not None
        symbol_glyphs = (
            sorted({symbol.cmap[code] for character in text if (code := 0xF000 + ord(character)) in symbol.cmap})
            if symbol
            else []
        )
        subsetter = Subsetter(options)
        subsetter.populate(text=text + (GLYPH_SAMPLE if glyphs else ""), glyphs=symbol_glyphs)
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


@dataclass(frozen=True)
class Scripts:
    """What scripts a face is for and covers, as ISO 15924 codes, and the sample it's previewed with."""

    script: str | None  # its own: Latn for a Latin face, None for one that draws no script
    scripts: list[str]  # every one it covers, for filtering by
    sample: str | None  # None for an icon, emoji or music font, which has nothing to preview


def has_coding_ligatures(face):
    """Whether shaping enough of CODING_LIGATURES draws them differently with the ligature features on,
    by HarfBuzz rather than by reading GSUB: Fira Code and most coding faces build theirs from calt's
    contextual alternates, which swap glyphs one for one rather than combining them, so only shaping both
    ways tells."""
    font = uharfbuzz.Font(uharfbuzz.Face(uharfbuzz.Blob.from_file_path(str(face.path)), face.number))
    off = {"liga": False, "calt": False, "clig": False}

    def glyphs(text, features):
        buffer = uharfbuzz.Buffer()
        buffer.add_str(text)
        buffer.guess_segment_properties()
        uharfbuzz.shape(font, buffer, features)
        return [info.codepoint for info in buffer.glyph_infos]

    changed = sum(glyphs(text, {}) != glyphs(text, off) for text in CODING_LIGATURES)
    return changed >= CODING_LIGATURES_MIN


def face_scripts(face, primary_script=None):
    """The face's own script, every script it covers, and its sample: the line in its own script,
    then SAMPLE_TEXT on the next where it has Latin letters too, or SAMPLE_TEXT alone for a Latin face.

    A face's own script is the one google/fonts gives as the family's primary script, else what
    own_script() reads from the face. Most faces for other scripts carry Latin letters too, so having
    them doesn't make a face Latin, and Google calls Poppins and Teko Devanagari faces, though most
    use them for Latin: showing both covers either reading.
    """
    with TTFont(face.path, fontNumber=face.number, lazy=True) as font:
        cmap = font.getBestCmap() or {}
        os2 = font.get("OS/2")
        code_pages = getattr(os2, "ulCodePageRange1", 0) if os2 is not None else 0
    covered = [
        script
        for script, sample in SCRIPT_SAMPLES.items()
        if all(ord(character) in cmap for character in sample if not character.isspace())
    ]
    letters = {ord(character) for character in PANGRAM if not character.isspace()}
    latin = len(letters & cmap.keys()) >= LATIN_COVERAGE * len(letters)
    european = [
        script
        for script, (low, high) in EUROPEAN_ALPHABETS.items()
        if all(code in cmap for code in range(low, high + 1))
    ]
    scripts = (["Latn"] if latin else []) + european + covered
    primary_script = SCRIPT_ALIASES.get(primary_script, primary_script)
    if primary_script in ("Latn", "Grek", "Cyrl") and latin:
        script = None
    elif primary_script in covered:
        script = primary_script
    else:
        script = own_script(face.family, cmap, code_pages, covered, latin)
    if script is not None:
        sample = SCRIPT_SAMPLES[script] + ("\n" + SAMPLE_TEXT if latin else "")
    else:
        sample = SAMPLE_TEXT if latin else None
    # Google's word for the family's script stands, even for one with no sample here, like Tifinagh.
    own = primary_script or script or ("Latn" if latin else None)
    if own and own not in scripts:
        scripts.append(own)
    return Scripts(own if sample else None, scripts if sample else [], sample)


def filtered_scripts(script, scripts, token=None):
    """The scripts the filter lists a face under, of those it covers: Latin, Greek and Cyrillic only
    where `script`, its own, is Latin or that one, or it's one of LATIN_TOO. Applied when assembling
    the catalog, not in the cached build, so changing it needs no rebuild."""
    if token in LATIN_TOO:
        return scripts
    own = script or "Latn"
    return [code for code in scripts if code not in ("Latn", *EUROPEAN_ALPHABETS) or own in ("Latn", code)]


def own_script(family, cmap, code_pages, covered, latin):
    """The script of `covered` a face is for, or None for a Latin face.

    A face is for a script its family's name gives, of those it covers. Otherwise a face with no
    Latin is for the first it covers, and one with Latin is for a CJK script when it has
    the thousands of characters one needs, or the kana alone of a kana display face, since Japanese
    fonts carry Greek and Cyrillic, and Hebrew sometimes. Otherwise it's for another script when it
    covers just that one and isn't a face for the scripts of Europe: one with Greek and Cyrillic, or
    either, beside Hebrew, Arabic, Armenian or Georgian. Tahoma and Open Sans are Latin faces, and Thonburi, with Cyrillic, a Thai one. Braille counts only where there's
    nothing else: Nerd Fonts and Maple Mono draw its patterns for terminals.
    """
    counts = Counter()
    for code in cmap:
        for name, (low, high) in SCRIPT_RANGES.items():
            if low <= code <= high:
                counts[name] += 1
    cjk = [script for script in covered if script in CJK_SCRIPTS]
    others = [script for script in covered if script not in CJK_SCRIPTS and script != "Brai"]
    if named := [script for script in others if re.search(rf"\b(?:{SCRIPT_NAMES[script]})\b", family)]:
        return named[0]
    counts["japanese kanji"] = all(ord(character) in cmap for character in JAPANESE_KANJI)
    if not latin:
        if cjk:
            return cjk_script(family, code_pages, counts, cjk)
        return covered[0] if covered else None
    ideographs = counts["han"] + counts["hangul"]
    if cjk and len(others) < 6 and (ideographs >= 2000 or (counts["kana"] >= 80 and ideographs < 20)):
        return cjk_script(family, code_pages, counts, cjk)
    if not cjk and len(others) == 1:
        europe = [counts["greek"] >= 20, counts["cyrillic"] >= 20]
        if not (any(europe) if others[0] in BESIDE_EUROPE else all(europe)):
            return others[0]
    return None


def cjk_script(family, code_pages, counts, covered):
    """Which of the CJK scripts in `covered` a CJK face is for: the region its family name gives, else
    the one its OS/2 code pages name alone, else Korean for one with hangul and only Korean's few
    thousand hanja, Japanese for one with kana and Japan's own kanji, Korean for one with hangul, and
    Chinese. Korean and Chinese character sets carry the kana too."""
    regions = [script for script, codes in CJK_REGIONS.items() if re.search(rf"(?:\b|(?<=[a-z]))(?:{codes})\b", family)]
    # Code pages 932 (JIS), 936 (simplified Chinese), 949 and 1361 (Korean) and 950 (traditional).
    pages = {
        script
        for script, bits in (("Jpan", 1 << 17), ("Hans", 1 << 18 | 1 << 20), ("Kore", 1 << 19 | 1 << 21))
        if code_pages & bits
    }
    if regions:
        wanted = regions[0]
    elif len(pages) == 1:
        (wanted,) = pages
        if wanted == "Hans" and not code_pages & 1 << 18:
            wanted = "Hant"
    elif counts["hangul"] >= 2000 and counts["han"] < 10000:
        wanted = "Kore"
    elif counts["kana"] >= 80 and counts["japanese kanji"]:
        wanted = "Jpan"
    elif counts["hangul"] >= 2000:
        wanted = "Kore"
    else:
        wanted = "Hans"
    order = [wanted, *(("Hant", "Hans") if wanted in ("Hans", "Hant") else ()), *CJK_SCRIPTS]
    return next(script for script in order if script in covered)


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
    for suffixes in (LICENSE_SUFFIXES, FALLBACK_LICENSE_SUFFIXES):
        paths = sorted(
            path
            for path in root.rglob("*")
            if path.suffix.lower() in suffixes
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


def google_primary_script(directory):
    """The script google/fonts says the family is for, as an ISO 15924 code, where it says: about a
    third of families do, though Badeen Display, an Arabic face, doesn't."""
    if not directory or not (metadata := CLONE / directory / "METADATA.pb").is_file():
        return None
    match = re.search(r'^primary_script: "(\w+)"', metadata.read_text(), re.MULTILINE)
    return match.group(1) if match else None


def google_description(directory):
    """The family's description, or its article where the description file is empty: Onest, Jaro and a
    few others ship a 0-byte DESCRIPTION.en_us.html beside a full article."""
    for name in GOOGLE_DESCRIPTIONS:
        if (path := CLONE / directory / name).is_file() and (description := describe(path.read_text(errors="replace"))):
            return description
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
    # Only where there is one, so adding one rebuilds that cask alone.
    if left_out := LEFT_OUT_FILES.get(entry["token"]):
        material["leftOut"] = left_out
    if description_directory := DESCRIPTION_DIRECTORIES.get(entry["token"]):
        material["descriptionDirectory"] = description_directory
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
        left_out = tuple(LEFT_OUT_FILES.get(token, ()))
        paths = [
            root / artifact
            for artifact in dict.fromkeys(entry["artifacts"])
            if Path(artifact).suffix.lower() in FONT_SUFFIXES
            and (root / artifact).is_file()
            and not Path(artifact).name.startswith(left_out)
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
        scripts = face_scripts(primary, google_primary_script(google.get("directory")))
        if (sample := scripts.sample) is None:
            # Icon, emoji and music fonts draw none of the samples: a card would show the system font.
            raise Skip("draws none of the sample text")
        # A Latin face with coding ligatures shows them in place of the sample's brackets.
        ligatures = has_coding_ligatures(primary)
        if ligatures and sample == SAMPLE_TEXT:
            sample = LIGATURE_SAMPLE_TEXT
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
        built |= {"script": scripts.script, "scripts": scripts.scripts}
        if ligatures:
            built["ligatures"] = True
        # A cask built from google/fonts but missing from Google's metadata, like Open Sans Hebrew, has no
        # google.directory, though its source names the same directory.
        directory = DESCRIPTION_DIRECTORIES.get(token) or google.get("directory") or entry["source"].get("google")
        if directory and (description := google_description(directory)):
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


def write_dataset(path, asset, token, catalog=FONTS):
    group = catalog / token
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
        family["scripts"] = filtered_scripts(family.get("script"), family["scripts"])
        kept.append(family)
    write_json(path, kept)
    print(f"{len(kept)} Apple font families")


def pair_nerd_fonts(catalog):
    """Marks each plain cask that has a Nerd Font version with that cask's token, as `nerdFont`, so the app
    shows the two as one card with a choice of which to install.

    A Nerd Font cask is one with `glyphs`. Nerd Fonts names its casks after the original in parentheses,
    "CaskaydiaCove Nerd Font (Cascadia Code)", which finds renamed ones; otherwise the token without its
    Nerd suffix does, as for Maple Mono's `-nf` casks. NERD_FONT_PAIRS settles the rest by hand. A
    plain cask with two candidates gets neither, with a warning, rather than a guess.
    """
    plain_by_name, plain_tokens = {}, set()
    for record in catalog:
        if not record["glyphs"]:
            plain_by_name.setdefault(fold_name(record["name"]), record["token"])
            plain_tokens.add(record["token"])
    candidates = {}
    for record in sorted(catalog, key=lambda record: record["token"]):
        token = record["token"]
        if not record["glyphs"]:
            continue
        if token in NERD_FONT_PAIRS:
            plain = NERD_FONT_PAIRS[token]
        elif (original := re.search(r"\(([^)]+)\)\s*$", record["name"])) and (fold_name(original[1]) in plain_by_name):
            plain = plain_by_name[fold_name(original[1])]
        else:
            plain = re.sub(r"-nerd-font$|-nf(?=-|$)", "", token)
        if plain and plain != token and plain in plain_tokens:
            candidates.setdefault(plain, []).append(token)
    records = {record["token"]: record for record in catalog}
    for plain, nerd in sorted(candidates.items()):
        if len(nerd) == 1:
            records[plain]["nerdFont"] = nerd[0]
        else:
            print(f"warning: {plain} has several Nerd Font versions, {', '.join(nerd)}; set NERD_FONT_PAIRS")
    if missing := sorted(token for pair in NERD_FONT_PAIRS.items() for token in pair if token and token not in records):
        print(f"warning: NERD_FONT_PAIRS names casks not in the catalog: {', '.join(missing)}")


NERD_FONTS_DESCRIPTION = (
    "{original} with Nerd Fonts' icons added, for prompts, status lines, and file trees in a terminal: "
    "thousands of glyphs from Font Awesome, Material Design, Devicons, Octicons, and other sets, along with "
    "the Powerline symbols."
)
POWERLINE_DESCRIPTION = (
    "{original} with the Powerline symbols added: the arrows and branch glyphs that shell prompts and editor "
    "status lines draw with."
)


@functools.cache
def drafted_descriptions():
    return json.loads(DRAFTED_DESCRIPTIONS.read_text()) if DRAFTED_DESCRIPTIONS.is_file() else {}


def describe_patched(catalog):
    """Describes each Nerd Font or Powerline cask that has no description of its own as its original with
    the icons added, followed by the original's description where the catalog has one. Runs after every
    other description is in place, so an original described later carries over to its variants.

    The original is the plain cask pair_nerd_fonts() paired it with, or else the family the cask's name
    gives, in parentheses as Nerd Fonts writes it or with "NF", "Nerd Font" or "for Powerline" taken out.
    """
    records = {record["token"]: record for record in catalog}
    plain_of = {record["nerdFont"]: record["token"] for record in catalog if record.get("nerdFont")}
    by_name = {fold_name(record["name"]): record for record in catalog if not record["glyphs"]}
    for record in catalog:
        token = record["token"]
        powerline = "powerline" in token or token in ("font-cascadia-code-pl", "font-cascadia-mono-pl")
        # Not every cask with icons is a patch: Cica and Cozette draw their own, beside the letters.
        nerd = re.search(r"nerd|-nf(-|$)", token)
        if record.get("description") or not (nerd or powerline):
            continue
        if token in PATCHED_ORIGINALS:
            original = PATCHED_ORIGINALS[token]
        elif original := re.search(r"\(([^)]+)\)\s*$", record["name"]):
            original = original[1]
        else:
            original = re.sub(r"\s+(Nerd Font( families)?|NF|PL|for Powerline|Powerline)\b", "", record["name"])
        plain = records.get(plain_of.get(token)) or by_name.get(fold_name(original))
        template = POWERLINE_DESCRIPTION if powerline else NERD_FONTS_DESCRIPTION
        description = template.format(original=original)
        if plain and plain is not record and plain.get("description"):
            description += "\n\n" + plain["description"]
            if designers := plain.get("designers"):
                record["designers"] = designers
        record["description"] = description


def fold_name(name):
    """A family name without case, spaces or punctuation, so "Meslo LG" matches "MesloLG"."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


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


def extra_entry(cask):
    """A lock entry for a cask in EXTRA_CASKS, as `lock` would pin it, for `try` before `lock` has run."""
    return {
        "token": cask["token"],
        "name": cask["name"][0],
        "homepage": cask["homepage"],
        "version": cask["version"],
        "installs": 0,
        "recentInstalls": 0,
        "exempt": True,
        "artifacts": [artifact["font"][0] for artifact in cask["artifacts"] if "font" in artifact],
        "source": {"url": cask["url"], "sha256": cask["sha256"]},
    }


def try_casks(tokens, apply=False):
    """`try`: builds just these casks from fonts.lock.json into .cache/try/, to see what a pipeline change
    makes of them without the hours a full build takes, and prints what each built into.

    A cask in EXTRA_CASKS that the lock doesn't have yet is built from that entry, so one can be tried
    before `lock` runs.

    With `apply`, also copies their previews into Typecask/Previews and their built fields into
    Catalog.json, for a look in the simulator. A cask the catalog doesn't have is added, with its license,
    and its fonts go into DebugFonts.xcassets, so run scripts/debug-fonts.py first: it replaces that
    catalog. That leaves the app's generated files half from this build and half from the last, so it's
    for a local check only: restore them with git afterwards.
    """
    locked = json.loads(LOCK.read_text())
    by_token = {entry["token"]: entry for entry in locked["casks"]}
    for cask in EXTRA_CASKS:
        by_token.setdefault(cask["token"], extra_entry(cask))
    if unknown := [token for token in tokens if token not in by_token]:
        sys.exit(f"not in {LOCK.name} or EXTRA_CASKS: {', '.join(unknown)}")
    entries = [by_token[token] for token in tokens]
    update_clone(locked["googleFonts"])
    checkout(locked["googleFonts"], google_directories(entries))
    mirrored = frozenset(mirrored_hashes()) if any(mirrorable(entry["source"]) for entry in entries) else frozenset()
    built = {}
    for entry in entries:
        destination = CACHE / "try" / entry["token"]
        _, error = build_job((entry, destination, mirrored))
        result = {"error": error} if error else json.loads((destination / "entry.json").read_text())
        built[entry["token"]] = result
        summary = {key: result[key] for key in ("skip", "error", "ligatures", "sample", "glyphs") if key in result}
        print(f"{entry['token']}: {json.dumps(summary, ensure_ascii=False)}")
    if not apply:
        return
    catalog = json.loads(CATALOG.read_text())
    known = {record["token"] for record in catalog["casks"]}
    licenses = None
    for entry in entries:
        token, result = entry["token"], built[entry["token"]]
        if token in known or "previewFile" not in result:
            continue
        destination = CACHE / "try" / token
        shipping = [file for file in result["files"] if file["shippable"]]
        for file in shipping:
            write_dataset(destination / "fonts" / file["file"], file["asset"], token, DEBUG_FONTS)
        licenses = licenses or json.loads(zlib.decompress(LICENSE_BUNDLE.read_bytes(), -15))
        licenses[token] = (destination / "license.txt").read_text()
        shutil.copy(destination / "license.txt", LICENSES / f"{token}.txt")
        catalog["casks"].append(
            {
                "token": token,
                "name": entry["name"],
                "homepage": entry["homepage"],
                "installs": entry["installs"],
                "bytes": sum(file["bytes"] for file in result["files"]),
                "fonts": len(result["files"]),
                "assets": [file["asset"] for file in shipping],
                "primaryFont": result["primaryFont"],
                "style": result["style"],
                "previewFile": result["previewFile"],
                "glyphs": result["glyphs"],
                "version": cask_version(entry["version"], result["fontVersion"]),
                "fontVersion": result["fontVersion"],
                "script": result["script"],
                "scripts": filtered_scripts(result["script"], result["scripts"], token),
            }
        )
        print(f"{token}: added to {CATALOG.name}, with its fonts in {DEBUG_FONTS.name}")
    catalog["casks"].sort(key=lambda record: record["token"])
    if licenses is not None:
        write_license_bundle(licenses)
    for record in catalog["casks"]:
        result = built.get(record["token"])
        if not result or "previewFile" not in result:
            continue
        shutil.copy(CACHE / "try" / record["token"] / result["previewFile"], PREVIEWS / result["previewFile"])
        for key in ("previewFile", "fontVersion", "glyphs", "style"):
            record[key] = result[key]
        for key in ("sample", "ligatures"):
            if key in result:
                record[key] = result[key]
            else:
                record.pop(key, None)
    write_json(CATALOG, catalog)
    print(f"applied to {CATALOG.name} and {PREVIEWS.name}/ for a local look; restore them with git afterwards")


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
    # `lock` leaves out EXCLUDED casks, but a lock written before a cask was excluded still names it,
    # and a run that doesn't lock again builds from that lock: Input shipped a release after it was
    # excluded that way. So a cask stops shipping at the next build, whichever lock it uses.
    excluded = {
        entry["token"]: "excluded in build-catalog.py"
        for entry in locked["casks"]
        if is_excluded(entry["token"], entry["source"].get("url"))
    }
    # In the line-up's order, which `lock` records as each entry's rank; a lock from before it had ranks
    # is in that order already, and a stable sort keeps it.
    entries = sorted(
        (entry for entry in locked["casks"] if entry["token"] not in excluded),
        key=lambda entry: entry.get("rank", 0),
    )
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
        checkout(locked["googleFonts"], google_directories(pending))
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
    skipped, trimmed, unshippable, shadowed = dict(excluded), {}, {}, {}
    # (Nerd Font cask, face) → the plain sibling that built that face too, which keeps it.
    plain_owners = {}
    for entry in entries:
        plain = entry["token"].removesuffix("-nerd-font")
        if plain != entry["token"] and plain in destinations and (destinations[plain] / "entry.json").is_file():
            built = json.loads((destinations[plain] / "entry.json").read_text())
            for file in built.get("files", []):
                plain_owners[entry["token"], file["asset"]] = plain
    # A family Apple offers too is listed as Apple's alone, which needs no download from the app and
    # can't collide with Apple's copy once Settings installs it.
    apple = json.loads((APP / "AppleFonts.json").read_text()) if (APP / "AppleFonts.json").is_file() else []
    apple_names = {simplified(family["name"]): family["name"] for family in apple}
    apple_faces = {family["previewFace"]: family["name"] for family in apple}
    for entry in entries:
        token, destination = entry["token"], destinations[entry["token"]]
        if not (destination / "entry.json").is_file():
            continue
        built = json.loads((destination / "entry.json").read_text())
        if "skip" in built:
            skipped[token] = built["skip"]
            continue
        # By name, Homebrew's or Google's, or by a face: font-stix installs STIX Two Text under another.
        names = (entry["name"], (entry.get("google") or {}).get("family"))
        matches = [apple_names.get(simplified(name)) for name in names if name]
        matches += [apple_faces.get(file["asset"]) for file in built["files"]]
        if apple_family := next(filter(None, matches), None):
            skipped[token] = f"one of Apple's fonts, {apple_family}"
            continue
        # Two casks can carry the same face; the higher-ranked one keeps it, except that a Nerd Font cask
        # yields its plain sibling's faces to it: Monocraft's patched collection reuses the plain one's
        # names, and the plain font is the one to offer.
        claimed = {
            file["asset"]: owner
            for file in built["files"]
            if (owner := owners.get(file["asset"]) or plain_owners.get((token, file["asset"])))
        }
        files, faces = [], set()
        for file in built["files"]:
            if file["asset"] in claimed:
                print(f"{token}: {file['asset']!r} already comes from {claimed[file['asset']]}")
            # A cask shipping the same face twice, as TTF and OTF, keeps the first quietly.
            elif file["asset"] not in faces:
                faces.add(file["asset"])
                files.append(file)
        if not files:
            shadowed[token] = sorted(set(claimed.values()))
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
        style = CASK_STYLES.get(token, style)
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
        if entry.get("updated"):
            record["updated"] = entry["updated"]
        if "sample" in built:
            record["sample"] = built["sample"]
        record |= {"script": built["script"], "scripts": filtered_scripts(built["script"], built["scripts"], token)}
        if built.get("ligatures"):
            record["ligatures"] = True
        if "description" in built:
            record["description"] = built["description"]
            # Google's descriptions are often the designer's own words, in the first person.
            if designers := google.get("designers"):
                record["designers"] = designers
        elif description := drafted_descriptions().get(token, {}).get("description"):
            record["description"] = description
        seasons = google.get("seasons") or {}
        if holidays := [
            holiday
            for tag, holiday in HOLIDAYS.items()
            if seasons.get(tag, 0) >= HOLIDAY_MIN_SCORE or token in HOLIDAY_CASKS.get(holiday, [])
        ]:
            record["holidays"] = holidays
        if token in LEGIBLE_CASKS:
            record["legible"] = True
        if token in SYMBOL_CASKS:
            record["symbols"] = True
        catalog.append(record)

    rank_popularity(catalog, entries)
    pair_nerd_fonts(catalog)
    describe_patched(catalog)
    tokens = {record["token"] for record in catalog}
    if missing := sorted(token for casks in HOLIDAY_CASKS.values() for token in casks if token not in tokens):
        print(f"warning: HOLIDAY_CASKS names casks not in the catalog: {', '.join(missing)}")
    if missing := sorted(LEGIBLE_CASKS - tokens):
        print(f"warning: LEGIBLE_CASKS names casks not in the catalog: {', '.join(missing)}")
    if missing := sorted(SYMBOL_CASKS - tokens):
        print(f"warning: SYMBOL_CASKS names casks not in the catalog: {', '.join(missing)}")
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
            # By token, so a week's new rankings change a line or two in each record rather than move it;
            # nothing reads the order: the app and the site sort by name or by the records' own ranks.
            "casks": sorted(catalog, key=lambda record: record["token"]),
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
    LICENSE_BUNDLE.write_bytes(license_bundle(licenses))


def license_bundle(licenses):
    """LICENSE_BUNDLE's bytes. Sorted and compact, so the same licenses always deflate to the same bytes."""
    text = json.dumps(licenses, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    # Negative window bits make raw DEFLATE, with no zlib header, which is what Apple's .zlib reads.
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(text.encode()) + compressor.flush()


def check_licenses():
    """`check-licenses`: whether LICENSE_BUNDLE holds exactly the texts in LICENSES. build writes both
    from the same licenses, so they differ only when one was edited by hand or committed without the
    other."""
    licenses = {path.stem: path.read_text() for path in sorted(LICENSES.glob("*.txt"))}
    if LICENSE_BUNDLE.read_bytes() == license_bundle(licenses):
        print(f"{LICENSE_BUNDLE.relative_to(ROOT)} matches the {len(licenses)} licenses in Licenses/")
        return 0
    print(f"{LICENSE_BUNDLE.relative_to(ROOT)} doesn't match Licenses/: rebuild both with build-catalog.py build")
    return 1


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

    try_command = commands.add_parser("try", help="build just these casks into .cache/try/, to try a pipeline change")
    try_command.add_argument("tokens", nargs="+", metavar="TOKEN")
    try_command.add_argument(
        "--apply", action="store_true", help="copy their previews and fields into the app, for a local look only"
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
    commands.add_parser("check-licenses", help="check that Licenses.deflate matches Licenses/")
    arguments = parser.parse_args()
    if arguments.command == "lock":
        lock(arguments.count, arguments.google_top)
    elif arguments.command == "build":
        build(
            only=set(arguments.fonts) if arguments.fonts else None,
            max_mb_per_install=arguments.max_mb_per_install,
            jobs=arguments.jobs,
        )
    elif arguments.command == "try":
        try_casks(arguments.tokens, apply=arguments.apply)
    elif arguments.command == "mirror":
        mirror()
    elif arguments.command == "check-licenses":
        return check_licenses()
    else:
        apple_previews()


if __name__ == "__main__":
    sys.exit(main())
