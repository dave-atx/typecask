import AppIntents
import SwiftUI

/// A font's page, laid out as a type specimen: a masthead of its letters, name, Install and facts, then, from the
/// full fonts, each style, passages at reading sizes, the character set and the languages it covers.
/// The full fonts are the installed copies, or the cask's On-Demand Resources tag downloaded when asked, as Try It
/// Out does; until then the page has only the preview's few dozen glyphs.
struct CaskDetailView: View {
    let cask: Cask
    let catalog: Catalog
    @Environment(FontInstaller.self) private var installer
    /// Whether the samples draw a coding face's ligatures. Try It Out has the switch for them.
    private let ligatures = true
    /// The full fonts, once installed or asked for, which Try It Out shares.
    @State private var loader: TryOutLoader?
    /// Try It Out, while it's open, and what it opened to.
    @State private var tryOut: TryOutStart?
    @Namespace private var tryOutNamespace
    /// Whether the page's Install and Try It Out are on screen; once they aren't, the navigation bar has them.
    @State private var actionsVisible = true
    /// Whether the full specimen was asked for, so VoiceOver hears when it's ready; an installed cask's loads unasked.
    @State private var announcesSpecimen = false
    /// Where each section starts, relative to the top of the scroll view, for the index to mark the one in view.
    @State private var offsets: [PageSection: CGFloat] = [:]
    /// The page's width, index included, which decides whether there's room for the index.
    @State private var width: CGFloat = 0
    private var size = SpecimenSize()

    init(cask: Cask, catalog: Catalog) {
        self.cask = cask
        self.catalog = catalog
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                page
                // Beside the page where there's room for it, as on an iPad in landscape or with the sidebar hidden. A
                // narrower page keeps its width, since the character grid and passages need it more.
                if width >= 760 {
                    SectionIndex(sections: sections, current: currentSection) { section in
                        withAnimation { proxy.scrollTo(section, anchor: .top) }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // The full specimen asked for from the actions row arrives below the fold, so the page goes to it.
            .onChange(of: specimen != nil) { _, loaded in
                if loaded, announcesSpecimen {
                    withAnimation { proxy.scrollTo(PageSection.styles, anchor: .top) }
                }
            }
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

    private var page: some View {
        ScrollView {
            // Lazy for the character grid's pinned header (see SpecimenCharacters).
            LazyVStack(alignment: .leading, spacing: 32, pinnedViews: .sectionHeaders) {
                VStack(alignment: .leading, spacing: 20) {
                    SpecimenMasthead(cask: cask, catalog: catalog)
                    CaskActions(cask: cask, fullSpecimen: fullSpecimenAction)
                        .onScrollVisibilityChange(threshold: 0.3) { visible in
                            withAnimation { actionsVisible = visible }
                        }
                    SpecimenFacts(cask: cask)
                }
                if let nerdVersion = catalog.nerdVersions[cask.token] {
                    anchor(.nerdFont)
                    NerdFontVersion(cask: nerdVersion, catalog: catalog)
                }
                if let specimen {
                    anchor(.styles)
                    SpecimenStyles(specimen: specimen, sample: sample, ligatures: ligatures)
                    anchor(.features)
                    SpecimenFeatures(specimen: specimen)
                    anchor(.setting)
                    SpecimenSetting(specimen: specimen, ligatures: ligatures)
                    anchor(.characters)
                    SpecimenCharacters(specimen: specimen)
                    anchor(.languages)
                    SpecimenLanguages(specimen: specimen)
                } else if loader != nil {
                    // Its download's progress, or why it failed, once asked for from the actions row.
                    FullSpecimenPrompt(cask: cask, loader: loader) { showFullSpecimen() }
                }
                if let description = cask.description {
                    anchor(.about)
                    SpecimenSection("About") {
                        CaskDescription(markdown: description, designers: cask.descriptionBy ?? [])
                    }
                }
                // Every cask in the catalog has a license; build-catalog.py skips those without one.
                anchor(.license)
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
    }

    /// Where a section starts, for the index to scroll to and to tell which section is in view. A view of its own
    /// rather than a modifier on the section, which would break the character grid's pinned header.
    private func anchor(_ section: PageSection) -> some View {
        Color.clear
            .frame(height: 0)
            .id(section)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { offsets[section] = $0 }
    }

    /// The sections this page has, in order, for the index beside it.
    private var sections: [PageSection] {
        var sections: [PageSection] = catalog.nerdVersions[cask.token] == nil ? [] : [.nerdFont]
        if let specimen {
            sections.append(.styles)
            if !specimen.features.isEmpty {
                sections.append(.features)
            }
            if TryOutText.draws(SpecimenSetting.paragraphs.joined(), specimen.covered) {
                sections.append(.setting)
            }
            sections.append(.characters)
            if !specimen.languages.isEmpty {
                sections.append(.languages)
            }
        }
        if cask.description != nil {
            sections.append(.about)
        }
        return sections + [.license]
    }

    /// The last section whose start has scrolled to near the top, or the first while none has.
    private var currentSection: PageSection? {
        sections.last { (offsets[$0] ?? .infinity) <= 120 } ?? sections.first
    }

    /// Whether the actions row offers the full specimen: for a cask this build carries, until it's asked for. An
    /// installed cask's loads by itself.
    private var canShowFullSpecimen: Bool {
        cask.isBundled && loader == nil && installer.status(of: cask) != .builtIn
    }

    private var fullSpecimenAction: (() -> Void)? {
        guard canShowFullSpecimen else { return nil }
        return { showFullSpecimen() }
    }

    private func showFullSpecimen() {
        announcesSpecimen = true
        loadSpecimen()
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
