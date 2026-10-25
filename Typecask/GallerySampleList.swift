import SwiftUI

/// Font Book's sample view: one specimen per font, set large enough to judge the face by.
struct GallerySampleList: View {
    let items: [GalleryItem]
    let catalog: Catalog

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    switch item {
                    case .cask(let cask):
                        CaskSampleRow(cask: cask, catalog: catalog)
                    case .apple(let family):
                        AppleFontSampleRow(family: family, sampleText: catalog.sampleText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(item.accessibilityIdentifier)
                Divider()
            }
        }
    }
}

/// A sample row's name line: the name, a checkmark once installed, and a detail at the trailing edge.
struct SampleRowHeader<Detail: View>: View {
    let title: String
    var status: FontInstaller.Status?
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            InstallBadge(status: status)
                .font(.caption)
            Spacer(minLength: 0)
            detail
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Padding and hit area shared by every sample row.
extension View {
    func sampleRowLayout() -> some View {
        padding(.horizontal)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .hoverEffect(.highlight)
    }
}

private struct CaskSampleRow: View {
    let cask: Cask
    let catalog: Catalog
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SampleRowHeader(title: cask.name, status: installer.status(of: cask)) {
                Text(cask.installs, format: .number)
                    .monospacedDigit()
            }
            // Two lines of a 64pt specimen: one line truncates after about "The quick".
            CaskSpecimen(cask: cask, catalog: catalog, size: 64, relativeTo: .largeTitle, lineLimit: 2)
        }
        .sampleRowLayout()
    }
}
