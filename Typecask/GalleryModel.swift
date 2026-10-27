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

    enum SortOrder: String, CaseIterable, Hashable {
        case name
        case popularity
        case trending

        var title: LocalizedStringResource {
            switch self {
            case .name: "Name"
            case .popularity: "Popularity"
            case .trending: "Trending"
            }
        }
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

    var sortOrder: SortOrder = .name {
        didSet { if sortOrder != oldValue { recompute() } }
    }

    private(set) var visibleItems: [GalleryItem] = []

    private let sortedItems: [GalleryItem]
    /// Each item's name and token, folded once here rather than on every keystroke.
    private let nameKeys: [String]
    /// Each item's description, folded the same way off the main actor after launch: two thousand
    /// descriptions are a couple of MB of text, too much to fold before the first frame. Until then a
    /// search matches names only.
    @ObservationIgnored private var descriptionKeys: [String]?
    /// `sortedItems`' indices in each sort order, worked out once: unranked items, Apple's fonts among
    /// them, follow the ranked ones by name.
    private let orders: [SortOrder: [Int]]

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
        nameKeys = sortedItems.map { item in
            switch item {
            // The token is worth matching too: it is what a Homebrew user already knows the cask by.
            case .cask(let cask): Self.fold("\(cask.name) \(cask.token)")
            case .apple(let family): Self.fold(family.name)
            }
        }
        var orders: [SortOrder: [Int]] = [.name: Array(sortedItems.indices)]
        for order in [SortOrder.popularity, .trending] {
            let ranks = sortedItems.map { item -> Int in
                guard case .cask(let cask) = item else { return .max }
                return (order == .popularity ? cask.popularity : cask.trending) ?? .max
            }
            // Stable on the name order, so ties and unranked items stay alphabetical.
            orders[order] = sortedItems.indices.sorted { ranks[$0] < ranks[$1] || (ranks[$0] == ranks[$1] && $0 < $1) }
        }
        self.orders = orders
        visibleItems = sortedItems
        let descriptions = sortedItems.map { item in
            switch item {
            case .cask(let cask): cask.description ?? ""
            case .apple: ""
            }
        }
        Task { [weak self] in
            let folded = await Self.foldAll(descriptions)
            guard let self else { return }
            descriptionKeys = folded
            if !searchText.isEmpty {
                recompute()
            }
        }
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
        for index in orders[sortOrder] ?? [] {
            let item = sortedItems[index]
            guard collection.contains(item, installed: installed) else { continue }
            if query.isEmpty || nameKeys[index].contains(query) {
                byName.append(item)
            } else if descriptionKeys?[index].contains(query) ?? false {
                byDescription.append(item)
            }
        }
        visibleItems = byName + byDescription
    }

    nonisolated private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    @concurrent
    nonisolated private static func foldAll(_ texts: [String]) async -> [String] {
        texts.map { fold($0) }
    }
}
