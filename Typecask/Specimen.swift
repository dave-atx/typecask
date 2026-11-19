import CoreText
import Foundation

/// What a font page's full specimen shows, made from the cask's full fonts once they're on hand: every style,
/// the faces the setting is set in, the character set by kind, and the languages the face can set.
nonisolated struct Specimen: @unchecked Sendable {
    let styles: [SpecimenStyle]
    /// Indices into `styles` of the upright, normal-width faces nearest regular, light, medium and heaviest, which
    /// the setting's passages are set in. A family of one face uses it for all four.
    let regular: Int
    let light: Int
    let medium: Int
    let heavy: Int
    let characters: [CharacterGroup]
    /// Locale identifiers, like "fr" or "sr-Latn", of the languages whose every letter the face has.
    let languages: [String]
    /// The characters the face nearest regular has, so a line it can't draw is left out.
    let covered: CharacterSet
    /// The OpenType features the face nearest regular has that change what the specimen's text looks like.
    let features: [SpecimenFeature]

    init(faces: [TryOutLoader.Face]) {
        // Every face gives at least one style, and the loader never makes a specimen of no faces.
        let styles = Self.orderedStyles(of: faces)
        let weights = styles.map(\.weight)
        let upright = styles.indices.filter { !styles[$0].isItalic && styles[$0].isNormalWidth }
        let candidates = upright.isEmpty ? Array(styles.indices) : upright
        func nearest(_ weight: Double) -> Int {
            candidates.min { abs(weights[$0] - weight) < abs(weights[$1] - weight) } ?? 0
        }
        let regular = nearest(400)
        let lightest = candidates.min { weights[$0] < weights[$1] } ?? regular
        self.styles = styles
        self.regular = regular
        light = weights[lightest] < weights[regular] ? lightest : regular
        medium = nearest(500)
        heavy = candidates.max { weights[$0] < weights[$1] } ?? regular
        let font = CTFontCreateWithFontDescriptor(styles[regular].descriptor, 24, nil)
        let covered = CTFontCopyCharacterSet(font) as CharacterSet
        self.covered = covered
        characters = CharacterGroup.groups(covered)
        languages = Languages.supported(by: covered)
        features = SpecimenFeature.detected(in: font, covered: covered)
    }

    /// Each face's named instances, or the face itself where it has none, widest-normal first, then upright before
    /// italic and light before heavy, as a printed specimen lists them.
    private static func orderedStyles(of faces: [TryOutLoader.Face]) -> [SpecimenStyle] {
        var seen = Set<String>()
        var styles = faces.flatMap { face -> [SpecimenStyle] in
            let font = CTFontCreateWithFontDescriptor(face.descriptor, 24, nil)
            let traits = CTFontCopyTraits(font) as? [CFString: Any] ?? [:]
            let weight = cssWeight(traits[kCTFontWeightTrait] as? Double ?? 0)
            let width = traits[kCTFontWidthTrait] as? Double ?? 0
            let italic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
            let instances = FontTables.namedInstances(of: font)
            guard !instances.isEmpty else {
                return [SpecimenStyle(name: face.name, face: face, variation: [:], weight: weight,
                                      width: width * 100, isItalic: italic)]
            }
            return instances.map { instance in
                let variation = instance.variation
                // A face with an ital or slnt axis says by it; otherwise, as a separate italic file does, by traits.
                let slants = variation.keys.contains(FontTables.ital) || variation.keys.contains(FontTables.slnt)
                let slanted = (variation[FontTables.ital] ?? 0) >= 0.5 || (variation[FontTables.slnt] ?? 0) != 0
                return SpecimenStyle(name: instance.name, face: face, variation: variation,
                                     weight: variation[FontTables.wght] ?? weight,
                                     width: variation[FontTables.wdth].map { $0 - 100 } ?? width * 100,
                                     isItalic: slants ? slanted : italic)
            }
        }
        .filter { seen.insert($0.name).inserted }
        styles.sort { lhs, rhs in
            let left = [abs(lhs.width), lhs.width, lhs.isItalic ? 1 : 0, lhs.weight]
            let right = [abs(rhs.width), rhs.width, rhs.isItalic ? 1 : 0, rhs.weight]
            return left == right ? lhs.name < rhs.name : left.lexicographicallyPrecedes(right)
        }
        for index in styles.indices {
            styles[index].id = index
        }
        return styles
    }

    /// Core Text's weight trait, -1 to 1, as a CSS weight, 100 to 900, which a variable font's wght axis uses.
    private static func cssWeight(_ trait: Double) -> Double {
        let stops: [(trait: Double, weight: Double)] = [
            (-1, 100), (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700),
            (0.56, 800), (0.62, 900), (1, 1000)
        ]
        guard let upper = stops.firstIndex(where: { $0.trait >= trait }), upper > 0 else { return 100 }
        let low = stops[upper - 1], high = stops[upper]
        return low.weight + (trait - low.trait) / (high.trait - low.trait) * (high.weight - low.weight)
    }
}

