import SwiftUI

/// Font Book's sample view: one specimen line per cask, set large enough to judge the face by.
struct CaskSampleList: View {
    let casks: [Cask]
    let sampleText: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(casks) { cask in
                NavigationLink(value: cask) {
                    CaskSampleRow(cask: cask, sampleText: sampleText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(cask.token)
                Divider()
            }
        }
    }
}

private struct CaskSampleRow: View {
    let cask: Cask
    let sampleText: String
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(cask.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if installer.status(of: cask).isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Installed")
                }
                Spacer(minLength: 0)
                Text("\(cask.installs, format: .number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(sampleText)
                .font(.custom(cask.previewFontName, size: 64, relativeTo: .largeTitle))
                // Two lines of a 64pt specimen: one line truncates after about "The quick".
                .lineLimit(2)
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}
