import CoreText
import SwiftUI

/// A section of a font page laid out like a printed specimen's: a hairline rule, a small capitalized title with
/// a count beside it, and what follows.
struct SpecimenSection<Content: View>: View {
    let title: LocalizedStringKey
    let detail: Text?
    let content: Content

    init(_ title: LocalizedStringKey, detail: Text? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    detail
                        .font(.caption)
                        .foregroundStyle(Color(.captionText))
                }
            }
            content
        }
    }
}

/// The top of a font page: a few of its letters, large, then its name and what it is, as a specimen's masthead.
struct SpecimenMasthead: View {
    let cask: Cask
    let catalog: Catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Drawn from the preview, which has only the sample's letters, so the poster is made of those.
            Text(poster)
                .font(PreviewFonts.font(cask.previewFile, size: 144))
                .lineLimit(1)
                .minimumScaleFactor(0.25)
                .accessibilityHidden(true)
            Text(cask.name)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(Color(.captionText))
        }
    }

    /// abc, as specimen-builder's poster has, or for a font for another script, the first three letters of its own
    /// line.
    private var poster: String {
        let line = (cask.sample ?? catalog.sampleText).split(separator: "\n").first.map(String.init) ?? ""
        if ["a", "b", "c"].allSatisfy(line.contains) {
            return "abc"
        }
        return String(line.filter(\.isLetter).prefix(3))
    }

    /// The design style and the writing systems, "Sans Serif · Latin, Cyrillic".
    private var summary: String {
        let scripts = cask.scripts.map { Locale.current.localizedString(forScriptCode: $0) ?? $0 }
        return ([String(localized: cask.style.name)] + (scripts.isEmpty ? [] : [scripts.formatted(.list(type: .and))]))
            .joined(separator: " · ")
    }
}

/// A font page's facts, as a specimen's masthead lists them: small labels over their values, two or more to a row.
struct SpecimenFacts: View {
    let cask: Cask
    @ScaledMetric private var column: CGFloat = 140

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: column), spacing: 16, alignment: .topLeading)],
                  alignment: .leading, spacing: 16) {
            if let designers = cask.designers, !designers.isEmpty {
                fact("Designer") { Text(designers, format: .list(type: .and)) }
            }
            if let updated = cask.updatedDate {
                // In UTC, the zone the date was written in, so it doesn't read as the day before west of it.
                fact("Updated") {
                    Text(updated.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
                }
            }
            if let version = cask.version {
                fact("Version") { Text(version) }
            }
            fact("Fonts") { Text(cask.fonts, format: .number) }
            fact("Download") { Text(cask.bytes, format: .byteCount(style: .file)) }
            if let popularity = cask.popularity {
                fact("Popularity") { PopularityRank(rank: popularity) }
            }
        }
    }

    private func fact(_ label: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color(.captionText))
            value()
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The sample size, which carries over to every font's page; until it's moved, the sample follows the text size.
struct SpecimenSize: DynamicProperty {
    @AppStorage("specimenSize") private var chosenSize: Double = 0
    @ScaledMetric(relativeTo: .largeTitle) private var standardSize: CGFloat = 40
    static let sizes: ClosedRange<Double> = 12...144

    var wrappedValue: Double {
        chosenSize > 0 ? chosenSize : min(max(standardSize, Self.sizes.lowerBound), Self.sizes.upperBound)
    }

    var binding: Binding<Double> {
        // Rounded rather than stepped: a step draws a dot for every stop along the track.
        Binding { wrappedValue } set: { chosenSize = $0.rounded() }
    }
}

/// The slider for `SpecimenSize`.
struct SpecimenSizeSlider: View {
    let size: Binding<Double>

    var body: some View {
        Slider(value: size, in: SpecimenSize.sizes) {
            Text("Sample Size")
        } minimumValueLabel: {
            Image(systemName: "textformat.size.smaller")
                .accessibilityHidden(true)
        } maximumValueLabel: {
            Image(systemName: "textformat.size.larger")
                .accessibilityHidden(true)
        }
        .accessibilityValue(Text("\(Int(size.wrappedValue)) points"))
        .accessibilityIdentifier("specimenSize")
    }
}

/// The type tester: the sample at a size of the reader's choosing, to judge a face at the size they'd read it. With
/// the full fonts it gains rather than changes: the same line, now editable, keeps its place, and the controls
/// specimen-builder's tester has, style, alignment, line height and a variable face's axes, are added below.
struct TypeTester: View {
    let cask: Cask
    let catalog: Catalog
    @Binding var ligatures: Bool
    let specimen: Specimen?
    private var size = SpecimenSize()
    /// What's typed in place of the sample; nil for the sample itself.
    @State private var typed: String?
    /// The style picked, by index into the specimen's; nil for its regular.
    @State private var style: Int?
    /// The style's axes moved away from its own values, by axis identifier.
    @State private var moved: [Int: Double] = [:]
    @State private var alignment = TextAlignment.leading
    /// Line height as a multiple of the font's own, which leaves the sample as the preview set it until moved.
    @State private var lineHeight = 1.0

