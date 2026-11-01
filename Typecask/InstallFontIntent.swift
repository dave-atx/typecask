import AppIntents
import CoreSpotlight
import SwiftUI

/// Installs a cask from Shortcuts, Siri or Spotlight: "Install Lexend with Typecask", or "Install this font
/// with Typecask" on a font's page.
///
/// The app comes forward first. The system's consent sheet for installing fonts needs it on screen, and
/// the font's page, which it opens, shows the download as it goes. Shortcuts saved with this intent find
/// it by its type name, so don't rename it.
struct InstallFontIntent: AppIntent {
    static let title: LocalizedStringResource = "Install Font"
    static let description = IntentDescription(
        "Installs a font from Typecask, for every app that lets you pick a font."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)
    /// On-Demand Resources and Core Text's consent sheet both belong to the app itself.
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    /// Optional, so that with none given the font on screen is the one installed. Siri sends "install this
    /// font" to an app's own intent only through a phrase that names the app; there's no schema for it.
    @Parameter(title: "Font", requestValueDialog: "Which font?")
    var font: FontEntity?

    @Dependency private var installer: FontInstaller
    @Dependency private var gallery: GalleryModel

    static var parameterSummary: some ParameterSummary {
        Summary("Install \(\.$font)")
    }

    init() {}

    init(font: FontEntity) {
        self.font = font
    }

    /// Safe to run again from the top, as the system may: a cask that's installed by then is reported, not
    /// installed twice.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FontEntity> & ProvidesDialog & ShowsSnippetView {
        let font = try await chosenFont()
        guard let cask = Catalog.bundled.casks.first(where: { $0.token == font.id }) else {
            throw AppIntentError.Unrecoverable.entityNotFound
        }
        // A shortcut can launch the app, and until the launch's refresh is done every cask reads as available.
        await installer.refresh(Catalog.bundled.casks)
        switch installer.status(of: cask) {
        case .installed, .updateAvailable:
            return .result(value: font, dialog: "\(cask.name) is already installed.", view: FontSnippet(cask: cask))
        case .builtIn:
            return .result(value: font, dialog: "\(cask.name) is built into iOS, so every app already has it.",
                           view: FontSnippet(cask: cask))
        case let status where status.isBusy:
            throw InstallFontError.busy(cask.name)
        default:
            break
        }
        guard cask.isBundled else {
            throw InstallFontError.notIncluded(cask.name)
        }
        gallery.show(cask)
        await installer.install(cask)
        switch installer.status(of: cask) {
        case .installed:
            return .result(value: font, dialog: "Installed \(cask.name) for every app that lets you pick a font.",
                           view: FontSnippet(cask: cask))
        case .failed(let message):
            throw InstallFontError.failed(cask.name, message)
        default:
            // Declined at the consent sheet.
            throw InstallFontError.cancelled(cask.name)
        }
    }
}

extension InstallFontIntent {
    /// The font given, else the one whose page is showing, else whichever the person names when asked.
    @MainActor
    private func chosenFont() async throws -> FontEntity {
        if let font {
            return font
        }
        if let shown = gallery.shownCask {
            return FontEntity(shown)
        }
        return try await $font.requestValue("Which font?")
    }
}

/// The font's sample line under Siri's answer, so you can see you got the font you asked for and not one
/// with a similar name.
private struct FontSnippet: View {
    let cask: Cask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaskSpecimen(cask: cask, catalog: .bundled, size: 28, relativeTo: .title, lineLimit: 2)
            Text(cask.name)
                .font(.headline)
            Text(cask.style.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

/// Shows a font's page: "Show Lexend in Typecask", or a font picked in Spotlight.
@AppIntent(schema: .system.open)
struct OpenFontIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Font"
    static let description = IntentDescription("Shows a font's page in Typecask.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Font")
    var target: FontEntity

    @Dependency private var gallery: GalleryModel

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let cask = Catalog.bundled.casks.first(where: { $0.token == target.id }) else {
            throw AppIntentError.Unrecoverable.entityNotFound
        }
        gallery.show(cask)
        return .result()
    }
}

/// Searches the gallery: "Search Typecask for rounded".
@AppIntent(schema: .system.searchInApp)
struct SearchFontsIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Fonts"
    static let description = IntentDescription("Searches Typecask's fonts by name, or by what their descriptions say.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Search", requestValueDialog: "What would you like to search for?")
    var criteria: StringSearchCriteria

    @Dependency private var gallery: GalleryModel

    @MainActor
    func perform() async throws -> some IntentResult {
        gallery.search(criteria.term)
        return .result()
    }
}

nonisolated enum InstallFontError: Error, CustomLocalizedStringResourceConvertible {
    case notIncluded(String)
    case busy(String)
    case cancelled(String)
    case failed(String, String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notIncluded(let name): "This build of Typecask doesn't include \(name)'s fonts."
        case .busy(let name): "Typecask is already working on \(name). Try again once it's done."
        case .cancelled(let name): "\(name) wasn't installed."
        case .failed(let name, let message): "Couldn't install \(name). \(message)"
        }
    }
}

