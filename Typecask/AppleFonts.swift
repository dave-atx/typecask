import CoreText
import SwiftUI
import UIKit

/// One of Apple's font families: built into iOS, or offered under Settings › General › Fonts ›
/// More Fonts. Listed in AppleFonts.json, which TypecaskUITests/ApplePreviewRenderer.swift generates in
/// the simulator.
///
/// An app can download a More Fonts family for its own use, but only Settings installs one for every
/// app, and nothing tells an app what Settings has installed. So downloadable families are previewed
/// from subsets shipped with the app, rather than downloaded as the gallery scrolls past them.
struct AppleFontFamily: Decodable, Identifiable, Hashable {
    let name: String
    let faces: Int
    /// PostScript name of the face previews are set in: the Regular, where the family has one.
    let previewFace: String
    let style: DesignStyle
    /// Always installed, as opposed to downloadable from Settings.
    let builtIn: Bool
    /// A line in the family's own script, for a font with no Latin letters.
    let sample: String?
    /// The family's preview face subset to its sample, from the Mac's copy, for a downloadable family.
    let previewFile: String?
    /// Base name of a rendered preview, for a downloadable family that has no subset: one the Mac
    /// lacks, or whose sample needs shaping that subsetting drops.
    let preview: String?

    var id: String { name }

    /// A built-in family set in its own face. Downloadable families draw from their preview images instead.
    func font(size: CGFloat) -> Font {
        Font(CTFontCreateWithName(previewFace as CFString, size, nil))
    }

    /// The rendered preview for a grid card or a sample row, or nil for a built-in family.
    func previewImage(_ kind: PreviewKind) -> UIImage? {
        preview.flatMap { UIImage(named: "\($0)-\(kind.rawValue)") }
    }

    enum PreviewKind: String {
        case card
        case row
    }
}

/// An entry in the gallery: a cask, or one of Apple's families, which sort and filter alongside the casks.
enum GalleryItem: Identifiable, Hashable {
    case cask(Cask)
    case apple(AppleFontFamily)

    var id: String {
        switch self {
        case .cask(let cask): "cask/\(cask.token)"
        case .apple(let family): "apple/\(family.name)"
        }
    }

    var name: String {
        switch self {
        case .cask(let cask): cask.name
        case .apple(let family): family.name
        }
    }

    var style: DesignStyle {
        switch self {
        case .cask(let cask): cask.style
        case .apple(let family): family.style
        }
    }

    /// What the UI tests find the item's card by: a cask's token, as Homebrew users know it.
    var accessibilityIdentifier: String {
        switch self {
        case .cask(let cask): cask.token
        case .apple(let family): family.name
        }
    }
}