    init(cask: Cask, catalog: Catalog, ligatures: Binding<Bool>, specimen: Specimen?) {
        self.cask = cask
        self.catalog = catalog
        _ligatures = ligatures
        self.specimen = specimen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                if let specimen {
                    editor(specimen)
                } else {
                    CaskSpecimenText(cask: cask, catalog: catalog, size: size.wrappedValue, lineLimit: nil,
                                     ligatures: ligatures)
                }
                SpecimenSizeSlider(size: size.binding)
            }
            if cask.ligatures == true {
                LigaturesToggle(isOn: $ligatures)
            }
            if let specimen {
                controls(specimen)
            }
        }
    }

    private var sample: String { cask.sample ?? catalog.sampleText }

    /// The sample as `CaskSpecimenText` sets it, Nerd Fonts' icons and all, with the line made editable.
    private func editor(_ specimen: Specimen) -> some View {
        VStack(alignment: .leading, spacing: size.wrappedValue / 4) {
            TextField("Type something", text: Binding { typed ?? sample } set: { typed = $0 == sample ? nil : $0 },
                      axis: .vertical)
                .font(Font(font(specimen)))
                .lineSpacing(size.wrappedValue * (lineHeight - 1))
                .multilineTextAlignment(alignment)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("specimen")
            if cask.glyphs {
                Text(catalog.glyphSample)
                    .font(PreviewFonts.font(cask.previewFile, size: size.wrappedValue))
                    .lineLimit(1)
                    .accessibilityLabel("Nerd Fonts icons")
            }
        }
    }

    @ViewBuilder private func controls(_ specimen: Specimen) -> some View {
        let current = specimen.styles[style ?? specimen.regular]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if specimen.styles.count > 1 {
                    Picker("Style", selection: Binding { style ?? specimen.regular } set: { style = $0; moved = [:] }) {
                        ForEach(specimen.styles) { style in
                            Text(style.name).tag(style.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("specimenStyle")
                }
                Spacer()
                Picker("Alignment", selection: $alignment) {
                    Label("Left", systemImage: "text.alignleft").tag(TextAlignment.leading)
                    Label("Center", systemImage: "text.aligncenter").tag(TextAlignment.center)
                    Label("Right", systemImage: "text.alignright").tag(TextAlignment.trailing)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .fixedSize()
            }
            control("Line Height") {
                Slider(value: $lineHeight, in: 1...2)
                    .accessibilityValue(Text(lineHeight, format: .number.precision(.fractionLength(1))))
            }
            ForEach(current.face.axes) { axis in
                let value = Binding { moved[axis.id] ?? current.variation[axis.id] ?? axis.defaultValue } set: {
                    moved[axis.id] = $0
                }
                control(LocalizedStringKey(axis.name)) {
                    Slider(value: value, in: axis.range)
                        .accessibilityValue(Text(value.wrappedValue, format: .number.precision(.fractionLength(0))))
                }
            }
            if typed != nil {
                Button("Restore Sample Text", systemImage: "arrow.counterclockwise") { typed = nil }
                    .font(.callout)
            }
        }
    }

    private func control(_ label: LocalizedStringKey, @ViewBuilder slider: () -> some View) -> some View {
        LabeledContent {
            slider()
        } label: {
            Text(label)
                .font(.callout)
                .frame(minWidth: 90, alignment: .leading)
        }
    }

    private func font(_ specimen: Specimen) -> CTFont {
        let current = specimen.styles[style ?? specimen.regular]
        let font = CTFontCreateWithFontDescriptor(current.descriptor(moving: moved), size.wrappedValue, nil)
        return ligatures ? font : TryOutText.withoutLigatures(font)
    }
}

/// Offers the full specimen, which needs the cask's full fonts: shown for one that isn't installed, with what it
/// downloads, then its progress, or why it failed.
struct FullSpecimenPrompt: View {
    let cask: Cask
    let loader: TryOutLoader?
    let start: () -> Void

    var body: some View {
        SpecimenSection("Full Specimen") {
            switch loader?.phase {
            case nil:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Every style, set in passages, the whole character set and the languages it covers.")
                        .font(.callout)
                        .foregroundStyle(Color(.captionText))
                    Button("Show Full Specimen", systemImage: "text.book.closed", action: start)
                        .buttonStyle(.glass)
                        .accessibilityHint(Text("Downloads \(cask.bytes.formatted(.byteCount(style: .file)))."))
                        .accessibilityIdentifier("fullSpecimen")
                }
            case .loading:
                ProgressView("Downloading \(cask.bytes.formatted(.byteCount(style: .file)))…",
                             value: loader?.progress ?? 0)
                    .frame(maxWidth: 280)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text(message)
                    } icon: {
                        // Red on the icon alone: red text is 3.5:1 on white, short of the 4.5:1 text needs.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Button("Try Again", systemImage: "arrow.clockwise", action: start)
                        .buttonStyle(.glass)
                }
            case .loaded:
                EmptyView()
            }
        }
    }
}
