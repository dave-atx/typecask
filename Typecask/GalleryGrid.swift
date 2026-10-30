import SwiftUI

/// Font Book's grid: one card per font, each set in its own face.
struct GalleryGrid: View {
    let items: [GalleryItem]
    let catalog: Catalog

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
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
                .accessibilityIdentifier(item.accessibilityIdentifier)
            }
        }
        .padding()
    }
}

/// The gallery's cards. Content rather than controls, so a plain fill instead of glass, with the
/// pointer lifting them on iPad and a press shrinking them slightly.
struct CardButtonStyle: ButtonStyle {
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(.fill.tertiary, in: shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.lift)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
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

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text("#\(rank, format: .number)")
                .monospacedDigit()
                .accessibilityLabel(Text("Popularity rank \(rank, format: .number)"))
        }
    }
}

/// A checkmark for an installed cask, or an arrow when it has an update.
struct InstallBadge: View {
    let status: FontInstaller.Status?

    var body: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Installed")
        case .updateAvailable:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Update available")
        default:
            EmptyView()
        }
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
        let font = PreviewFonts.font(cask.previewFile, size: size)
        VStack(alignment: .leading, spacing: size / 4) {
            Text(cask.sample ?? catalog.sampleText)
                .font(font)
                .lineLimit(lineLimit)
            if cask.glyphs {
                Text(catalog.glyphSample)
                    .font(font)
                    .lineLimit(1)
                    .accessibilityLabel("Nerd Fonts icons")
            }
        }
    }
}
