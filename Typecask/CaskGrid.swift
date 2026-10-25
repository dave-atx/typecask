import SwiftUI

/// Font Book's grid: one card per cask, each set in its own face.
struct CaskGrid: View {
    let casks: [Cask]
    let sampleText: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
            ForEach(casks) { cask in
                NavigationLink(value: cask) {
                    CaskCard(cask: cask, sampleText: sampleText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(cask.token)
            }
        }
        .padding()
    }
}

private struct CaskCard: View {
    let cask: Cask
    let sampleText: String
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sampleText)
                .font(.custom(cask.previewFontName, size: 20, relativeTo: .title3))
                .lineLimit(3)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading) {
                    Text(cask.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(cask.installs, format: .number) installs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if installer.status(of: cask).isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Installed")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
    }
}