/// A face, or one of a variable face's named instances, like DINish's Condensed Light.
nonisolated struct SpecimenStyle: Identifiable, @unchecked Sendable {
    var id = 0
    let name: String
    let face: TryOutLoader.Face
    /// The instance's axis values by axis identifier; empty for a static face.
    let variation: [Int: Double]
    /// A CSS weight, 100 to 900.
    let weight: Double
    /// Away from normal width, in percent: -25 for condensed.
    let width: Double
    let isItalic: Bool

    var isNormalWidth: Bool { abs(width) < 0.5 }

    var descriptor: CTFontDescriptor { descriptor(moving: [:]) }

    /// The face at this style's axis values, with any of them moved.
    func descriptor(moving moved: [Int: Double]) -> CTFontDescriptor {
        let values = variation.merging(moved) { $1 }
        guard !values.isEmpty else { return face.descriptor }
        let attributes = [kCTFontVariationAttribute: values as CFDictionary] as CFDictionary
        return CTFontDescriptorCreateCopyWithAttributes(face.descriptor, attributes)
    }
}

/// The characters a face has of one kind, as the character grid lists them.
nonisolated struct CharacterGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let scalars: [Unicode.Scalar]

    /// The face's characters by kind, in the order a specimen shows them. Controls, spaces and marks, which
    /// draw nothing on their own, are left out.
    static func groups(_ covered: CharacterSet) -> [CharacterGroup] {
        var kinds: [Kind: [Unicode.Scalar]] = [:]
        for plane in UInt32(0)...16 where covered.hasMember(inPlane: UInt8(plane)) {
            for value in (plane << 16)...(plane << 16 | 0xFFFF) {
                guard let scalar = Unicode.Scalar(value), covered.contains(scalar),
                      let kind = Kind(scalar) else { continue }
                kinds[kind, default: []].append(scalar)
            }
        }
        return Kind.allCases.compactMap { kind in
            kinds[kind].map { CharacterGroup(id: "\(kind)", title: kind.title, scalars: $0) }
        }
    }

    private enum Kind: CaseIterable {
        case uppercase, lowercase, figures, punctuation, greek, cyrillic, otherLetters, symbols, icons

        init?(_ scalar: Unicode.Scalar) {
            let value = scalar.value
            switch scalar.properties.generalCategory {
            case .uppercaseLetter where Self.isLatin(value): self = .uppercase
            case .lowercaseLetter where Self.isLatin(value): self = .lowercase
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                if (0x0370...0x03FF).contains(value) || (0x1F00...0x1FFF).contains(value) {
                    self = .greek
                } else if (0x0400...0x052F).contains(value) {
                    self = .cyrillic
                } else {
                    self = .otherLetters
                }
            case .decimalNumber, .letterNumber, .otherNumber: self = .figures
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation: self = .punctuation
            case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: self = .symbols
            case .privateUse: self = .icons
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .uppercase: String(localized: "Uppercase")
            case .lowercase: String(localized: "Lowercase")
            case .figures: String(localized: "Figures")
            case .punctuation: String(localized: "Punctuation")
            case .greek: Locale.current.localizedString(forScriptCode: "Grek") ?? "Greek"
            case .cyrillic: Locale.current.localizedString(forScriptCode: "Cyrl") ?? "Cyrillic"
            case .otherLetters: String(localized: "Other Letters")
            case .symbols: String(localized: "Symbols")
            case .icons: String(localized: "Icons")
            }
        }

        private static func isLatin(_ value: UInt32) -> Bool {
            value <= 0x024F || (0x1E00...0x1EFF).contains(value) || (0x2C60...0x2C7F).contains(value)
                || (0xA720...0xA7FF).contains(value)
        }
    }
}

/// The letters each language needs, from CLDR's exemplar characters (scripts/languages.py writes the file).
nonisolated enum Languages {
    private struct File: Decodable {
        let languages: [String: String]
    }

    static let letters: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Languages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return file.languages
    }()

    /// The languages whose every letter the face has, by locale identifier.
    static func supported(by covered: CharacterSet) -> [String] {
        letters.filter { $0.value.unicodeScalars.allSatisfy(covered.contains) }.keys.sorted()
    }
}

