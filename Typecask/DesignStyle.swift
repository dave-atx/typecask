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

    /// What the gallery says at the top of the style's collection.
    var summary: LocalizedStringResource {
        switch self {
        case .monospaced:
            "Every character the same width, so columns line up: fonts for code, terminals and tables."
        case .serif:
            "Small finishing strokes on each letter, as in most books and newspapers, for reading at length."
        case .sansSerif:
            "Letters without finishing strokes, plain and clean: the usual choice for screens, interfaces and signs."
        case .display:
            "Fonts made for headlines, posters and logos, to be set large rather than in paragraphs."
        case .handwriting:
            "Scripts, brush lettering and handwriting, from formal calligraphy to quick notes."
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
    /// Coding faces that join sequences like -> and != into ligatures, which the catalog marks `ligatures`.
    case ligatures
    /// Casks made to be easy to read, which the catalog marks `legible`.
    case legibility
    /// Casks typed on a keyboard that draw something other than letters, which the catalog marks `symbols`.
    case symbols
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
        case .ligatures: "Ligatures"
        case .legibility: "Legibility"
        case .symbols: "Symbols"
        case .appleFonts: "Apple Fonts"
        case .holiday(let holiday): holiday.name
        }
    }

    /// What the gallery says at the top of the collection, or nil for one that needs no explaining: all fonts,
    /// which go straight to the fonts, and a holiday's.
    var summary: LocalizedStringResource? {
        switch self {
        case .allFonts:
            nil
        case .installed:
            "Fonts you've installed with Typecask. Remove one here, or in Settings › General › Fonts."
        case .style(let style):
            style.summary
        case .nerdFonts:
            """
            Coding fonts patched with Nerd Fonts' thousands of icons, for terminal prompts and editors that show \
            file types, branches and the like.
            """
        case .ligatures:
            """
            Coding fonts that draw sequences like -> and != as single symbols, in editors and terminals that \
            support ligatures. A font's page can turn them off to show the characters underneath.
            """
        case .legibility:
            """
            Fonts made to be easy to read, for low vision, dyslexia or beginning readers: Atkinson Hyperlegible \
            from the Braille Institute, Lexend from research into reading fluency, B612 from Airbus's cockpit \
            displays, and more.
            """
        case .symbols:
            """
            Fonts you type like any other that draw something else: scribbles and blocks that stand in for text \
            in mockups, knitting symbols, and letters charted as stitches on a grid.
            """
        case .appleFonts:
            """
            The fonts built into iOS, and those Settings › General › Fonts offers to download. Typecask can't \
            install these: only Settings can give one of Apple's fonts to every app.
            """
        case .holiday:
            nil
        }
    }

    var symbol: String {
        switch self {
        case .allFonts: "square.grid.2x2"
        case .installed: "checkmark.circle"
        case .style(let style): style.symbol
        case .nerdFonts: "terminal"
        case .ligatures: "link"
        case .legibility: "eyeglasses"
        case .symbols: "scribble"
        case .appleFonts: "applelogo"
        case .holiday(let holiday): holiday.symbol
        }
    }

    func contains(_ item: GalleryItem, installed: Set<Cask.ID>) -> Bool {
        switch (self, item) {
        case (.allFonts, _): true
        case (.style(let style), _): item.style == style
        // A paired card stands for its Nerd Font version too.
        case (.installed, .cask(let cask)): installed.contains(cask.id) || cask.nerdFont.map(installed.contains) == true
        case (.nerdFonts, .cask(let cask)): cask.glyphs || cask.nerdFont != nil
        case (.ligatures, .cask(let cask)): cask.ligatures ?? false
        case (.legibility, .cask(let cask)): cask.legible ?? false
        case (.symbols, .cask(let cask)): cask.symbols ?? false
        case (.appleFonts, .apple): true
        case (.holiday(let holiday), .cask(let cask)): cask.holidays?.contains(holiday.rawValue) ?? false
        default: false
        }
    }
}

extension FontCollection {
    /// The collection's name in an article's links (collection:serif) and the remembered last page, spelled
    /// as scripts/articles.py's COLLECTIONS spells them.
    var key: String {
        switch self {
        case .allFonts: "allFonts"
        case .installed: "installed"
        case .style(let style): style.rawValue
        case .nerdFonts: "nerdFonts"
        case .ligatures: "ligatures"
        case .legibility: "legibility"
        case .symbols: "symbols"
        case .appleFonts: "appleFonts"
        case .holiday(let holiday): holiday.rawValue
        }
    }

    init?(key: String) {
        let fixed: [FontCollection] = [
            .allFonts, .installed, .nerdFonts, .ligatures, .legibility, .symbols, .appleFonts
        ]
        if let collection = fixed.first(where: { $0.key == key }) {
            self = collection
        } else if let style = DesignStyle(rawValue: key) {
            self = .style(style)
        } else if let holiday = Holiday(rawValue: key) {
            self = .holiday(holiday)
        } else {
            return nil
        }
    }
}
