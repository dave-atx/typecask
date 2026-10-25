import Foundation

/// How a cask's primary face is drawn, classified from PANOSE and the OS/2 family class by
/// scripts/build-catalog.py. Drives the sidebar's collections, like Font Book's.
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
        case .display: "sparkles"
        case .handwriting: "hand.draw"
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

/// A sidebar collection. `List` selection has to be non-optional: a `nil` tag reads as "nothing
/// selected", so an All Fonts row tagged `nil` can never become the selection.
enum FontCollection: Hashable, Identifiable, Sendable {
    case allFonts
    case style(DesignStyle)

    var id: Self { self }

    var style: DesignStyle? {
        if case .style(let style) = self { style } else { nil }
    }
}
