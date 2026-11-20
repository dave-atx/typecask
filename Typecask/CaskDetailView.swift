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
    /// The full fonts, once installed or asked for, which Try It Out shares.
    @State private var loader: TryOutLoader?
    /// Try It Out, while it's open, and what it opened to.
    @State private var tryOut: TryOutStart?
    @Namespace private var tryOutNamespace
    /// Whether the page's Install and Try It Out are on screen; once they aren't, the navigation bar has them.
    @State private var actionsVisible = true
    /// Whether the full specimen was asked for, so VoiceOver hears when it's ready; an installed cask's loads unasked.
    @State private var announcesSpecimen = false
    private var size = SpecimenSize()

    init(cask: Cask, catalog: Catalog) {
        self.cask = cask
        self.catalog = catalog
    }

    var body: some View {
        ScrollView {
            // Lazy for the character grid's pinned header (see SpecimenCharacters).
            LazyVStack(alignment: .leading, spacing: 32, pinnedViews: .sectionHeaders) {
                VStack(alignment: .leading, spacing: 20) {
                    SpecimenMasthead(cask: cask, catalog: catalog)
                    CaskActions(cask: cask)
                        .onScrollVisibilityChange(threshold: 0.3) { visible in
                            withAnimation { actionsVisible = visible }
                        }
                    SpecimenFacts(cask: cask)
                }
                if let nerdVersion = catalog.nerdVersions[cask.token] {
                    NerdFontVersion(cask: nerdVersion, catalog: catalog)
                }
                SpecimenSection("Tester") {
                    TypeTester(cask: cask, catalog: catalog, ligatures: $ligatures)
                }
                if let specimen {
                    SpecimenStyles(specimen: specimen, sample: sample, ligatures: ligatures)
                    SpecimenFeatures(specimen: specimen)
                    SpecimenSetting(specimen: specimen, ligatures: ligatures)
                    SpecimenCharacters(specimen: specimen)
                    SpecimenLanguages(specimen: specimen)
                } else if cask.isBundled || installer.status(of: cask).isInstalled {
                    FullSpecimenPrompt(cask: cask, loader: loader) {
                        announcesSpecimen = true
                        loadSpecimen()
                    }
                }
                if let description = cask.description {
                    SpecimenSection("About") {
                        CaskDescription(markdown: description, designers: cask.descriptionBy ?? [])
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PageShareLink(url: SiteLink.cask(cask), title: cask.name)
            }
            if !actionsVisible {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PageToolbarActions(cask: cask)
                }
                // Not into the overflow menu on a narrow bar, as on iPhone Duo's outer display.
                .visibilityPriority(.high)
            }
        }
        // The bar holds Install and Try It Out while their own buttons are scrolled away, so it mustn't minimize
        // on scroll, which on iPhone Duo's outer display hid them until scrolling back up.
        .toolbarMinimizationBehavior(.never, for: .navigationBar)
        // The sample, each style and feature, the character shown large and the Try It Out button all open the
        // editor, set up for what was tapped, zooming from it.
        .environment(\.tryOut, canTryOut ? TryOutOpener(token: cask.token, namespace: tryOutNamespace,
                                                        open: openTryOut) : nil)
        .sheet(item: $tryOut) { start in
            if let loader {
                TryItOutView(fonts: .cask(cask), loader: loader, start: start)
                    // A page on iPad, not a form sheet: an editor wants the room.
                    .presentationSizing(.page)
                    .navigationTransition(.zoom(sourceID: start.source, in: tryOutNamespace))
            }
        }
        // An installed cask's fonts are on the device already, so its full specimen needs no asking.
        .task(id: installer.status(of: cask).isInstalled) {
            if installer.status(of: cask).isInstalled, loader == nil {
                loadSpecimen()
            }
        }
        .onChange(of: specimen != nil) { _, loaded in
            if loaded, announcesSpecimen {
                AccessibilityNotification.Announcement(String(localized: "Full specimen loaded.")).post()
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

    /// Whether Try It Out can open: as for its button, a cask this build carries or that's installed, and not one iOS
    /// has built in.
    private var canTryOut: Bool {
        let status = installer.status(of: cask)
        return (cask.isBundled || status.isInstalled) && status != .builtIn
    }

    /// Opens Try It Out at the page's sample size, starting the download the page's specimen shares if it hasn't.
    private func openTryOut(_ start: TryOutStart) {
        if loader == nil {
            loadSpecimen()
        }
        var start = start
        start.size = start.size ?? size.wrappedValue
        tryOut = start
    }

    private func loadSpecimen() {
        let loader = TryOutLoader()
        self.loader = loader
        let installed = installer.status(of: cask).isInstalled
        Task { await loader.load(cask, installed: installed, sample: sample) }
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
        // In rows, each button onto the next where it doesn't fit, rather than squeezed: at an accessibility text
        // size a single row broke every label mid-word. Wrapping keeps the labels, which icons alone wouldn't, and
        // with Install on Mac there are four, which no iPhone fits in one row.
        WrappingRows(spacing: 12) { buttons }
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
        if cask.isBundled {
            // The share sheet, for AirDrop to a Mac, where Font Book installs the fonts: iOS can't install them there.
            ShareLink(item: FontArchive(cask, tag: cask.pack ?? cask.token), preview: SharePreview(cask.name)) {
                Label("Install on Mac", systemImage: "laptopcomputer.and.arrow.down")
            }
            .buttonStyle(.glass)
            .accessibilityLabel(isNerdVersion ? "Install Nerd Font on Mac" : "Install on Mac")
            .accessibilityIdentifier("installOnMac")
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
