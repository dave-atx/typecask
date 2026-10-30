import Foundation

/// How a font is drawn: from Google's category for Google Fonts families, and otherwise classified from
/// PANOSE and the OS/2 family class by scripts/build-catalog.py. Drives the sidebar's collections, like
/// Font Book's.
enum DesignStyle: String, CaseIterable, Hashable, Sendable {
    case monospaced
    case serif
    case sansSerif
    case display
    case handwriting

    var name: LocalizedStringResource {
        switch self {
        case .monospaced: "Fixed Width"
        case .serif: "Serif"
        case .sansSerif: "Sans Serif"
        case .display: "Display"
        case .handwriting: "Handwriting"
        }
    }

    var symbol: String {
        switch self {
        case .monospaced: "chevron.left.forwardslash.chevron.right"
        case .serif: "textformat.characters"
        case .sansSerif: "textformat"
        case .display: "megaphone"
        case .handwriting: "signature"
        }
    }
}

extension DesignStyle: Decodable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // A newer build-catalog.py may emit a style this build has no case for. Grouping it with sans
        // serif keeps the cask in the gallery instead of failing the whole catalog.
        self = DesignStyle(rawValue: raw) ?? .sansSerif
    }
}

/// A holiday collection, from the seasonal tags Google Fonts gives its families plus a few casks from
/// elsewhere that scripts/build-catalog.py adds. In calendar order, which the sidebar lists them in.
enum Holiday: String, CaseIterable, Hashable, Sendable {
    case lunarNewYear
    case valentinesDay
    case halloween
    case diwali
    case christmas

    var name: LocalizedStringResource {
        switch self {
        case .lunarNewYear: "Lunar New Year"
        case .valentinesDay: "Valentine’s Day"
        case .halloween: "Halloween"
        case .diwali: "Diwali"
        case .christmas: "Christmas"
        }
    }

    var symbol: String {
        switch self {
        case .lunarNewYear: "fireworks"
        case .valentinesDay: "heart"
        case .halloween: "theatermasks"
        case .diwali: "flame"
        case .christmas: "gift"
        }
    }
}

/// A sidebar collection. `List` selection has to be non-optional: a `nil` tag reads as "nothing
/// selected", so an All Fonts row tagged `nil` can never become the selection.
enum FontCollection: Hashable, Identifiable, Sendable {
    case allFonts
    /// Casks this app has installed.
    case installed
    case style(DesignStyle)
    /// Casks patched with Nerd Fonts' icons.
    case nerdFonts
    /// Apple's built-in and downloadable fonts rather than casks.
    case appleFonts
    case holiday(Holiday)

    var id: Self { self }

    var name: LocalizedStringResource {
        switch self {
        case .allFonts: "All Fonts"
        case .installed: "Installed"
        case .style(let style): style.name
        case .nerdFonts: "Nerd Fonts"
        case .appleFonts: "Apple Fonts"
        case .holiday(let holiday): holiday.name
        }
    }

    var symbol: String {
        switch self {
        case .allFonts: "square.grid.2x2"
        case .installed: "checkmark.circle"
        case .style(let style): style.symbol
        case .nerdFonts: "terminal"
        case .appleFonts: "applelogo"
        case .holiday(let holiday): holiday.symbol
        }
    }

    func contains(_ item: GalleryItem, installed: Set<Cask.ID>) -> Bool {
        switch (self, item) {
        case (.allFonts, _): true
        case (.style(let style), _): item.style == style
        case (.installed, .cask(let cask)): installed.contains(cask.id)
        case (.nerdFonts, .cask(let cask)): cask.glyphs
        case (.appleFonts, .apple): true
        case (.holiday(let holiday), .cask(let cask)): cask.holidays?.contains(holiday.rawValue) ?? false
        default: false
        }
    }
}
