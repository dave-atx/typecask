import Foundation
import Observation

/// Owns the gallery's browsing state and the filtered list it produces.
///
/// `visibleCasks` is recomputed only when the search text or the collection changes, so a body
/// evaluation triggered by anything else — an install finishing, a rotation, a split-view resize —
/// just reads a prepared array.
@MainActor
@Observable
final class GalleryModel {
    enum ViewMode: String, CaseIterable, Hashable {
        case grid
        case sample
    }

    let catalog: Catalog
    /// The styles present in this catalog, in `DesignStyle`'s own order, with how many casks each holds.
    let collections: [(style: DesignStyle, count: Int)]

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

    var viewMode: ViewMode = .grid

    private(set) var visibleCasks: [Cask] = []

    private let sortedCasks: [Cask]

    init(catalog: Catalog) {
        self.catalog = catalog
        let counts = Dictionary(grouping: catalog.casks, by: \.style).mapValues(\.count)
        collections = DesignStyle.allCases.compactMap { style in
            counts[style].map { (style, $0) }
        }
        // Sorted once here, so every later filter preserves the order instead of re-sorting.
        sortedCasks = catalog.casks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        visibleCasks = sortedCasks
    }

    private func recompute() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = collection.style
        visibleCasks = sortedCasks.filter { cask in
            guard style == nil || cask.style == style else { return false }
            guard !query.isEmpty else { return true }
            // The token is worth matching too: it is what the Homebrew user already knows the cask by.
            return cask.name.localizedCaseInsensitiveContains(query)
                || cask.token.localizedCaseInsensitiveContains(query)
        }
    }
}
