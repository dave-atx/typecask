import AppIntents
import SwiftUI

/// A font's page, laid out as a type specimen: a masthead of its letters, name, Install and facts, a type tester,
/// then, from the full fonts, each style, passages at reading sizes, the character set and the languages it covers.
/// The full fonts are the installed copies, or the cask's On-Demand Resources tag downloaded when asked, as Try It
/// Out does; until then the page has only the preview's few dozen glyphs.
struct CaskDetailView: View {
    let cask: Cask
    let catalog: Catalog
    @Environment(FontInstaller.self) private var installer
    /// Whether the samples draw a coding face's ligatures, which the page can turn off to show what they join.
    @State private var ligatures = true
    /// The full fonts, once installed or asked for.
    @State private var loader: TryOutLoader?

    var body: some View {
        ScrollView {
            // Lazy for the character grid's pinned header (see SpecimenCharacters).
            LazyVStack(alignment: .leading, spacing: 32, pinnedViews: .sectionHeaders) {
                VStack(alignment: .leading, spacing: 20) {
                    SpecimenMasthead(cask: cask, catalog: catalog)
                    CaskActions(cask: cask)
                    SpecimenFacts(cask: cask)
                }
                if let nerdVersion = catalog.nerdVersions[cask.token] {
                    NerdFontVersion(cask: nerdVersion, catalog: catalog)
                }
                SpecimenSection("Tester") {
                    TypeTester(cask: cask, catalog: catalog, ligatures: $ligatures, specimen: specimen)
                }
                if let specimen {
                    SpecimenStyles(specimen: specimen, sample: sample, ligatures: ligatures)
                    SpecimenFeatures(specimen: specimen)
                    SpecimenSetting(specimen: specimen, ligatures: ligatures)
                    SpecimenCharacters(specimen: specimen)
                    SpecimenLanguages(specimen: specimen)
                } else if cask.isBundled || installer.status(of: cask).isInstalled {
                    FullSpecimenPrompt(cask: cask, loader: loader, start: loadSpecimen)
                }
                if let description = cask.description {
                    SpecimenSection("About") {
                        CaskDescription(markdown: description, designers: cask.designers ?? [])
                    }
                }
                // Every cask in the catalog has a license; build-catalog.py skips those without one.
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    DisclosureGroup("License") {
                        LicenseText(token: cask.token)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(cask.name)
        .navigationBarTitleDisplayMode(.inline)
        // An installed cask's fonts are on the device already, so its full specimen needs no asking.
        .task(id: installer.status(of: cask).isInstalled) {
            if installer.status(of: cask).isInstalled, specimen == nil {
                loadSpecimen()
            }
        }
        .promptsForReview(after: cask)
        // So Siri and Apple Intelligence take "this" to mean this font, as in "install this".
        .appEntityIdentifier(EntityIdentifier(for: FontEntity.self, identifier: cask.token))
        .focusedSceneValue(\.cask, cask)
        .onAppear { QuickActions.remember(cask) }
    }

    private var sample: String { cask.sample ?? catalog.sampleText }

    private var specimen: Specimen? {
        guard case .loaded(let loaded) = loader?.phase else { return nil }
        return loaded.specimen
    }

    private func loadSpecimen() {
        let loader = TryOutLoader()
        self.loader = loader
        let installed = installer.status(of: cask).isInstalled
        Task { await loader.load(cask, installed: installed, sample: sample) }
    }
}

/// Turns a coding face's ligatures off and on in the samples above, so you can see -> and != become arrows and
/// signs and back.
struct LigaturesToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("Ligatures")
            Text("Joins sequences like -> and != into single symbols, in editors that support them.")
                // Darker than the system's secondary gray, which is 3.5:1 on white where text needs 4.5:1.
                .foregroundStyle(Color(.captionText))
        }
        .accessibilityIdentifier("ligatures")
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
struct LicenseText: View {
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
/// Identified by the cask's token, so the UI tests can tell a page's two sets apart, the plain cask's and its
/// Nerd Font version's, which share their buttons' identifiers.
struct CaskActions: View {
    let cask: Cask
    /// Whether these are a paired page's Nerd Font version's, which leave out the homepage and name the
    /// version to VoiceOver, so the page's two Install buttons don't sound alike.
    var isNerdVersion = false
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        // The same spacing as the page's own, which these were part of before they were grouped.
        VStack(alignment: .leading, spacing: 24) {
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("controls.\(cask.token)")
    }

    @ViewBuilder private var content: some View {
        // In a row when they fit, stacked when they don't, as on a narrow screen at an accessibility text
        // size, where a row broke every label mid-word. Stacking keeps the labels, which icons alone wouldn't.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { buttons }
            VStack(alignment: .leading, spacing: 12) { buttons }
        }
        if !cask.isBundled, installer.status(of: cask) != .builtIn {
            // The release left this cask's fonts out (see README), or this is a debug build carrying a few
            // casks', so there is no On-Demand Resources tag to download, and offering Install would just fail.
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
        // An installed cask can be removed even when this build no longer ships it, and one iOS has built in
        // says so whatever the build carries.
        let status = installer.status(of: cask)
        if cask.isBundled || status.isInstalled || status == .builtIn {
            InstallControl(cask: cask, isNerdVersion: isNerdVersion)
        }
        if (cask.isBundled || status.isInstalled) && status != .builtIn {
            TryItOutButton(cask: cask)
        }
        if !isNerdVersion {
            Link(destination: cask.homepage) {
                Label("Homepage", systemImage: "safari")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("homepage")
        }
    }
}

/// The control for the cask's status. When an install or uninstall finishes, VoiceOver's focus moves to
/// whatever replaced the button it was on, rather than being lost with that button.
private struct InstallControl: View {
    let cask: Cask
    var isNerdVersion = false
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
                Task { await installer.run(.update, on: cask) }
            }
            .buttonStyle(.glassProminent)
            .disabled(!cask.isBundled)
            .accessibilityLabel(isNerdVersion ? "Update Nerd Font" : "Update")
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
            Task { await installer.run(.uninstall, on: cask) }
        }
        .buttonStyle(.glass)
        .accessibilityLabel(isNerdVersion ? "Uninstall Nerd Font" : "Uninstall")
        .accessibilityFocused($focus, equals: .uninstall)
        .accessibilityIdentifier("uninstall")
    }

    private func installButton(_ title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "arrow.down.circle") {
            Task { await installer.run(.install, on: cask) }
        }
        .buttonStyle(.glassProminent)
        // The visible title, or which version it installs on a paired page. Try Again stays as it is.
        .accessibilityLabel(isNerdVersion && title == "Install" ? "Install Nerd Font" : title)
        .accessibilityFocused($focus, equals: .install)
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
