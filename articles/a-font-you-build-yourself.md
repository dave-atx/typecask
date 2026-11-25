---
title: A font you build yourself
summary: Iosevka, and the fonts other people have built from it.
order: 11
---

Iosevka is unique in that it's both a font and the code that makes it. Every letter has alternates, a short config file picks
among them, and anyone can build a version of their own: a dotted or slashed zero, a different lowercase g,
wider letters, ligatures or none. A lot of people have, and some of their builds have become fonts with names of
their own.

## Iosevka

@font-iosevka: const fits = columns.filter(c => c.width <= 80)

**[Iosevka](font:font-iosevka)** is [Renzhi Li](designer:renzhi-li)'s coding font, started in 2015.
It's narrow, so more columns fit across a screen, and it comes in sans and slab versions, plus
quasi-proportional ones, Aile and Etoile, for prose. Its stylistic sets echo other coding fonts, Menlo,
Consolas, and JetBrains Mono among them.

## Italic or oblique

@font-iosevka {face=Iosevka-Italic}: a fine office of affable folk

@font-iosevka {face=Iosevka-Oblique}: a fine office of affable folk

Iosevka comes with two kinds of slanted letters, which makes it a good place to see the difference. Its
**Italic** is drawn as a different set of letters, closer to handwriting: the a loses its top storey, the f
drops below the baseline, and the i and l finish with a curl. Its **Oblique** is the upright letters, slanted.
Many sans serifs have only an oblique, even when they call it italic, while nearly every serif has a true
italic. In code, an italic sets comments or keywords apart more clearly; an oblique keeps them looking like the
rest of the line.

## Builds of their own

@font-aporetic: (load-theme 'modus-operandi t)

**[Aporetic](font:font-aporetic)** is [Protesilaos Stavrou](designer:protesilaos-stavrou)'s build, the
successor to his Iosevka Comfy. He replaced almost every letter with a rounder one, then made the italics a
little sturdier so they don't look rounder than the upright. Stavrou also wrote the Modus themes that come with
Emacs, and Aporetic is popular there.

@font-ioskeley-mono: SELECT name FROM fonts WHERE width = 'compact';

**[Ioskeley Mono](font:font-ioskeley-mono)**, by [Ahmed Hatem](designer:ahmed-hatem), tunes Iosevka toward
Berkeley Mono's compact, geometric look (there's more in [Inspired by the classics](article:inspired-by-the-classics)).
It comes in ten weights and two widths, with a Term version sized for terminal cells.

@font-iosevka-charon: Charon ferries text across the river; Charon Mono ferries code.

**[Iosevka Charon](font:font-iosevka-charon)** and **[Iosevka Charon Mono](font:font-iosevka-charon-mono)**, by
[Juliette Pluto](designer:juliette-pluto), are built to Google Fonts' rules, which put them on Google Fonts.
Charon is quasi-proportional, for technical writing and dense interfaces, and Charon Mono is for code.

@font-pragmasevka: if (rows * cols > limit) return truncate(buf);

**[Pragmasevka](font:font-pragmasevka)**, by [Oleksii Shytikov](designer:oleksii-shytikov), chases PragmataPro,
Fabrizio Schiavi's condensed coding font, which isn't free. Iosevka already has a
stylistic set modeled on PragmataPro, SS08; Shytikov started there, then raised the x-height, tightened the line
spacing, and made the bold and the punctuation heavier to get closer still.

## In an editor and a desktop

@font-zed-mono: zed --new ~/notes/todo.md

**Zed Mono** is the font of the Zed code editor, a build [Zed Industries](foundry:zed-industries) made for it,
with a quasi-proportional sibling, [Zed Sans](font:font-zed-sans).

@font-adwaita-mono: $ gsettings get org.gnome.desktop.interface monospace-font-name

**Adwaita Mono** has been [GNOME](foundry:gnome)'s monospace font since GNOME 48 in 2025, next to Adwaita Sans,
which is based on Inter.

## Build your own

Iosevka's website has a customizer that writes the config file for you, letter by letter. Building the font
takes a computer with Node.js, and a few minutes.
