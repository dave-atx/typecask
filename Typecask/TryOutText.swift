import CoreText
import Foundation

/// What the Try It Out editor starts with: the font's sample, then whatever it has to show off, from its own
/// character set, so a line it can't draw never appears. A coding face gets the ligatures it really joins, found
/// by shaping each candidate with its ligatures on and off; a Nerd Font gets a run of each icon set's glyphs; a
/// face for another script gets that script's letters.
nonisolated enum TryOutText {
    /// Sequences coding faces commonly join, the ones that turn up in code first.
    static let codingCandidates = [
        "->", "=>", "<-", "<=", ">=", "!=", "!==", "==", "===", "<>", "<=>", "|>", "<|", "::", ":::", ":=", "=:=",
        "=/=", "...", "..", "..<", "..=", "?.", "??", "&&", "||", "++", "--", "**", "//", "///", "/*", "*/", "<!--",
        "-->", "</", "/>", "</>", "~>", "<~", "~~", "=~", "!~", ">>", "<<", ">>=", "<<=", "<->", "<=<", ">=>",
        "|->", "<|>", "-<", ">-", "#{", "#[", "#(", "#!", ";;", "|=", "^=", "0x", "www"
    ]

    /// Words that use the ligatures text faces draw: fi, fl, ff and the rest.
    static let textCandidates = ["office", "fluffy", "affirm", "afflict", "fjord", "after", "first", "flight"]

    static let lines = [
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "abcdefghijklmnopqrstuvwxyz",
        "0123456789 ½ ¼ ¾",
        "! \" # $ % & ' ( ) * + , - . / : ; < = > ? @ [ \\ ] ^ _ ` { | } ~",
        "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØŒÙÚÛÜÝ àáâãäåæçèéêëìíîïñòóôõöøœùúûüýÿß",
        "ĄąĆćĘęŁłŃńŚśŹźŻż ČčĎďĚěŇňŘřŠšŤťŮůŽž ĞğİıŞş ĀāĒēĪīŌōŪū",
        "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ абвгдежзийклмнопрстуфхцчшщъыьэюя",
        "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ αβγδεζηθικλμνξοπρστυφχψω",
        "$ € £ ¥ ¢ ₹ ₩ ₽ ₺ ₿ § ¶ † ‡ © ® ™ ° ‰ • … – — « » ‹ › “ ” ‘ ’",
        "← ↑ → ↓ ↔ ⇐ ⇒ ⇔ ≠ ≈ ≤ ≥ ± × ÷ ∞ √ ∑ ∏ ∫ ∂ ∆ ∈ ∀ ∃ ¬ ∧ ∨"
    ]

    /// Box drawing and blocks, which only a face with all of them can draw as a joined-up grid.
    static let boxes = "┌──┬──┐ ░░▒▒▓▓██\n│  │  │ ▀▀▄▄▌▐■□\n├──┼──┤ ╔══╦══╗\n└──┴──┘ ╚══╩══╝"

    /// Nerd Fonts' icon sets, by the ranges they occupy: Powerline, Font Awesome, Devicons, Seti, Codicons,
    /// Octicons, Linux logos, weather and Material Design.
    static let iconRanges: [ClosedRange<UInt32>] = [
        0xE0A0...0xE0D7, 0xF000...0xF2E0, 0xE700...0xE8EF, 0xE5FA...0xE6B7, 0xEA60...0xEC1E, 0xF400...0xF533,
        0xF300...0xF381, 0xE300...0xE3E3, 0xF0001...0xF1AF0
    ]
    static let iconsPerSet = 24

    /// Where another script's letters are looked for: everything past Latin, Greek and Cyrillic, short of the
    /// punctuation, symbols and private use areas, which other lines cover.
    static let otherScripts: [ClosedRange<UInt32>] = [
        0x0530...0x1DFF, 0x2E80...0xDFFF, 0xF900...0xFDFF, 0x10000...0x2FFFF
    ]
    static let otherScriptCharacters = 240

    struct Result {
        let text: String
        /// Whether the face joins any of the candidates, so the editor offers to turn its ligatures off.
        let hasLigatures: Bool
    }

    static func make(font: CTFont, sample: String, glyphs: Bool) -> Result {
        let covered = CTFontCopyCharacterSet(font) as CharacterSet
        var sections = [sample]

        let coding = codingCandidates.filter { draws($0, covered) && joins($0, in: font) }
        let words = textCandidates.filter { draws($0, covered) && joins($0, in: font) }
        if !coding.isEmpty {
            sections.append(coding.joined(separator: " "))
        }
        if !words.isEmpty {
            sections.append(words.joined(separator: " "))
        }

        let drawn = lines.compactMap { kept($0, covered) }
        if !drawn.isEmpty {
            sections.append(drawn.joined(separator: "\n"))
        }
        if draws(boxes, covered) {
            sections.append(boxes)
        }
        if glyphs {
            let icons = iconRanges.map { sampled($0, covered, count: iconsPerSet) }.filter { !$0.isEmpty }
            sections.append(icons.map { $0.joined(separator: " ") }.joined(separator: "\n"))
        }
        let letters = otherScripts.flatMap { range in scalars(in: range, covered) }.prefix(otherScriptCharacters)
        if !letters.isEmpty {
            // Twenty to a line, spaced, so each shows on its own, as a joining script's isolated forms do.
            let rows = stride(from: 0, to: letters.count, by: 20).map { start in
                letters.dropFirst(start).prefix(20).map { String($0) }.joined(separator: " ")
            }
            sections.append(rows.joined(separator: "\n"))
        }
        return Result(text: sections.joined(separator: "\n\n"), hasLigatures: !coding.isEmpty || !words.isEmpty)
    }

    /// Whether the face has every character of `text` other than spaces and line breaks.
    static func draws(_ text: String, _ covered: CharacterSet) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == " " || $0 == "\n" || covered.contains($0) }
    }

    /// The line with only the characters the face has, or nil when it has under half of them: a line of
    /// Cyrillic with two letters left is noise.
    static func kept(_ line: String, _ covered: CharacterSet) -> String? {
        let words = line.split(separator: " ").map { word in
            String(String.UnicodeScalarView(word.unicodeScalars.filter(covered.contains)))
        }
        let total = line.unicodeScalars.count { $0 != " " }
        let left = words.reduce(0) { $0 + $1.unicodeScalars.count }
        guard left * 2 >= total, left > 0 else { return nil }
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Up to `count` of the characters the face has in `range`, spread evenly across them.
    static func sampled(_ range: ClosedRange<UInt32>, _ covered: CharacterSet, count: Int) -> [String] {
        let present = scalars(in: range, covered)
        guard present.count > count else { return present.map { String($0) } }
        return (0..<count).map { String(present[$0 * present.count / count]) }
    }

    static func scalars(in range: ClosedRange<UInt32>, _ covered: CharacterSet) -> [Unicode.Scalar] {
        range.compactMap(Unicode.Scalar.init).filter { covered.contains($0) && !$0.properties.isWhitespace }
    }

    /// Whether shaping `text` with the face's ligatures and contextual alternates on draws different glyphs from
    /// shaping it with them off. Comparing glyphs rather than counting them catches faces like Fira Code, whose
    /// ligatures keep a glyph per character, spacers and all.
    static func joins(_ text: String, in font: CTFont) -> Bool {
        glyphs(text, font) != glyphs(text, withoutLigatures(font))
    }

    static func withoutLigatures(_ font: CTFont) -> CTFont {
        let off = ["liga", "clig", "calt"].map { tag in
            [kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: 0] as [CFString: Any]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: off] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    private static func glyphs(_ text: String, _ font: CTFont) -> [CGGlyph] {
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        let string = NSAttributedString(string: text, attributes: [key: font])
        let line = CTLineCreateWithAttributedString(string)
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        return runs.flatMap { run in
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return glyphs
        }
    }
}
