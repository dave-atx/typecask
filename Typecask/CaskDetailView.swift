import SwiftUI

struct CaskDetailView: View {
    let cask: Cask
    let sampleText: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(sampleText)
                    .font(.custom(cask.previewFontName, size: 40, relativeTo: .largeTitle))
                Text(sampleText)
                    .font(.custom(cask.previewFontName, size: 17, relativeTo: .body))
                InstallButton(cask: cask)
                VStack(spacing: 8) {
                    LabeledContent("Fonts", value: cask.fonts, format: .number)
                    LabeledContent("Download", value: cask.bytes, format: .byteCount(style: .file))
                    LabeledContent("Installs, last 365 days", value: cask.installs, format: .number)
                }
                Link("Homepage", destination: cask.homepage)
                if let license = cask.license {
                    DisclosureGroup("License") {
                        Text(license)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(cask.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InstallButton: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        if cask.isBundled {
            status
        } else {
            // Built with scripts/build-catalog.py --fonts, which writes font assets for a few casks only.
            // There is no On-Demand Resources tag to download, so offering Install would just fail.
            Label("Fonts not included in this build", systemImage: "arrow.down.circle.dotted")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch installer.status(of: cask) {
        case .available:
            button("Install")
        case .downloading(let fractionCompleted):
            ProgressView("Downloading…", value: fractionCompleted)
        case .installing:
            ProgressView("Installing…")
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading) {
                button("Try Again")
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func button(_ title: LocalizedStringKey) -> some View {
        Button(title) {
            Task { await installer.install(cask) }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("install")
    }
}
