---
title: For the terminal
summary: Coding fonts that keep every character in its column and stay clear for hours.
order: 6
---

Code gets read far more than it gets written, usually small and for hours at a time. A good coding font
keeps every character in its column, makes look-alikes like 0 and O, or 1, l, and I, easy to tell apart, and
stays comfortable through a long session. Use these in a terminal app, a code editor, or anywhere text needs
to line up.

## Nerd Fonts

Many of these have a second cask in the catalog with "[Nerd Font](term:nerd-font)" in its name. The
[Nerd Fonts](https://www.nerdfonts.com/) project patches coding fonts with thousands of extra icons from sets
like Font Awesome and Octicons, so a terminal prompt or an editor's sidebar can show a git branch, a folder,
or a Python logo in a single character. By Homebrew's install counts,
[JetBrains Mono's Nerd Font version](font:font-jetbrains-mono-nerd-font) is the most popular font in the
whole catalog. If your terminal setup asks for a [Nerd Font](collection:nerdFonts), install that version; otherwise the
plain one is all you need.

## The popular ones

@font-jetbrains-mono: git commit -m "fix typo" # attempt 47

**JetBrains Mono** comes from [JetBrains](foundry:jetbrains), the makers of IntelliJ IDEA
and PyCharm, designed by [Philipp Nurullin](designer:philipp-nurullin) and [Konstantin Bulenkov](designer:konstantin-bulenkov) for the specific needs of developers. It's
the default in JetBrains' own editors, and it has a tall [x-height](term:x-height) and plain, simple shapes
that stay clear at small sizes.

@font-fira-code: if (status != 200 && tries <= 3) => retry()

**Fira Code**, by [Nikita Prokopov](designer:nikita-prokopov), adds programming
[ligatures](term:ligature) to [Fira Mono](font:font-fira-mono) (the coding sibling of Fira Sans, from
[Workhorses](article:workhorses)). Sequences like != and => are drawn as single symbols, so your eye reads
one token instead of parsing two characters. It's only a display trick: the file still holds plain ASCII.

@font-cascadia-code: PS C:> Get-Coffee -Strength Max

**Cascadia Code** is [Microsoft's](https://github.com/microsoft/cascadia-code), made for Windows Terminal as
a replacement for Consolas and now the default in Visual Studio too. It has a lively, almost handwritten
italic and covers Greek, Cyrillic, Arabic, and Hebrew. [Cascadia Mono](font:font-cascadia-mono)
is the same font without ligatures, for anyone who wants one glyph per character.

@font-source-code-pro: <p class="todo">Finish this later</p>

**Source Code Pro** is [Paul D. Hunt](designer:paul-d-hunt)'s [monospaced](term:monospaced) version of
[Source Sans](font:font-source-sans-3) (see [Workhorses](article:workhorses)), made because people asked
[Adobe](foundry:adobe) for one. It keeps Source Sans's proportions and comes in the same full range of weights.

@font-hack: $ sudo make me a sandwich

**Hack** is built on the open-source Bitstream Vera and DejaVu Sans Mono, aiming to be a workhorse for
source code. It was made by [Chris Simpkins](designer:chris-simpkins), and it ships with the
Powerline symbols that fancy terminal prompts use.

## Newer favorites

@font-monaspace: // TODO: minimize this million-line mess

**Monaspace**, from [GitHub Next](https://monaspace.githubnext.com/), is five coding fonts that share the
same metrics, so you can mix them in one editor (comments in one, code in another) and everything still
lines up. They're named after noble gases: Neon, Argon, Xenon, Radon, and Krypton. Monaspace also pioneered
"texture healing": a wide letter like m borrows a little room from a narrow neighbor like i, so a line looks
even while every character stays in its column.

@font-geist-mono: vercel deploy --prod # it's Friday

**Geist Mono** is the coding partner to [Geist](font:font-geist), [Vercel](foundry:vercel)'s sans serif from
[Workhorses](article:workhorses). Clean, Swiss-inspired, and very at home in a terminal.

@font-commit-mono: git push --force # what could go wrong

**Commit Mono**, by [Eigil Nikolajsen](designer:eigil-nikolajsen), calls itself an "anonymous and neutral" coding font. It's built to stay
out of the way, and [its website](https://commitmono.com/) lets you pick your own alternate letters before
you download.

@font-maple-mono: ~/projects $ npm install patience

**Maple Mono** has rounded corners, a cursive italic, and a big set of smart ligatures, all aimed at
"[smoothing your coding flow](https://github.com/subframe7536/maple-font)." There's also a version with
Chinese characters.

@font-0xproto: 0O 1lI 5S 8B: no more squinting

**0xProto**, from [0xType](foundry:0xtype), focuses on legibility: look-alike characters
get clearly different shapes, the insides of letters stay open at small sizes, and its ligatures never
squash the characters they join. It borrows texture healing from Monaspace.

@font-victor-mono {face=VictorMono-Italic}: // cursive comments, because we're fancy

**Victor Mono**, by [Rune Bjørnerås](designer:rune-bjørnerås), is slender and narrow, so a lot
of code fits on a line. The fun part is its italic, a semi-connected cursive that makes comments look
handwritten.

@font-google-sans-code: def greet(): return "Hello, world!"

**Google Sans Code** is [Google's coding font](https://github.com/googlefonts/googlesans-code), drawn from
its brand fonts, with an italic inspired by early Italian italics. It's dedicated to Chris Simpkins, who
made [Hack](font:font-hack) and who helped get the project going.

@font-iosevka-charon-mono: fn main() { println!("narrow and proud"); }

**Iosevka Charon Mono** is a ready-made version of [Iosevka](https://typeof.net/Iosevka/), a famously narrow
coding font that people customize letter by letter. It fits a lot of columns into a small window, which
makes it great for splitting a screen.

## Also check out

[Intel One Mono](font:font-intel-one-mono), made with low-vision developers, is in
[Easy on the eyes](article:easy-on-the-eyes). [Monocraft](font:font-monocraft), the Minecraft coding font, is
in [Screens of the past](article:screens-of-the-past), and [Ioskeley Mono](font:font-ioskeley-mono), a free
take on Berkeley Mono, is in [Inspired by the classics](article:inspired-by-the-classics).
