import CoreText
import Foundation

/// Which sample a face is previewed with: the same rules as sample_for() and own_script() in
/// scripts/build-catalog.py, from the same tables, so Apple's fonts and the casks preview alike.
/// Change both together.
enum OwnScript {
    /// The line in the face's own script, then `latinSample` on the next where it has Latin letters
    /// too, or nil for a Latin face, which the app shows the catalog's sample text in.
    static func sample(for font: CTFont, family: String, latinSample: String) -> String? {
        let latin = covers(font, "The quick brown fox jumps over the lazy dog")
        guard let script = script(of: font, family: family, latin: latin) else { return nil }
        let line = samples.first { $0.script == script }!.sample
        return latin ? line + "\n" + latinSample : line
    }

    /// The script a face is for, or nil for a Latin face. A face with no Latin is for the first it
    /// covers. One with Latin is for a CJK script when it has the thousands of characters one needs, or
    /// the kana alone of a kana display face, since Japanese fonts carry Greek and Cyrillic too.
    /// Otherwise it's for another script when it covers just that one and has neither Greek nor
    /// Cyrillic: Lucida Grande, with Arabic, Hebrew and Thai beside the scripts of Europe, is a Latin
    /// face. Braille counts only where there's nothing else.
    private static func script(of font: CTFont, family: String, latin: Bool) -> String? {
        let covered = samples.filter { covers(font, $0.sample) }.map(\.script)
        let characters = CTFontCopyCharacterSet(font) as CharacterSet
        func count(_ range: ClosedRange<UInt32>) -> Int {
            range.count(where: { Unicode.Scalar($0).map { characters.contains($0) } ?? false })
        }
        let kana = count(0x3040...0x30FF)
        let hangul = count(0xAC00...0xD7A3)
        let ideographs = count(0x4E00...0x9FFF) + hangul
        let cjk = covered.filter(cjkScripts.contains)
        let others = covered.filter { !cjkScripts.contains($0) && $0 != "Brai" }
        func cjkScript() -> String {
            Self.cjkScript(of: font, family: family, kana: kana, hangul: hangul, covered: cjk)
        }
        if !latin {
            return cjk.isEmpty ? covered.first : cjkScript()
        }
        if !cjk.isEmpty && others.count < 6 && (ideographs >= 2000 || (kana >= 80 && ideographs < 20)) {
            return cjkScript()
        }
        if cjk.isEmpty && others.count == 1 && count(0x0391...0x03C9) < 20 && count(0x0410...0x044F) < 20 {
            return others[0]
        }
        return nil
    }

    /// Which of the CJK scripts in `covered` a CJK face is for: the region its family name gives, else
    /// the one its OS/2 code pages name alone, else Japanese for a face with kana, Korean for one with
    /// hangul, and Chinese.
    private static func cjkScript(of font: CTFont, family: String, kana: Int, hangul: Int,
                                  covered: [String]) -> String {
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
        } else if kana >= 80 {
            wanted = "Jpan"
        } else if hangul >= 2000 {
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