/// What Core Text doesn't say about a font: a variable font's named instances, read from its fvar and name tables.
nonisolated enum FontTables {
    static let wght = tag("wght")
    static let wdth = tag("wdth")
    static let slnt = tag("slnt")
    static let ital = tag("ital")

    struct Instance {
        let name: String
        let variation: [Int: Double]
    }

    /// The instances the font names, like Condensed Light, with their axis values, in the font's own order.
    static func namedInstances(of font: CTFont) -> [Instance] {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableFvar), []) else { return [] }
        let fvar = Reader(data: table as Data)
        guard let axesOffset = fvar.u16(4), let axisCount = fvar.u16(8), let axisSize = fvar.u16(10),
              let instanceCount = fvar.u16(12), let instanceSize = fvar.u16(14),
              instanceSize >= 4 + 4 * axisCount else { return [] }
        let tags = (0..<axisCount).compactMap { fvar.u32(axesOffset + $0 * axisSize).map(Int.init) }
        guard tags.count == axisCount else { return [] }
        let names = nameStrings(of: font)
        let start = axesOffset + axisCount * axisSize
        return (0..<instanceCount).compactMap { index in
            let offset = start + index * instanceSize
            guard let nameID = fvar.u16(offset), let name = names[nameID] else { return nil }
            var variation: [Int: Double] = [:]
            for (axis, tag) in tags.enumerated() {
                guard let value = fvar.u32(offset + 4 + 4 * axis) else { return nil }
                variation[tag] = Double(Int32(bitPattern: value)) / 65536
            }
            return Instance(name: name, variation: variation)
        }
    }

    /// The name table's strings by name ID, in US English where there's a choice.
    static func nameStrings(of font: CTFont) -> [Int: String] {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) else { return [:] }
        let name = Reader(data: table as Data)
        guard let count = name.u16(2), let storage = name.u16(4) else { return [:] }
        var best: [Int: (rank: Int, text: String)] = [:]
        for index in 0..<count {
            let record = 6 + index * 12
            guard let platform = name.u16(record), let encoding = name.u16(record + 2),
                  let language = name.u16(record + 4), let nameID = name.u16(record + 6),
                  let length = name.u16(record + 8), let offset = name.u16(record + 10),
                  let bytes = name.bytes(storage + offset, length) else { continue }
            let rank: Int
            let text: String?
            switch (platform, encoding) {
            case (3, 1), (3, 10), (0, _):
                rank = platform == 3 && language == 0x409 ? 3 : platform == 0 ? 2 : 1
                text = String(bytes: bytes, encoding: .utf16BigEndian)
            case (1, 0):
                rank = 0
                text = String(bytes: bytes, encoding: .macOSRoman)
            default:
                continue
            }
            if let text, rank > best[nameID]?.rank ?? -1 {
                best[nameID] = (rank, text)
            }
        }
        return best.mapValues(\.text)
    }

    /// The OpenType substitution features the font has, by tag, each with the name its designer gave it where a
    /// stylistic set or character variant has one, like DINish's "Alternate digit 1".
    static func substitutionFeatures(of font: CTFont) -> [String: String?] {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableGSUB), []) else { return [:] }
        let gsub = Reader(data: table as Data)
        guard let list = gsub.u16(6), let count = gsub.u16(list) else { return [:] }
        var names: [Int: String]?
        var features: [String: String?] = [:]
        for index in 0..<count {
            let record = list + 2 + index * 6
            guard let value = gsub.u32(record), let offset = gsub.u16(record + 4) else { continue }
            let tag = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, encoding: .ascii)
            guard let tag, features[tag] == nil else { continue }
            // A stylistic set's params are a version then a name ID; a character variant's, a format then one.
            var name: String?
            if tag.hasPrefix("ss") || tag.hasPrefix("cv"), let params = gsub.u16(list + offset), params != 0,
               let nameID = gsub.u16(list + offset + params + 2) {
                names = names ?? nameStrings(of: font)
                name = names?[nameID]
            }
            features[tag] = name
        }
        return features
    }

    private static func tag(_ string: String) -> Int {
        string.unicodeScalars.reduce(0) { $0 << 8 | Int($1.value) }
    }

    /// Big-endian reads that return nil past the end of the table, rather than trapping on a broken font.
    private struct Reader {
        let data: Data

        func u16(_ offset: Int) -> Int? {
            bytes(offset, 2).map { Int($0[0]) << 8 | Int($0[1]) }
        }

        func u32(_ offset: Int) -> UInt32? {
            bytes(offset, 4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }

        func bytes(_ offset: Int, _ count: Int) -> [UInt8]? {
            guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
            let start = data.startIndex + offset
            return Array(data[start..<start + count])
        }
    }
}
