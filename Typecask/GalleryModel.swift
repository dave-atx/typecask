import Foundation
import Observation

/// Owns the gallery's browsing state and the filtered list it produces.
///
/// `visibleItems` is recomputed only when the search text, the collection or the installed casks
/// change, so a body evaluation triggered by anything else — an install's progress, a rotation, a
/// split-view resize — just reads a prepared array.
@MainActor
@Observable
final class GalleryModel {
    enum ViewMode: String, CaseIterable, Hashable {
        case grid
        case sample
    }

    let catalog: Catalog
    /// The styles present in the gallery, in `DesignStyle`'s own order, with how many fonts each holds.
    let styles: [(style: DesignStyle, count: Int)]
    let nerdFontCount: Int

    var searchText: String = "" {
        didSet { if searchText != oldValue { recompute() } }
    }

    var collection: FontCollection = .allFonts {
        didSet { if collection != oldValue { recompute() } }
    }

    /// `List` selection is optional on iOS. The tags themselves are never nil — that was the bug: a row
    /// tagged `nil` reads as "nothing selected" and can never be picked — so nil here only means deselect.
    var selectedCollection: FontCollection? {
        get { collection }
        set { collection = newValue ?? .allFonts }
    }

    /// Mirrors FontInstaller's, which the gallery view passes in as it changes.
    var installed: Set<Cask.ID> = [] {
        didSet { if installed != oldValue && collection == .installed { recompute() } }
    }

    var viewMode: ViewMode = .grid

    private(set) var visibleItems: [GalleryItem] = []

    private let sortedItems: [GalleryItem]
    /// Each item's name and token, and its description, folded once here rather than on every keystroke:
    /// two thousand descriptions are a couple of MB of text.
    private let searchKeys: [(names: String, description: String)]

    init(catalog: Catalog) {
        self.catalog = catalog
        let items = catalog.casks.map(GalleryItem.cask) + catalog.appleFonts.map(GalleryItem.apple)
        let counts = Dictionary(grouping: items, by: \.style).mapValues(\.count)
        styles = DesignStyle.allCases.compactMap { style in
            counts[style].map { (style, $0) }
        }
        nerdFontCount = catalog.casks.count(where: \.glyphs)
        // Sorted once here, so every later filter preserves the order instead of re-sorting.
        sortedItems = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        searchKeys = sortedItems.map { item in
            switch item {
            case .cask(let cask):
                // The token is worth matching too: it is what a Homebrew user already knows the cask by.
                (Self.fold("\(cask.name) \(cask.token)"), Self.fold(cask.description ?? ""))
            case .apple(let family):
                (Self.fold(family.name), "")
            }
        }
        visibleItems = sortedItems
    }

    func count(of collection: FontCollection) -> Int {
        switch collection {
        case .allFonts: sortedItems.count
        case .installed: installed.count
        case .style(let style): styles.first { $0.style == style }?.count ?? 0
        case .nerdFonts: nerdFontCount
        case .appleFonts: catalog.appleFonts.count
        }
    }

    /// Fonts in the collection matching the search: those whose name matches first, then those whose
    /// description does, so "mono" lists monospaced families ahead of prose that mentions the word.
    private func recompute() {
        let query = Self.fold(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        var byName: [GalleryItem] = [], byDescription: [GalleryItem] = []
        for (item, keys) in zip(sortedItems, searchKeys) where collection.contains(item, installed: installed) {
            if query.isEmpty || keys.names.contains(query) {
                byName.append(item)
            } else if keys.description.contains(query) {
                byDescription.append(item)
            }
        }
        visibleItems = byName + byDescription
    }

    nonisolated private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
