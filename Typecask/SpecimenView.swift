import CoreText
import SwiftUI

/// A section of a font page laid out like a printed specimen's: a hairline rule, a small capitalized title with
/// a count beside it, and what follows.
struct SpecimenSection<Content: View>: View {
    let title: LocalizedStringKey
    let detail: Text?
    /// The title's identifier, for the UI tests, which shouldn't depend on its wording.
    let identifier: String?
    let content: Content

    init(_ title: LocalizedStringKey, detail: Text? = nil, identifier: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.identifier = identifier
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
                        .accessibilityIdentifier(identifier ?? "")
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
        // Not a LazyVGrid: it sizes its rows once, so text grown in place, as the accessibility audit grows it,
        // outgrew the last row.
        FactColumns(minimumWidth: column, spacing: 16) {
            if let foundries = cask.foundries, !foundries.isEmpty {
                fact(foundries.count == 1 ? "Foundry" : "Foundries", combines: false) {
                    MakerLinks(kind: .foundry, names: foundries)
                }
            }
            if let designers = cask.designers, !designers.isEmpty {
                fact(designers.count == 1 ? "Designer" : "Designers", combines: false) {
                    MakerLinks(kind: .designer, names: designers)
                }
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

    /// One element to VoiceOver, "Updated, Nov 3", unless its value holds links, which each need to be their own.
    private func fact(_ label: LocalizedStringKey, combines: Bool = true,
                      @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color(.captionText))
            value()
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: combines ? .combine : .contain)
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

/// The full specimen's download, once the actions row's Full Specimen asks for it: its progress, or why it failed.
struct FullSpecimenPrompt: View {
    let cask: Cask
    let loader: TryOutLoader?
    let start: () -> Void

    var body: some View {
        SpecimenSection("Full Specimen") {
            switch loader?.phase {
            case nil:
                EmptyView()
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

/// The facts in as many columns as fit at `minimumWidth`, two on an iPhone and more on an iPad, filled row by row,
/// each row as tall as its tallest fact.
private struct FactColumns: Layout {
    let minimumWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // An unbounded proposal, as a stack beside the page asks while working out how much room to give it, gets
        // two columns' width, as no proposal does.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumWidth * 2 + spacing
        let heights = rowHeights(subviews, width: width)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (count, width) = columns(bounds.width)
        var top = bounds.minY
        for (row, height) in rowHeights(subviews, width: bounds.width).enumerated() {
            for column in 0..<count where row * count + column < subviews.count {
                let leading = bounds.minX + CGFloat(column) * (width + spacing)
                subviews[row * count + column].place(at: CGPoint(x: leading, y: top),
                                                     proposal: ProposedViewSize(width: width, height: nil))
            }
            top += height + spacing
        }
    }

    /// How many columns fit, and how wide each is.
    private func columns(_ width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    /// Each row's height, its tallest fact's at the column's width.
    private func rowHeights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        let (count, columnWidth) = columns(width)
        let proposal = ProposedViewSize(width: columnWidth, height: nil)
        return stride(from: 0, to: subviews.count, by: count).map { start in
            subviews[start..<min(start + count, subviews.count)].map { $0.sizeThatFits(proposal).height }.max() ?? 0
        }
    }
}
