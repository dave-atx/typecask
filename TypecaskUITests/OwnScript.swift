import CoreText
import Foundation

/// What scripts a face is for and covers, and the sample it's previewed with: the same rules as
/// face_scripts() and own_script() in scripts/build-catalog.py, from the same tables, so Apple's fonts
/// and the casks preview alike. Change both together.
struct OwnScript {
    /// The face's own script, as an ISO 15924 code: Latn for a Latin face, nil for one that draws none.
    let script: String?
    /// Every script the face covers, for filtering by.
    let scripts: [String]
    /// The line in the face's own script, then `latinSample` on the next where it has Latin letters
    /// too, or nil for a Latin face, which the app shows the catalog's sample text in.
    let sample: String?

    init(_ font: CTFont, family: String, latinSample: String) {
        let latin = Self.covers(font, "The quick brown fox jumps over the lazy dog")
        let characters = CTFontCopyCharacterSet(font) as CharacterSet
        let european = Self.europeanAlphabets.filter { alphabet in
            alphabet.range.allSatisfy { Unicode.Scalar($0).map { characters.contains($0) } ?? false }
        }.map(\.script)
        let covered = Self.samples.filter { Self.covers(font, $0.sample) }.map(\.script)
        scripts = (latin ? ["Latn"] : []) + european + covered
        if let own = Self.ownScript(of: font, family: family, latin: latin, covered: covered) {
            script = own
            let line = Self.samples.first { $0.script == own }!.sample
            sample = latin ? line + "\n" + latinSample : line
        } else {
            script = latin ? "Latn" : nil
            sample = nil
        }
    }

    /// What cjkScript(of:family:counts:covered:) reads from a face's characters.
    private struct Counts {
        let kana: Int
        let han: Int
        let hangul: Int
        let japaneseKanji: Bool
    }

    /// The script a face is for, or nil for a Latin face. A face is for a script its family's name
    /// gives, of those it covers. Otherwise a face with no Latin is for the first it covers, and one
    /// with Latin is for a CJK script when it has the thousands of characters one needs, or the kana
    /// alone of a kana display face, since Japanese fonts carry Greek and Cyrillic too. Otherwise it's
    /// for another script when it covers just that one and has neither Greek nor Cyrillic: Lucida
    /// Grande, with Arabic, Hebrew and Thai beside the scripts of Europe, is a Latin face. Braille
    /// counts only where there's nothing else.
    private static func ownScript(of font: CTFont, family: String, latin: Bool, covered: [String]) -> String? {
        let cjk = covered.filter(cjkScripts.contains)
        let others = covered.filter { !cjkScripts.contains($0) && $0 != "Brai" }
        if let named = others.first(where: { script in
            family.range(of: "\\b(?:\(scriptNames[script]!))\\b", options: .regularExpression) != nil
        }) {
            return named
        }
        let characters = CTFontCopyCharacterSet(font) as CharacterSet
        func count(_ range: ClosedRange<UInt32>) -> Int {
            range.count(where: { Unicode.Scalar($0).map { characters.contains($0) } ?? false })
        }
        let counts = Counts(kana: count(0x3040...0x30FF), han: count(0x4E00...0x9FFF),
                            hangul: count(0xAC00...0xD7A3), japaneseKanji: covers(font, japaneseKanji))
        let ideographs = counts.han + counts.hangul
        if !latin {
            return cjk.isEmpty ? covered.first : cjkScript(of: font, family: family, counts: counts, covered: cjk)
        }
        if !cjk.isEmpty && others.count < 6 && (ideographs >= 2000 || (counts.kana >= 80 && ideographs < 20)) {
            return cjkScript(of: font, family: family, counts: counts, covered: cjk)
        }
        if cjk.isEmpty && others.count == 1 && count(0x0391...0x03C9) < 20 && count(0x0410...0x044F) < 20 {
            return others[0]
        }
        return nil
    }

    /// Which of the CJK scripts in `covered` a CJK face is for: the region its family name gives, else
    /// the one its OS/2 code pages name alone, else Korean for one with hangul and only Korean's few
    /// thousand hanja, Japanese for one with kana and Japan's own kanji, Korean for one with hangul,
    /// and Chinese. Korean and Chinese character sets carry the kana too.
    private static func cjkScript(of font: CTFont, family: String, counts: Counts, covered: [String]) -> String {
        let regions = cjkRegions.filter { region in
            family.range(of: "(?:\\b|(?<=[a-z]))(?:\(region.codes))\\b", options: .regularExpression) != nil
        }
        // Code pages 932 (JIS), 936 (simplified Chinese), 949 and 1361 (Korean) and 950 (traditional).
        let codePages = codePageRange(font)
        let pages = [("Jpan", UInt32(1) << 17), ("Hans", 1 << 18 | 1 << 20), ("Kore", 1 << 19 | 1 << 21)]
            .filter { codePages & $0.1 != 0 }.map(\.0)
        var wanted: String
        if let region = regions.first {
            wanted = region.script
        } else if pages.count == 1 {
            wanted = pages[0] == "Hans" && codePages & 1 << 18 == 0 ? "Hant" : pages[0]
        } else if counts.hangul >= 2000 && counts.han < 10000 {
            wanted = "Kore"
        } else if counts.kana >= 80 && counts.japaneseKanji {
            wanted = "Jpan"
        } else if counts.hangul >= 2000 {
            wanted = "Kore"
        } else {
            wanted = "Hans"
        }
        let order = [wanted] + (["Hans", "Hant"].contains(wanted) ? ["Hant", "Hans"] : []) + cjkScripts
        return order.first(where: covered.contains)!
    }

