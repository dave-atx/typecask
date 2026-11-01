import SwiftUI

/// Font Book's grid: one card per font, each set in its own face.
struct GalleryGrid: View {
    let items: [GalleryItem]
    let catalog: Catalog
    let summary: LocalizedStringResource?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
            // In the grid rather than above it, inside the one lazy container the scroll view holds.
            Section {
                cards
            } header: {
                if let summary {
                    CollectionSummary(text: summary)
                }
            }
        }
        .padding()
    }

    private var cards: some View {
        ForEach(items) { item in
            NavigationLink(value: item) {
                switch item {
                case .cask(let cask):
                    CaskCard(cask: cask, catalog: catalog)
                case .apple(let family):
                    AppleFontCard(family: family, sampleText: catalog.sampleText)
                }
            }
            .buttonStyle(.card)
            .galleryItemAccessibility(item)
            .accessibilityIdentifier(item.accessibilityIdentifier)
        }
    }
}

/// What kinds of fonts a collection holds, above them.
struct CollectionSummary: View {
    let text: LocalizedStringResource

    var body: some View {
        Text(text)
            .font(.callout)
            // The system's secondary gray is 3.5:1 on white, short of the 4.5:1 text this size needs.
            .foregroundStyle(Color(.captionText))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("collectionSummary")
    }
}

/// The gallery's cards. Content rather than controls, so a plain fill instead of glass, with the
/// pointer lifting them on iPad and a press shrinking them slightly.
struct CardButtonStyle: ButtonStyle {
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(.fill.tertiary, in: shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.lift)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CardButtonStyle {
    static var card: CardButtonStyle { CardButtonStyle() }
}

private struct CaskCard: View {
    let cask: Cask
    let catalog: Catalog
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CaskSpecimen(cask: cask, catalog: catalog, size: 20, relativeTo: .title3, lineLimit: cask.glyphs ? 2 : 3)
            Spacer(minLength: 0)
            CardFooter(title: cask.name, status: installer.status(of: cask)) {
                PopularityRank(rank: cask.popularity)
            }
        }
    }
}

/// The name and a detail line under a card's specimen, with a checkmark once it's installed.
struct CardFooter<Detail: View>: View {
    let title: String
    var status: FontInstaller.Status?
    @ViewBuilder let detail: Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading) {
                // Three lines at accessibility sizes, where one cut "Atkinson Hyperlegible Next" to "Atkin…".
                Text(title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .accessibilityIdentifier("itemName")
                // Darker than the system's secondary gray, which is 3.3:1 on a card where a caption needs 4.5:1.
                detail
                    .font(.caption)
                    .foregroundStyle(Color(.captionText))
            }
            Spacer(minLength: 0)
            InstallBadge(status: status)
        }
    }
}

/// A cask's rank by popularity across Homebrew and Google Fonts, as "#12".
struct PopularityRank: View {
    let rank: Int?

    var body: some View {
        if let rank {
            // VoiceOver reads "#12" as "number 12", after the "Popularity" a font's page and a card's custom
            // content put before it. A longer label made the accessibility audit take the rank for clipped text.
            Text("#\(rank, format: .number)")
                .monospacedDigit()
        }
    }
}

/// A checkmark for an installed cask, or an arrow when it has an update. On a card it's the only sign of
/// either, so its colors are darker than the system's green and orange, which are about 2:1 on white
/// where an icon needs 3:1.
struct InstallBadge: View {
    let status: FontInstaller.Status?

    var body: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(.installedBadge))
                .accessibilityLabel("Installed")
        case .updateAvailable:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color(.updateBadge))
                .accessibilityLabel("Update available")
        default:
            EmptyView()
        }
    }
}

extension FontInstaller.Status {
    /// How VoiceOver reads the status as a gallery entry's value, or nil when there's nothing to say.
    var accessibilityValue: LocalizedStringResource? {
        switch self {
        case .available: nil
        case .downloading: "Downloading"
        case .installing: "Installing"
        case .installed: "Installed"
        case .updateAvailable: "Update available"
        case .updating: "Updating"
        case .uninstalling: "Uninstalling"
        case .builtIn: "Built into iOS"
        case .failed: "Install failed"
        }
    }
}

extension View {
    /// Names a gallery card or sample row after its font, for VoiceOver and Voice Control, and offers a cask's
    /// install or uninstall from there; see `caskActions(_:)`.
    func galleryItemAccessibility(_ item: GalleryItem) -> some View {
        modifier(GalleryItemAccessibility(item: item))
    }
}

/// What VoiceOver and Voice Control know a gallery entry by: its name, then whether it's installed, with its
/// style and rank a swipe away. Left to the link, VoiceOver read the whole sample line, "The quick brown fox
/// jumps over the lazy dog 0123456789" and its brackets, ahead of the name on every card.
private struct GalleryItemAccessibility: ViewModifier {
    let item: GalleryItem
    @Environment(FontInstaller.self) private var installer

    func body(content: Content) -> some View {
        switch item {
        case .cask(let cask): described(content).caskActions(cask)
        case .apple: described(content)
        }
    }

    private func described(_ content: Content) -> some View {
        content
            .accessibilityLabel(Text(item.name))
            .accessibilityValue(value)
            .accessibilityInputLabels([Text(item.name)])
            .accessibilityCustomContent(AccessibilityCustomContentKey("Design Style"), Text(item.style.name))
            .accessibilityCustomContent(AccessibilityCustomContentKey("Popularity"), popularity)
            .accessibilityCustomContent(AccessibilityCustomContentKey("Includes"), nerdFonts)
    }

    private var value: Text {
        switch item {
        case .cask(let cask): installer.status(of: cask).accessibilityValue.map { Text($0) } ?? Text(verbatim: "")
        case .apple(let family): Text(family.builtIn ? LocalizedStringKey("Built In") : "In Settings")
        }
    }

    private var popularity: Text? {
        guard case .cask(let cask) = item, let rank = cask.popularity else { return nil }
        return Text("#\(rank, format: .number)")
    }

    private var nerdFonts: Text? {
        guard case .cask(let cask) = item, cask.glyphs else { return nil }
        return Text("Nerd Fonts icons")
    }
}

/// The sample text in a cask's preview font, after a line in its own script for a font for another
/// script, and Nerd Fonts' icons under it for a patched cask.
struct CaskSpecimen: View {
    let cask: Cask
    let catalog: Catalog
    let lineLimit: Int?
    @ScaledMetric private var size: CGFloat

    init(cask: Cask, catalog: Catalog, size: CGFloat, relativeTo style: Font.TextStyle, lineLimit: Int?) {
        self.cask = cask
        self.catalog = catalog
        self.lineLimit = lineLimit
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    var body: some View {
        CaskSpecimenText(cask: cask, catalog: catalog, size: size, lineLimit: lineLimit)
    }
}

/// `CaskSpecimen` at a size given in points, rather than one that follows the text size.
struct CaskSpecimenText: View {
    let cask: Cask
    let catalog: Catalog
    let size: CGFloat
    let lineLimit: Int?

    var body: some View {
        let font = PreviewFonts.font(cask.previewFile, size: size)
        VStack(alignment: .leading, spacing: size / 4) {
            Text(cask.sample ?? catalog.sampleText)
                .font(font)
                .lineLimit(lineLimit)
                .accessibilityIdentifier("specimen")
            if cask.glyphs {
                Text(catalog.glyphSample)
                    .font(font)
                    .lineLimit(1)
                    .accessibilityLabel("Nerd Fonts icons")
            }
        }
    }
}
