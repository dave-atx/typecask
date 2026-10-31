import SwiftUI

struct CaskDetailView: View {
    let cask: Cask
    let catalog: Catalog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    CaskSpecimen(cask: cask, catalog: catalog, size: 40, relativeTo: .largeTitle, lineLimit: nil)
                    // The same line again, smaller, which VoiceOver needn't read twice.
                    CaskSpecimen(cask: cask, catalog: catalog, size: 17, relativeTo: .body, lineLimit: nil)
                        .accessibilityHidden(true)
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
                    if let popularity = cask.popularity {
                        LabeledContent("Popularity") { PopularityRank(rank: popularity) }
                    }
                }
                .labeledContentStyle(.detailRow)
                // Every cask in the catalog has a license; build-catalog.py skips those without one.
                DisclosureGroup("License") {
                    LicenseText(token: cask.token)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
        .navigationTitle(cask.name)
        .navigationBarTitleDisplayMode(.inline)
        .promptsForReview(after: cask)
        .announcesInstalls(of: cask)
    }
}

/// A detail page's facts: label and value side by side, or the value under its label at accessibility sizes,
/// where side by side hyphenated "Download" and wrapped a list of designers a word to a line.
struct DetailRowStyle: LabeledContentStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                configuration.label
                configuration.content
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            LabeledContent(configuration)
        }
    }
}

extension LabeledContentStyle where Self == DetailRowStyle {
    static var detailRow: DetailRowStyle { DetailRowStyle() }
}

/// A cask's license, read when the disclosure group first opens: a collapsed group doesn't build its
/// content, so the detail page never pays for unpacking the licenses unless someone asks.
private struct LicenseText: View {
    let token: String
    @State private var text: AttributedString?
    @State private var loaded = false

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("licenseText")
            } else if loaded {
                Text("The license couldn't be read.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: token) {
            text = await Licenses.text(for: token).map(Self.linkified)
            loaded = true
        }
    }

    /// The license with its URLs as links, like the OFL's FAQ at https://scripts.sil.org/OFL.
    private static func linkified(_ string: String) -> AttributedString {
        var attributed = AttributedString(string)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        for match in detector.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let url = match.url,
                  let range = Range(match.range, in: string),
                  let start = AttributedString.Index(range.lowerBound, within: attributed),
                  let end = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[start..<end].link = url
        }
        return attributed
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
        // In a row when they fit, stacked when they don't, as on a narrow screen at an accessibility text
        // size, where a row broke every label mid-word. Stacking keeps the labels, which icons alone wouldn't.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { buttons }
            VStack(alignment: .leading, spacing: 12) { buttons }
        }
        if !cask.isBundled {
            // The release left this cask's fonts out (see README), so there is no On-Demand Resources
            // tag to download, and offering Install would just fail.
            Label("Fonts not included in this build", systemImage: "arrow.down.circle.dotted")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if case .failed(let message) = installer.status(of: cask) {
            // Red on the icon alone: red text is 3.5:1 on white, short of the 4.5:1 text needs.
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        // An installed cask can be removed even when this build no longer ships it.
        if cask.isBundled || installer.status(of: cask).isInstalled {
            InstallControl(cask: cask)
        }
        Link(destination: cask.homepage) {
            Label("Homepage", systemImage: "safari")
        }
        .buttonStyle(.glass)
    }
}

/// The control for the cask's status. When an install or uninstall finishes, VoiceOver's focus moves to
/// whatever replaced the button it was on, rather than being lost with that button.
private struct InstallControl: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer
    @AccessibilityFocusState private var focus: Control?

    private enum Control: Hashable {
        case install
        case uninstall
    }

    var body: some View {
        content
            .onChange(of: installer.status(of: cask)) { old, new in
                guard old.isBusy else { return }
                switch new {
                case .installed: focus = .uninstall
                case .available, .failed: focus = .install
                default: break
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch installer.status(of: cask) {
        case .available:
            installButton("Install")
        case .failed:
            installButton("Try Again")
        case .downloading:
            ProgressView("Downloading…", value: installer.progress(of: cask))
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
            // Green on the icon alone: green text is about 2:1 on white.
            Label {
                Text("Installed")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(.installedBadge))
            }
            uninstallButton
        }
    }

    private var uninstallButton: some View {
        Button("Uninstall", systemImage: "trash", role: .destructive) {
            Task { await installer.uninstall(cask) }
        }
        .buttonStyle(.glass)
        .accessibilityFocused($focus, equals: .uninstall)
        .accessibilityIdentifier("uninstall")
    }

    private func installButton(_ title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "arrow.down.circle") {
            Task { await installer.install(cask) }
        }
        .buttonStyle(.glassProminent)
        .accessibilityFocused($focus, equals: .install)
        .accessibilityIdentifier("install")
    }
}

extension View {
    /// Tells VoiceOver how an install, update or uninstall of the cask ended; see `InstallAnnouncements`.
    func announcesInstalls(of cask: Cask) -> some View {
        modifier(InstallAnnouncements(cask: cask))
    }
}

/// Announces the end of an install, update or uninstall, which otherwise only swaps one button for another,
/// and an error that otherwise only appears as text. Only an action finishing, not a refresh finding the cask
/// already installed. High priority, so VoiceOver restoring focus after the consent sheet doesn't cut it off.
private struct InstallAnnouncements: ViewModifier {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer
    /// Whether the install under way is an update, which goes through downloading and installing like any other.
    @State private var isUpdating = false

    func body(content: Content) -> some View {
        content
            .onChange(of: installer.status(of: cask)) { old, new in
                if new == .updating {
                    isUpdating = true
                }
                guard let announcement = announcement(from: old, to: new) else { return }
                if !new.isBusy {
                    isUpdating = false
                }
                var text = AttributedString(localized: announcement)
                text.accessibilitySpeechAnnouncementPriority = .high
                AccessibilityNotification.Announcement(text).post()
            }
    }

    private func announcement(from old: FontInstaller.Status,
                              to new: FontInstaller.Status) -> LocalizedStringResource? {
        let name = cask.name
        return switch (old, new) {
        case (.installing, .installed): isUpdating ? "\(name) updated" : "\(name) installed"
        // An update removes the old fonts before installing the new, so declining it leaves neither.
        case (.installing, .available):
            isUpdating ? "Update cancelled. \(name) is no longer installed." : "Install cancelled"
        case (.uninstalling, .available): "\(name) uninstalled"
        case (.uninstalling, .failed(let message)): "Couldn't uninstall \(name). \(message)"
        case (_, .failed(let message)) where old.isBusy:
            isUpdating ? "Couldn't update \(name). \(message)" : "Couldn't install \(name). \(message)"
        default: nil
        }
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

#if DEBUG
#Preview("Installed") {
    let catalog = Catalog.bundled
    let cask = catalog.casks.first { $0.token == "font-aboreto" } ?? catalog.casks[0]
    NavigationStack {
        CaskDetailView(cask: cask, catalog: catalog)
    }
    .environment(FontInstaller(previewing: .installed, for: cask))
}

#Preview("Installed, AX1") {
    let catalog = Catalog.bundled
    let cask = catalog.casks.first { $0.token == "font-aboreto" } ?? catalog.casks[0]
    NavigationStack {
        CaskDetailView(cask: cask, catalog: catalog)
    }
    .environment(FontInstaller(previewing: .installed, for: cask))
    .dynamicTypeSize(.accessibility1)
}
#endif