    /// OS/2's ulCodePageRange1, or 0 for a font with no OS/2 table or one too old to have it.
    private static func codePageRange(_ font: CTFont) -> UInt32 {
        guard let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
              os2.count >= 82 else { return 0 }
        return os2[os2.startIndex + 78..<os2.startIndex + 82].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// Whether the font draws every character of `text` itself, skipping spaces.
    private static func covers(_ font: CTFont, _ text: String) -> Bool {
        let units = Array(text.filter { !$0.isWhitespace }.utf16)
        guard !units.isEmpty else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
    }

    private static let cjkScripts = ["Jpan", "Hans", "Hant", "Kore"]
    /// The lowercase alphabets that make a face Greek or Cyrillic too: Latin's is the pangram, and the
    /// others are `samples`.
    private static let europeanAlphabets: [(script: String, range: ClosedRange<UInt32>)] = [
        ("Grek", 0x03B1...0x03C9), ("Cyrl", 0x0430...0x044F)
    ]
    /// Kanji made in Japan, which Chinese character sets lack though they carry the kana.
    private static let japaneseKanji = "込働畑"
    /// What a family's name calls each script: October Gujarati and Kigelia Arabic carry Devanagari or
    /// the scripts of Europe as well as their own.
    private static let scriptNames = [
        "Arab": "Arabic|Urdu|Kufi|Naskh|Nastaliq", "Hebr": "Hebrew", "Deva": "Devanagari",
        "Beng": "Bangla|Bengali", "Guru": "Gurmukhi", "Gujr": "Gujarati", "Orya": "Odia|Oriya",
        "Taml": "Tamil", "Telu": "Telugu", "Knda": "Kannada", "Mlym": "Malayalam", "Sinh": "Sinhala",
        "Thai": "Thai", "Laoo": "Lao", "Khmr": "Khmer", "Mymr": "Myanmar", "Tibt": "Tibetan",
        "Geor": "Georgian", "Armn": "Armenian", "Ethi": "Ethiopic", "Cher": "Cherokee",
        "Cans": "Canadian Aboriginal|UCAS", "Mong": "Mongolian", "Syrc": "Syriac", "Mtei": "Meetei Mayek",
        "Olck": "Ol Chiki"
    ]
    /// A CJK family's region, as its name gives it: Noto Sans CJK JP and KR carry the same characters.
    private static let cjkRegions: [(script: String, codes: String)] = [
        ("Jpan", "JP"), ("Kore", "KR"), ("Hans", "SC|CN|GB"), ("Hant", "TC|HK|MO|TW")
    ]

    /// A line in each script, keyed by ISO 15924 code and tried in order for a face with no Latin.
    /// SCRIPT_SAMPLES in scripts/build-catalog.py is the same list, for casks.
    private static let samples: [(script: String, sample: String)] = [
        ("Jpan", "いろはにほへと ちりぬるを"),           // Japanese
        ("Hans", "天地玄黄 宇宙洪荒"),                   // Chinese, simplified
        ("Hant", "天地玄黃 宇宙洪荒"),                   // Chinese, traditional
        ("Kore", "다람쥐 헌 쳇바퀴에 타고파"),             // Korean
        ("Arab", "أبجد هوز حطي كلمن"),                   // Arabic
        ("Hebr", "דג סקרן שט בים מאוכזב"),               // Hebrew
        ("Deva", "नमस्ते दुनिया"),                         // Devanagari
        ("Beng", "বাংলা লিপি"),                           // Bengali
        ("Guru", "ਗੁਰਮੁਖੀ ਲਿਪੀ"),                           // Gurmukhi
        ("Gujr", "ગુજરાતી લિપિ"),                          // Gujarati
        ("Orya", "ଓଡ଼ିଆ ଲିପି"),                            // Odia
        ("Taml", "தமிழ் எழுத்து"),                         // Tamil
        ("Telu", "తెలుగు లిపి"),                           // Telugu
        ("Knda", "ಕನ್ನಡ ಲಿಪಿ"),                            // Kannada
        ("Mlym", "മലയാളം ലിപി"),                          // Malayalam
        ("Sinh", "සිංහල අක්ෂර"),                          // Sinhala
        ("Thai", "สวัสดีชาวโลก"),                          // Thai
        ("Laoo", "ສະບາຍດີ"),                               // Lao
        ("Khmr", "សួស្តីពិភពលោក"),                           // Khmer
        ("Mymr", "မင်္ဂလာပါ"),                               // Myanmar
        ("Tibt", "བོད་ཡིག"),                               // Tibetan
        ("Geor", "ქართული დამწერლობა"),                 // Georgian
        ("Armn", "Հայերեն այբուբեն"),                    // Armenian
        ("Ethi", "ግዕዝ ፊደል"),                            // Ethiopic
        ("Cher", "ᏣᎳᎩ ᎦᏬᏂᎯᏍᏗ"),                          // Cherokee
        ("Cans", "ᐃᓄᒃᑎᑐᑦ"),                              // Canadian syllabics
        ("Mong", "ᠮᠣᠩᠭᠣᠯ ᠪᠢᠴᠢᠭ"),                          // Mongolian
        ("Syrc", "ܠܫܢܐ ܣܘܪܝܝܐ"),                          // Syriac
        ("Mtei", "ꯃꯤꯇꯩ ꯃꯌꯦꯛ"),                            // Meetei Mayek
        ("Olck", "ᱚᱞ ᱪᱤᱠᱤ"),                              // Ol Chiki
        ("Brai", "⠃⠗⠁⠊⠇⠇⠑")                                // Braille
    ]
}