/// A cask, as Shortcuts, Siri and Spotlight know it.
struct FontEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Font"
    static let defaultQuery = FontEntityQuery()

    /// The cask's token, like font-lexend. Saved shortcuts store it, so it has to stay the token.
    let id: String
    @Property(title: "Name") var name: String
    private let style: LocalizedStringResource
    private let designers: [String]
    private let summary: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: style)
    }

    /// What Spotlight finds the font by: its name, its token, which Homebrew users know it by, its style and
    /// designers, and Google's description.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = name
        attributes.contentDescription = summary ?? String(localized: style)
        attributes.authorNames = designers
        attributes.keywords = [id, String(localized: style)]
        return attributes
    }

    @MainActor
    init(_ cask: Cask) {
        id = cask.token
        style = cask.style.name
        designers = cask.designers ?? []
        // Plain text, without the description's Markdown links.
        summary = cask.description.map { description in
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: description, options: options)).map { String($0.characters) }
                ?? description
        }
        name = cask.name
    }
}

nonisolated struct FontEntityQuery: EntityStringQuery, IndexedEntityQuery {
    /// How many of the most popular casks Siri and Shortcuts suggest. Each one becomes a spoken phrase, out
    /// of about a thousand an app gets per language; "Install a font" still reaches the rest by name.
    private static let suggestions = 200
    private static let matchLimit = 50

    func entities(for identifiers: [FontEntity.ID]) async throws -> [FontEntity] {
        let wanted = Set(identifiers)
        return await MainActor.run {
            Catalog.bundled.casks.filter { wanted.contains($0.token) }.map(FontEntity.init)
        }
    }

    /// Casks whose name or token holds every word of `string`, the name's exact match first, so "Lexend"
    /// puts Lexend ahead of Lexend Deca, then by popularity. "Font" is dropped, as in "the Lexend font".
    func entities(matching string: String) async throws -> [FontEntity] {
        let words = GalleryModel.fold(string).split(whereSeparator: \.isWhitespace)
            .filter { $0 != "font" && $0 != "fonts" }
        guard !words.isEmpty else { return [] }
        let query = words.joined(separator: " ")
        return await MainActor.run {
            Catalog.bundled.casks
                .filter { cask in
                    let key = GalleryModel.fold("\(cask.name) \(cask.token)")
                    return words.allSatisfy { key.contains($0) }
                }
                .sorted { lhs, rhs in
                    let lhsExact = GalleryModel.fold(lhs.name) == query, rhsExact = GalleryModel.fold(rhs.name) == query
                    if lhsExact != rhsExact {
                        return lhsExact
                    }
                    return (lhs.popularity ?? .max, lhs.token) < (rhs.popularity ?? .max, rhs.token)
                }
                .prefix(Self.matchLimit)
                .map(FontEntity.init)
        }
    }

    func reindexEntities(for identifiers: [FontEntity.ID],
                         indexDescription: CSSearchableIndexDescription) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities(for: identifiers))
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await FontSpotlight.index()
    }

    func suggestedEntities() async throws -> [FontEntity] {
        await MainActor.run {
            Catalog.bundled.casks
                .compactMap { cask in cask.popularity.map { (rank: $0, cask: cask) } }
                .sorted { $0.rank < $1.rank }
                .prefix(Self.suggestions)
                .map { FontEntity($0.cask) }
        }
    }
}

nonisolated struct TypecaskShortcuts: AppShortcutsProvider {
    // Siri and saved shortcuts depend on these phrases: add to them rather than reword them.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: InstallFontIntent(),
            phrases: [
                "Install \(\.$font) with \(.applicationName)",
                "Install a font with \(.applicationName)",
                "Install this font with \(.applicationName)",
                "Install this with \(.applicationName)"
            ],
            shortTitle: "Install Font",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: OpenFontIntent(),
            phrases: [
                "Show \(\.$target) in \(.applicationName)",
                "Open \(\.$target) in \(.applicationName)",
                "Show a font in \(.applicationName)"
            ],
            shortTitle: "Open Font",
            systemImageName: "textformat"
        )
        AppShortcut(
            intent: SearchFontsIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search for fonts in \(.applicationName)"
            ],
            shortTitle: "Search Fonts",
            systemImageName: "magnifyingglass"
        )
    }
}

/// Keeps Spotlight's copy of the catalog in step with the app's, which changes only with a new build.
enum FontSpotlight {
    private static let indexedKey = "spotlightIndexedCatalog"

    /// Indexes every cask, once per build of the catalog.
    static func update() async {
        let stamp = [Bundle.main.infoDictionary?["CFBundleVersion"] as? String, Catalog.bundled.generated]
            .compactMap(\.self).joined(separator: " ") + " \(Catalog.bundled.casks.count)"
        guard UserDefaults.standard.string(forKey: indexedKey) != stamp else { return }
        do {
            try await index()
            UserDefaults.standard.set(stamp, forKey: indexedKey)
        } catch {
            // Tried again at the next launch.
        }
    }

    /// Replaces the index, so casks a release dropped don't linger in Spotlight.
    nonisolated static func index() async throws {
        let entities = await MainActor.run { Catalog.bundled.casks.map(FontEntity.init) }
        let index = CSSearchableIndex.default()
        try await index.deleteAppEntities(ofType: FontEntity.self)
        try await index.indexAppEntities(entities)
    }
}
