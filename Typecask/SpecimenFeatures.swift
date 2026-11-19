import CoreText
import SwiftUI
import UIKit

/// An OpenType feature the face has, with text that shows it: DINish's fractions turn 1/2 into ½. Found, not
/// listed by hand: a feature is shown only when the font has it and shaping its text with it on draws different
/// glyphs from shaping it with it off, so a feature that does nothing to that text is left out.
nonisolated struct SpecimenFeature: Identifiable, Sendable {
    /// A run of the demo text, with the feature applied or not: a superscript is applied to the 2 in x2 alone.
    struct Part: Sendable {
        let text: String
        let featured: Bool
    }

    let tag: String
    let name: String
    let parts: [Part]

    var id: String { tag }

    /// Features with a text that shows them, in the order a specimen lists them: figures, then the rest.
    private struct Demo {
        let tag: String
        let name: String.LocalizationValue
        /// The text in pieces, a word or a formula each, of which the specimen shows only the ones the feature
        /// changes: Geist Pixel's fractions make ½ and ¾ but leave 7/8 as it is, so it shows 1/2 3/4.
        let segments: [[Part]]
        /// Whether a piece shows only if the feature changes every featured character in it, not just one: Geist
        /// Pixel's superscripts have ¹ but no superior zero, so x10 came out x¹0.
        let changesEvery: Bool

        init(_ tag: String, _ name: String.LocalizationValue, _ parts: [Part]) {
            self.init(tag, name, segments: [parts])
        }

        init(_ tag: String, _ name: String.LocalizationValue, words: String) {
            self.init(tag, name, segments: words.split(separator: " ").map { [Part(text: String($0), featured: true)] })
        }

        init(_ tag: String, _ name: String.LocalizationValue, segments: [[Part]], changesEvery: Bool = false) {
            self.tag = tag
            self.name = name
            self.segments = segments
            self.changesEvery = changesEvery
        }
    }

    private static let demos: [Demo] = [
        Demo("frac", "Fractions", words: "1/2 3/4 7/8"),
        Demo("lnum", "Lining Figures", [Part(text: "0123456789", featured: true)]),
        Demo("onum", "Oldstyle Figures", [Part(text: "0123456789", featured: true)]),
        Demo("tnum", "Tabular Figures", [Part(text: "1,111.10 / 9,876.54", featured: true)]),
        Demo("pnum", "Proportional Figures", [Part(text: "1,111.10 / 9,876.54", featured: true)]),
        Demo("zero", "Slashed Zero", [Part(text: "0 10 100", featured: true)]),
        Demo("sups", "Superscripts", segments: [
            [Part(text: "E = mc", featured: false), Part(text: "2", featured: true)],
            [Part(text: "x", featured: false), Part(text: "10", featured: true)]
        ], changesEvery: true),
        Demo("subs", "Subscripts", segments: [
            [Part(text: "H", featured: false), Part(text: "2", featured: true), Part(text: "O", featured: false)],
            [Part(text: "CO", featured: false), Part(text: "2", featured: true)]
        ], changesEvery: true),
        Demo("sinf", "Scientific Inferiors", segments: [[
            Part(text: "C", featured: false), Part(text: "6", featured: true), Part(text: "H", featured: false),
            Part(text: "12", featured: true), Part(text: "O", featured: false), Part(text: "6", featured: true)
        ]], changesEvery: true),
        Demo("ordn", "Ordinals", [Part(text: "1a 2o No. 3", featured: true)]),
        Demo("case", "Case-Sensitive Forms", [Part(text: "(HELLO) [WORLD] ¿QUÉ? A-Z", featured: true)]),
        Demo("smcp", "Small Capitals", [Part(text: "Small Capitals", featured: true)]),
        Demo("c2sc", "Capitals to Small Capitals", [Part(text: "NASA AND UNESCO", featured: true)]),
        Demo("dlig", "Discretionary Ligatures", words: "ct st sp Th"),
        Demo("hlig", "Historical Ligatures", words: "ct st ſt"),
        Demo("titl", "Titling Alternates", [Part(text: "TITLING", featured: true)])
    ]

    /// What a stylistic set, character variant, stylistic alternate or swash is looked for in: each of these
    /// characters, shaped alone, that the feature changes is shown.
    private static let alternates = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789&?!@$%*#"
    private static let alternatesShown = 16

    static func detected(in font: CTFont, covered: CharacterSet) -> [SpecimenFeature] {
        let tags = FontTables.substitutionFeatures(of: font)
        var features = demos.compactMap { demo -> SpecimenFeature? in
            guard tags.keys.contains(demo.tag) else { return nil }
            let shown = demo.segments.filter { segment in
                TryOutText.draws(segment.map(\.text).joined(), covered)
                    && (demo.changesEvery ? changesEvery(segment, demo.tag, font) : changes(segment, demo.tag, font))
            }
            guard !shown.isEmpty else { return nil }
            let parts = Array(shown.joined(separator: [Part(text: " ", featured: false)]))
            return SpecimenFeature(tag: demo.tag, name: String(localized: demo.name), parts: parts)
        }
        // Sets and variants after the rest, in tag order: ss01, ss02, then cv01.
        let numbered = tags.keys.filter { $0.hasPrefix("ss") || $0.hasPrefix("cv") }.sorted { lhs, rhs in
            lhs.hasPrefix("ss") != rhs.hasPrefix("ss") ? lhs.hasPrefix("ss") : lhs < rhs
        }
        for tag in ["salt", "swsh"].filter(tags.keys.contains) + numbered {
            let changed = alternates.unicodeScalars.filter { covered.contains($0) }.map(String.init).filter {
                changes([Part(text: $0, featured: true)], tag, font)
            }
            guard !changed.isEmpty else { continue }
            let text = changed.prefix(alternatesShown).joined(separator: " ")
            features.append(SpecimenFeature(tag: tag, name: (tags[tag] ?? nil) ?? name(of: tag),
                                            parts: [Part(text: text, featured: true)]))
        }
        return features
    }

    /// A numbered feature's name where its designer gave none: Stylistic Set 1, Character Variant 2.
    private static func name(of tag: String) -> String {
        let number = Int(tag.dropFirst(2)) ?? 0
        return switch tag.prefix(2) {
        case "ss": String(localized: "Stylistic Set \(number)")
        case "cv": String(localized: "Character Variant \(number)")
        case "sa": String(localized: "Stylistic Alternates")
        default: String(localized: "Swashes")
        }
    }

    /// The feature's name and its text, "Fractions: 1/2 3/4 7/8", for Try It Out's sample.
    var sampleLine: String { "\(name): \(parts.map(\.text).joined())" }

    /// The font with these features on and, unless `ligatures`, its ligatures off. In one set of feature settings,
    /// since a copy's settings replace those of the font it copies.
    static func font(_ font: CTFont, features: Set<String>, ligatures: Bool) -> CTFont {
        var settings = features.sorted().map { [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 1] }
        if !ligatures {
            settings += ["liga", "clig", "calt"].map { [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 0] }
        }
        guard !settings.isEmpty else { return font }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: settings]
                                                                as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    /// The font with the feature turned on.
    static func font(_ font: CTFont, with tag: String) -> CTFont {
        let setting = [kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: 1] as [CFString: Any]
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: [setting]]
                                                                as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    /// Whether the feature draws the text differently, and not with blanks where it had ink: EB Garamond 0.016's
    /// fractions put an empty fraction slash between the figures, so 1/2 came out as 1 and 2 a slash's width apart.
    private static func changes(_ parts: [Part], _ tag: String, _ font: CTFont) -> Bool {
        let plain = shaped(parts, font, featured: font)
        let featured = shaped(parts, font, featured: Self.font(font, with: tag))
        return featured.glyphs != plain.glyphs && featured.blanks <= plain.blanks
    }

    /// Whether the feature changes each featured character on its own, in its place in the text.
    private static func changesEvery(_ parts: [Part], _ tag: String, _ font: CTFont) -> Bool {
        parts.indices.filter { parts[$0].featured }.allSatisfy { featured in
            parts[featured].text.indices.allSatisfy { character in
                let alone = parts.indices.flatMap { index -> [Part] in
                    let text = parts[index].text
                    guard index == featured else { return [Part(text: text, featured: false)] }
                    return [Part(text: String(text[..<character]), featured: false),
                            Part(text: String(text[character]), featured: true),
                            Part(text: String(text[text.index(after: character)...]), featured: false)]
                }
                return changes(alone.filter { !$0.text.isEmpty }, tag, font)
            }
        }
    }

    /// The glyphs the text shapes to, and how many of them draw nothing, as a space doesn't.
    private static func shaped(_ parts: [Part], _ font: CTFont, featured: CTFont) -> (glyphs: [CGGlyph], blanks: Int) {
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        let string = NSMutableAttributedString()
        for part in parts {
            string.append(NSAttributedString(string: part.text, attributes: [key: part.featured ? featured : font]))
        }
        let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(string)) as? [CTRun] ?? []
        var blanks = 0
        let glyphs = runs.flatMap { run in
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            // Toll-free bridged, and unlike CTFont, a cast to it can fail.
            if let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as? UIFont {
                var bounds = [CGRect](repeating: .zero, count: count)
                CTFontGetBoundingRectsForGlyphs(runFont as CTFont, .default, glyphs, &bounds, count)
                blanks += bounds.count(where: \.isEmpty)
            }
            return glyphs
        }
        return (glyphs, blanks)
    }
}

