import SwiftUI

struct CaskDetailView: View {
    let cask: Cask
    let catalog: Catalog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    CaskSpecimen(cask: cask, catalog: catalog, size: 40, relativeTo: .largeTitle, lineLimit: nil)
                    CaskSpecimen(cask: cask, catalog: catalog, size: 17, relativeTo: .body, lineLimit: nil)
                }
                CaskActions(cask: cask)
                if let description = cask.description {
                    CaskDescription(markdown: description, designers: cask.designers ?? [])
                }
                VStack(spacing: 8) {
                    if let version = cask.version {
                        LabeledContent("Version", value: version)
                    }
                    if let designers = cask.designers, !designers.isEmpty {
                        LabeledContent("Designer") { Text(designers, format: .list(type: .and)) }
                    }
                    LabeledContent("Fonts", value: cask.fonts, format: .number)
                    LabeledContent("Design Style") { Text(cask.style.name) }
                    LabeledContent("Download", value: cask.bytes, format: .byteCount(style: .file))
                    LabeledContent("Installs, last 365 days", value: cask.installs, format: .number)
                }
                if let license = cask.license {
                    DisclosureGroup("License") {
                        Text(license)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(cask.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Google Fonts' description, which comes as paragraphs of Markdown with links. Often the designer's
/// own words, in the first person, so it reads as a quote attributed to them.
private struct CaskDescription: View {
    let markdown: String
    let designers: [String]

    var body: some View {
        // Inline-only parsing keeps the blank lines between paragraphs, which full parsing would merge.
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        VStack(alignment: .leading, spacing: 10) {
            Text((try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown))
                .font(.callout)
                .textSelection(.enabled)
            if !designers.isEmpty {
                Text("— \(designers.formatted(.list(type: .and))), on Google Fonts")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.tint.opacity(0.6))
                .frame(width: 3)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Install or Uninstall, and the homepage, as glass buttons. Not in a GlassEffectContainer: inside one,
/// the buttons dropped out of the accessibility tree once the cask was installed, Uninstall included.
private struct CaskActions: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        HStack(spacing: 12) {
            // An installed cask can be removed even when this build no longer ships it.
            if cask.isBundled || installer.status(of: cask).isInstalled {
                InstallControl(cask: cask)
            }
            Link(destination: cask.homepage) {
                Label("Homepage", systemImage: "safari")
            }
            .buttonStyle(.glass)
        }
        if !cask.isBundled {
            // The release left this cask's fonts out (see README), so there is no On-Demand Resources
            // tag to download, and offering Install would just fail.
            Label("Fonts not included in this build", systemImage: "arrow.down.circle.dotted")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if case .failed(let message) = installer.status(of: cask) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

private struct InstallControl: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        switch installer.status(of: cask) {
        case .available:
            installButton("Install")
        case .failed:
            installButton("Try Again")
        case .downloading(let fractionCompleted):
            ProgressView("Downloading…", value: fractionCompleted)
                .frame(maxWidth: 220)
        case .installing:
            ProgressView("Installing…")
        case .uninstalling:
            ProgressView("Uninstalling…")
        case .updating:
            ProgressView("Updating…")
        case .updateAvailable:
            Button("Update", systemImage: "arrow.down.circle") {
                Task { await installer.update(cask) }
            }
            .buttonStyle(.glassProminent)
            .disabled(!cask.isBundled)
            .accessibilityIdentifier("update")
            uninstallButton
        case .builtIn:
            Label("Built into iOS", systemImage: "checkmark.seal")
                .foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            uninstallButton
        }
    }

    private var uninstallButton: some View {
        Button("Uninstall", systemImage: "trash", role: .destructive) {
            Task { await installer.uninstall(cask) }
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("uninstall")
    }

    private func installButton(_ title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "arrow.down.circle") {
            Task { await installer.install(cask) }
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("install")
    }
}

#Preview {
    let catalog = Catalog.bundled
    let cask = catalog.casks.first { $0.token == "font-aboreto" } ?? catalog.casks[0]
    NavigationStack {
        CaskDetailView(cask: cask, catalog: catalog)
    }
    .environment(FontInstaller())
}
