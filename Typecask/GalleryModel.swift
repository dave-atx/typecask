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

    private func recompute() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = sortedItems.filter { item in
            guard collection.contains(item, installed: installed) else { return false }
            guard !query.isEmpty else { return true }
            // A cask's token is worth matching too: it is what a Homebrew user already knows it by.
            if case .cask(let cask) = item, cask.token.localizedCaseInsensitiveContains(query) {
                return true
            }
            return item.name.localizedCaseInsensitiveContains(query)
        }
    }
}
