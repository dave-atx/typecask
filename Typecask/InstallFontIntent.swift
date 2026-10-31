import AppIntents
import Foundation

/// Installs a cask from Shortcuts, Siri or Spotlight: "Install Lexend with Typecask".
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

    @Parameter(title: "Font", requestValueDialog: "Which font?")
    var font: FontEntity

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
    func perform() async throws -> some IntentResult & ReturnsValue<FontEntity> & ProvidesDialog {
        guard let cask = Catalog.bundled.casks.first(where: { $0.token == font.id }) else {
            throw AppIntentError.Unrecoverable.entityNotFound
        }
        // A shortcut can launch the app, and until the launch's refresh is done every cask reads as available.
        await installer.refresh(Catalog.bundled.casks)
        switch installer.status(of: cask) {
        case .installed, .updateAvailable:
            return .result(value: font, dialog: "\(cask.name) is already installed.")
        case .builtIn:
            return .result(value: font, dialog: "\(cask.name) is built into iOS, so every app already has it.")
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
            return .result(value: font, dialog: "Installed \(cask.name) for every app that lets you pick a font.")
        case .failed(let message):
            throw InstallFontError.failed(cask.name, message)
        default:
            // Declined at the consent sheet.
            throw InstallFontError.cancelled(cask.name)
        }
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

/// A cask, as Shortcuts and Siri know it.
struct FontEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Font"
    static let defaultQuery = FontEntityQuery()

    /// The cask's token, like font-lexend. Saved shortcuts store it, so it has to stay the token.
    let id: String
    @Property(title: "Name") var name: String
    private let style: LocalizedStringResource

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: style)
    }

    @MainActor
    init(_ cask: Cask) {
        id = cask.token
        style = cask.style.name
        name = cask.name
    }
}

nonisolated struct FontEntityQuery: EntityStringQuery {
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
                "Install a font with \(.applicationName)"
            ],
            shortTitle: "Install Font",
            systemImageName: "arrow.down.circle"
        )
    }
}