/// The face's OpenType features, each as its text without the feature and with it.
struct SpecimenFeatures: View {
    let specimen: Specimen
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 30

    var body: some View {
        if !specimen.features.isEmpty {
            SpecimenSection("Features", detail: Text("\(specimen.features.count) features"),
                            identifier: "section.features") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(specimen.features) { feature in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.name)
                                    .font(.caption)
                                    .foregroundStyle(Color(.captionText))
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .firstTextBaseline, spacing: 14) { comparison(feature) }
                                    VStack(alignment: .leading, spacing: 4) { comparison(feature) }
                                }
                            }
                            Spacer(minLength: 8)
                            TryOutMark()
                        }
                        .accessibilityElement(children: .ignore)
                        // Its name and its text, which reads the same either way: the feature changes glyphs, not
                        // characters. "Off" and "On" alone said nothing.
                        .accessibilityLabel(Text(verbatim: feature.sampleLine))
                        .opensTryOut(TryOutStart(source: "feature-\(feature.tag)", feature: feature),
                                     hint: Text("Opens Try It Out with \(feature.name) on."))
                        .accessibilityIdentifier("specimenFeature.\(feature.tag)")
                    }
                }
            }
        }
    }

    /// Off, dimmed, then an arrow, then on.
    @ViewBuilder private func comparison(_ feature: SpecimenFeature) -> some View {
        text(feature, isOn: false)
            .foregroundStyle(Color(.captionText))
        Image(systemName: "arrow.right")
            .font(.body)
            .foregroundStyle(Color(.captionText))
            .accessibilityHidden(true)
        text(feature, isOn: true)
    }

    private func text(_ feature: SpecimenFeature, isOn: Bool) -> Text {
        let base = CTFontCreateWithFontDescriptor(specimen.styles[specimen.regular].descriptor, size, nil)
        let featured = isOn ? SpecimenFeature.font(base, with: feature.tag) : base
        return feature.parts.reduce(Text(verbatim: "")) { text, part in
            Text("\(text)\(Text(verbatim: part.text).font(Font(part.featured ? featured : base)))")
        }
    }
}
