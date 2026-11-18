import CoreText
import SwiftUI

/// Each style the cask has, its name set in itself, as a specimen shows a family's weights.
struct SpecimenStyles: View {
    let specimen: Specimen
    let sample: String
    let ligatures: Bool
    @State private var showsAll = false
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 34
    private static let shown = 12

    var body: some View {
        let styles = specimen.styles
        SpecimenSection("Styles", detail: Text("\(styles.count) styles")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(showsAll ? styles : Array(styles.prefix(Self.shown))) { style in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(style.name)
                            .font(.caption)
                            .foregroundStyle(Color(.captionText))
                        Text(line(style))
                            .font(Font(font(style)))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .accessibilityHidden(true)
                    }
                }
                if styles.count > Self.shown {
                    Button(showsAll ? "Show Fewer Styles" : "Show All \(styles.count) Styles") {
                        withAnimation { showsAll.toggle() }
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// The style's name, where the face can draw it, else the sample's first line.
    private func line(_ style: SpecimenStyle) -> String {
        if TryOutText.draws(style.name, specimen.covered) {
            return style.name
        }
        return sample.split(separator: "\n").first.map(String.init) ?? sample
    }

    private func font(_ style: SpecimenStyle) -> CTFont {
        let font = CTFontCreateWithFontDescriptor(style.descriptor, size, nil)
        return ligatures ? font : TryOutText.withoutLigatures(font)
    }
}

/// Passages at the sizes text is read at, from a display line down to small print, as a specimen's setting shows
/// how a face holds up in use. From the Universal Declaration of Human Rights, as specimen-builder sets.
struct SpecimenSetting: View {
    let specimen: Specimen
    let ligatures: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    private struct Passage: Identifiable {
        let id: Int
        let role: LocalizedStringKey
        let style: Int
        let size: CGFloat
        let text: String
    }

    var body: some View {
        // Every passage is Latin, so a face for another script, which can't set them, leaves the section out.
        if TryOutText.draws(Self.paragraphs.joined(), specimen.covered) {
            SpecimenSection("Setting") {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(passages) { passage in
                        VStack(alignment: .leading, spacing: 6) {
                            let style = specimen.styles[passage.style].name
                            Text("\(Text(passage.role)) · \(style) · \(Int(passage.size)) pt")
                                .font(.caption)
                                .foregroundStyle(Color(.captionText))
                            setting(passage)
                        }
                    }
                }
            }
        }
    }

    private var passages: [Passage] {
        [
            Passage(id: 0, role: "Display", style: specimen.heavy, size: 40, text: Self.paragraphs[0]),
            Passage(id: 1, role: "Headline", style: specimen.medium, size: 26, text: Self.paragraphs[1]),
            Passage(id: 2, role: "Lead", style: specimen.light, size: 19, text: Self.paragraphs[2]),
            Passage(id: 3, role: "Body", style: specimen.regular, size: 15, text: Self.paragraphs[3]),
            Passage(id: 4, role: "Small", style: specimen.regular, size: 11, text: Self.paragraphs[4])
        ]
    }

    /// A passage, in two columns where there's room for small print to read comfortably that way.
    @ViewBuilder private func setting(_ passage: Passage) -> some View {
        let font = Font(font(passage))
        if passage.size < 13, sizeClass == .regular {
            let halves = Self.halves(passage.text)
            HStack(alignment: .top, spacing: 24) {
                Text(halves.0).font(font)
                Text(halves.1).font(font)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(passage.text)
                .font(font)
                .lineSpacing(passage.size * 0.2)
        }
    }

    private func font(_ passage: Passage) -> CTFont {
        let font = CTFontCreateWithFontDescriptor(specimen.styles[passage.style].descriptor, passage.size, nil)
        return ligatures ? font : TryOutText.withoutLigatures(font)
    }

    /// The text split at the sentence nearest its middle.
    private static func halves(_ text: String) -> (String, String) {
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let ends = text.ranges(of: ". ").map(\.upperBound)
        guard let split = ends.min(by: {
            abs(text.distance(from: middle, to: $0)) < abs(text.distance(from: middle, to: $1))
        }) else { return (text, "") }
        return (String(text[..<split]).trimmingCharacters(in: .whitespaces), String(text[split...]))
    }

    static let paragraphs = [
        "Everyone has the right to life, liberty and security of person.",
        "All human beings are born free and equal in dignity and rights.",
        "They are endowed with reason and conscience and should act towards one another in a spirit of "
            + "brotherhood. Everyone is entitled to all the rights and freedoms set forth in this Declaration, "
            + "without distinction of any kind.",
        "Everyone has the right to freedom of thought, conscience and religion; this right includes freedom to "
            + "change his religion or belief, and freedom, either alone or in community with others and in public "
            + "or private, to manifest his religion or belief in teaching, practice, worship and observance. "
            + "Everyone has the right to freedom of opinion and expression; this right includes freedom to hold "
            + "opinions without interference and to seek, receive and impart information and ideas through any "
            + "media and regardless of frontiers.",
        "Everyone has the right to rest and leisure, including reasonable limitation of working hours and periodic "
            + "holidays with pay. Everyone has the right to a standard of living adequate for the health and "
            + "well-being of himself and of his family, including food, clothing, housing and medical care and "
            + "necessary social services. Everyone has the right to education. Education shall be free, at least in "
            + "the elementary and fundamental stages. Elementary education shall be compulsory. Technical and "
            + "professional education shall be made generally available and higher education shall be equally "
            + "accessible to all on the basis of merit."
    ]
}

/// Every character the face has, by kind, with the one tapped shown large with its name and code point, as a
/// specimen's character grid.
struct SpecimenCharacters: View {
    let specimen: Specimen
    @State private var selected: Unicode.Scalar?
    @State private var expanded: Set<String> = []
    @ScaledMetric private var cell: CGFloat = 48
    /// Shown of each kind until asked for the rest: a CJK face has tens of thousands.
    private static let shown = 240

    /// A section of the page's lazy stack, whose header, the title and the character tapped shown large, pins under
    /// the navigation bar while the grid scrolls by, so a character's detail stays in sight as you go through them.
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(specimen.characters) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        grid(expanded.contains(group.id) ? group.scalars : Array(group.scalars.prefix(Self.shown)))
                        if group.scalars.count > Self.shown, !expanded.contains(group.id) {
                            Button("Show All \(group.scalars.count)") { expanded.insert(group.id) }
                                .font(.callout)
                        }
                    }
                }
            }
        } header: {
            let total = specimen.characters.reduce(0) { $0 + $1.scalars.count }
            SpecimenSection("Characters", detail: Text("\(total) characters")) {
                if let scalar = selected ?? specimen.characters.first?.scalars.first {
                    inspector(scalar)
                }
            }
            .padding(.bottom, 12)
            .background(Color(.systemBackground))
        }
    }

    private func inspector(_ scalar: Unicode.Scalar) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(String(scalar))
                .font(Font(font(size: 64)))
                .frame(width: 96, height: 96)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.name(of: scalar))
                    .font(.subheadline.weight(.semibold))
                Text(Self.codePoint(scalar))
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(.captionText))
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func grid(_ scalars: [Unicode.Scalar]) -> some View {
        let font = Font(font(size: 26))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: cell), spacing: 2)], spacing: 2) {
            ForEach(scalars, id: \.self) { scalar in
                Button {
                    selected = scalar
                } label: {
                    Text(String(scalar))
                        .font(font)
                        .frame(maxWidth: .infinity, minHeight: cell)
                        .background(selected == scalar ? AnyShapeStyle(.tint.opacity(0.18))
                                                       : AnyShapeStyle(.fill.quinary),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Self.name(of: scalar)))
                .accessibilityAddTraits(selected == scalar ? .isSelected : [])
            }
        }
    }

    private func font(size: CGFloat) -> CTFont {
        CTFontCreateWithFontDescriptor(specimen.styles[specimen.regular].descriptor, size, nil)
    }

    /// The character's Unicode name in title case, "Latin Capital Letter A", or its code point where it has none,
    /// as a private-use icon doesn't.
    static func name(of scalar: Unicode.Scalar) -> String {
        guard let name = scalar.properties.nameAlias ?? scalar.properties.name else { return codePoint(scalar) }
        return name.lowercased().capitalized
    }

    static func codePoint(_ scalar: Unicode.Scalar) -> String {
        "U+" + String(scalar.value, radix: 16, uppercase: true).leftPadded(to: 4)
    }
}

/// The languages whose every letter the face has, by CLDR's exemplar characters.
struct SpecimenLanguages: View {
    let names: [String]

    init(specimen: Specimen) {
        names = specimen.languages
            .map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        if !names.isEmpty {
            SpecimenSection("Languages", detail: Text("\(names.count) languages")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(names.joined(separator: " · "))
                        .font(.callout)
                    Text("Each has every letter the Unicode Common Locale Data Repository lists for it.")
                        .font(.footnote)
                        .foregroundStyle(Color(.captionText))
                }
            }
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
