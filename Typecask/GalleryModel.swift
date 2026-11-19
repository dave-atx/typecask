import Foundation
import Observation

/// Owns the gallery's browsing state and the filtered list it produces.
///
/// `visibleItems` is recomputed only when the search text, the collection or the installed casks
/// change, so a body evaluation triggered by anything else — an install's progress, a rotation, a
/// split-view resize — just reads a prepared array. The sidebar's counts are likewise recounted only
/// when the installed casks or the writing systems change.
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
        case updated

        var title: LocalizedStringResource {
            switch self {
            case .name: "Name"
            case .popularity: "Popularity"
            case .trending: "Trending"
            case .updated: "Recently Updated"
            }
        }
    }

    /// A script the gallery's fonts cover, by its ISO 15924 code, with how many fonts cover it.
    struct Script: Hashable, Identifiable {
        let code: String
        let name: String
        let count: Int

        var id: String { code }
    }

    let catalog: Catalog
    /// The styles present in the gallery, in `DesignStyle`'s own order.
    let styles: [DesignStyle]
    /// The holidays some cask suits, in `Holiday`'s own order.
    let holidays: [Holiday]
    /// The scripts enough fonts cover to list in the script menu itself: Latin, then the rest by name.
    let scripts: [Script]
    /// The long tail of scripts, a handful of fonts each, which the menu tucks into a submenu.
    let moreScripts: [Script]

    var searchText: String = "" {
        didSet { if searchText != oldValue { recompute() } }
    }

    /// What the gallery's stack starts from: Start Here, a collection's fonts, or the index of foundries or
    /// designers.
    enum Root: Hashable {
        case start
        case collection(FontCollection)
        case makers(Maker.Kind)
    }

    /// The fonts the gallery shows. Picking one, from the sidebar, a quick action or a search, shows it.
    var collection: FontCollection = .allFonts {
        didSet {
            if collection != oldValue { recompute() }
            if root != .collection(collection) { root = .collection(collection) }
        }
    }

    var root: Root = .start {
        didSet {
            if case .collection(let collection) = root, collection != self.collection { self.collection = collection }
            if root != oldValue { remember() }
        }
    }

    /// `List` selection is optional on iOS. The tags themselves are never nil — that was the bug: a row
    /// tagged `nil` reads as "nothing selected" and can never be picked — so nil here only means deselect,
    /// which an iPhone's back button to the sidebar does. That keeps the root: taking nil for Start Here
    /// changed the selection, and the split view pushed Start Here straight back over the sidebar.
    var selectedRoot: Root? {
        get { root }
        set { if let newValue { root = newValue } }
    }

    let articles: [Article]
    /// While the last page is being put back, which mustn't save the half-restored page over it.
    @ObservationIgnored var isRestoring = false

    /// Mirrors FontInstaller's, which the gallery view passes in as it changes.
    var installed: Set<Cask.ID> = [] {
        didSet {
            guard installed != oldValue else { return }
            recount()
            if collection == .installed {
                recompute()
            }
        }
    }

    /// Fonts must cover at least one of these; empty lets every font through.
    var selectedScripts: Set<String> = [] {
        didSet {
            guard selectedScripts != oldValue else { return }
            recount()
            recompute()
        }
    }

    var viewMode: ViewMode = .grid

    /// The pages pushed over the gallery: an article, a font's, or none.
    var path: [GalleryPage] = [] {
        didSet { if path != oldValue { remember() } }
    }
    var showsAbout = false
    /// Whether the search field is active, which a search from Siri or Shortcuts sets.
    var isSearchPresented = false
    /// Bumped to put the keyboard in the search field: presenting search again when it's already presented
    /// changes nothing, so Search Fonts from the Home Screen found the field there but not focused.
    private(set) var searchFocusRequests = 0

    var sortOrder: SortOrder = .name {
        didSet { if sortOrder != oldValue { recompute() } }
    }

    private(set) var visibleItems: [GalleryItem] = []
    /// How many fonts each sidebar collection holds that cover the selected writing systems.
    private var counts: [FontCollection: Int] = [:]

    let sortedItems: [GalleryItem]
    /// Each item's name and token, folded once here rather than on every keystroke.
    private let nameKeys: [String]
    private let scriptSets: [Set<String>]
    /// Each item's description, folded the same way off the main actor after launch: two thousand
    /// descriptions are a couple of MB of text, too much to fold before the first frame. Until then a
    /// search matches names only.
    @ObservationIgnored private var descriptionKeys: [String]?
    /// `sortedItems`' indices in each sort order, worked out once: unranked items, Apple's fonts among
    /// them, follow the ranked ones by name.
    private let orders: [SortOrder: [Int]]
    /// Every foundry and every designer, A to Z, with how many cards credit each.
    let makerIndex: [Maker.Kind: [MakerEntry]]
    /// Each maker's cards, as `sortedItems`' indices, most popular first.
    let makerItems: [Maker: [Int]]

    init(catalog: Catalog, articles: [Article] = Article.bundled) {
        self.catalog = catalog
        self.articles = articles
        // A paired Nerd Font version shares its plain cask's card rather than having its own.
        let casks = catalog.casks.filter { catalog.plainVersions[$0.token] == nil }
        let items = casks.map(GalleryItem.cask) + catalog.appleFonts.map(GalleryItem.apple)
        let presentStyles = Set(items.map(\.style))
        styles = DesignStyle.allCases.filter(presentStyles.contains)
        let presentHolidays = Set(catalog.casks.flatMap { $0.holidays ?? [] })
        holidays = Holiday.allCases.filter { presentHolidays.contains($0.rawValue) }
        let allScripts = Self.scripts(of: items)
        scripts = allScripts.filter { $0.count >= Self.listedScriptMinimum }
        moreScripts = allScripts.filter { $0.count < Self.listedScriptMinimum }
        // Sorted once here, so every later filter preserves the order instead of re-sorting.
        sortedItems = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        nameKeys = sortedItems.map { item in
            switch item {
            // The token is worth matching too: it is what a Homebrew user already knows the cask by. A paired
            // card answers to its Nerd Font version's name and token as well, so "Caskaydia" finds Cascadia.
            case .cask(let cask):
                Self.fold(([cask] + [catalog.nerdVersions[cask.token]].compactMap(\.self))
                    .map { "\($0.name) \($0.token)" }.joined(separator: " "))
            case .apple(let family): Self.fold(family.name)
            }
        }
        scriptSets = sortedItems.map { Set($0.scripts) }
        var orders: [SortOrder: [Int]] = [.name: Array(sortedItems.indices)]
        for order in [SortOrder.popularity, .trending, .updated] {
            // A paired card ranks as the better of its two casks, or the more recently updated.
            let ranks = sortedItems.map { item -> Int in
                guard case .cask(let cask) = item else { return .max }
                return ([cask] + [catalog.nerdVersions[cask.token]].compactMap(\.self))
                    .compactMap { Self.rank($0, by: order) }.min() ?? .max
            }
            // Stable on the name order, so ties and unranked items stay alphabetical.
            orders[order] = sortedItems.indices.sorted { ranks[$0] < ranks[$1] || (ranks[$0] == ranks[$1] && $0 < $1) }
        }
        self.orders = orders
        (makerItems, makerIndex) = Self.indexMakers(of: sortedItems, inOrder: orders[.popularity] ?? [])
        visibleItems = sortedItems
        recount()
        restore()
        let descriptions = sortedItems.map(Self.searchedText)
        Task { [weak self] in
            let folded = await Self.foldAll(descriptions)
            guard let self else { return }
            descriptionKeys = folded
            if !searchText.isEmpty {
                recompute()
            }
        }
    }

    /// Where the cask comes in `order`, lowest first; nil leaves it after those that have one. An update ranks by
    /// its date, newest first, as the negated number 20261106 reads.
    private static func rank(_ cask: Cask, by order: SortOrder) -> Int? {
        switch order {
        case .popularity: cask.popularity
        case .trending: cask.trending
        case .updated: cask.updated.flatMap { Int($0.filter(\.isNumber)) }.map { -$0 }
        case .name: nil
        }
    }

    /// The cask whose page is showing, if one is.
    var shownCask: Cask? {
        guard case .item(.cask(let cask)) = path.last else { return nil }
        return cask
    }

    /// Opens the cask's page over whatever was showing, as a shortcut installing or opening it does: its plain
    /// cask's, for a paired Nerd Font version, which that page offers too. The About sheet goes as well: left
    /// open, it covered the page and the install's progress.
    func show(_ cask: Cask) {
        showsAbout = false
        path = [.item(.cask(catalog.shown(cask)))]
    }

    /// Shows the collection's fonts in the order given, over whatever was showing, as the Home Screen's quick
    /// actions do.
    func browse(_ collection: FontCollection, sortedBy order: SortOrder? = nil) {
        showsAbout = false
        path = []
        // The whole collection, not what an earlier search left of it: Installed after a search for Roboto
        // showed "No Results for Roboto", under a search bar that hid the collection's name.
        searchText = ""
        isSearchPresented = false
        self.collection = collection
        if let order {
            sortOrder = order
        }
    }

    /// Searches every font for `term`, from the gallery itself, as a search from Siri or Shortcuts does.
    func search(_ term: String) {
        showsAbout = false
        path = []
        collection = .allFonts
        selectedScripts = []
        isSearchPresented = true
        searchText = term
        searchFocusRequests += 1
    }

    func count(of collection: FontCollection) -> Int {
        counts[collection] ?? 0
    }

    /// Every collection the sidebar lists, in its order.
    var collections: [FontCollection] {
        [.allFonts, .installed] + styles.map(FontCollection.style)
            + [.nerdFonts, .ligatures, .legibility, .symbols, .appleFonts]
            + holidays.map(FontCollection.holiday)
    }

    private func coversSelectedScripts(_ index: Int) -> Bool {
        selectedScripts.isEmpty || !selectedScripts.isDisjoint(with: scriptSets[index])
    }

    /// Counts each collection's fonts that cover the selected writing systems, so the sidebar agrees with
    /// what picking a collection then shows.
    private func recount() {
        let covering = sortedItems.indices.filter(coversSelectedScripts).map { sortedItems[$0] }
        counts = Dictionary(uniqueKeysWithValues: collections.map { collection in
            (collection, covering.count { collection.contains($0, installed: installed) })
        })
    }

    /// Fonts in the collection matching the search: those whose name matches first, then those whose
    /// description does, so "mono" lists monospaced families ahead of prose that mentions the word.
    private func recompute() {
        let query = Self.fold(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        var byName: [GalleryItem] = [], byDescription: [GalleryItem] = []
        for index in orders[sortOrder] ?? [] {
            let item = sortedItems[index]
            guard collection.contains(item, installed: installed), coversSelectedScripts(index) else { continue }
            if query.isEmpty || nameKeys[index].contains(query) {
                byName.append(item)
            } else if descriptionKeys?[index].contains(query) ?? false {
                byDescription.append(item)
            }
        }
        visibleItems = byName + byDescription
    }

    /// Every script `items` cover, Latin first, as most of the gallery is, then the rest by name.
    private static func scripts(of items: [GalleryItem]) -> [Script] {
        let counts = items.reduce(into: [String: Int]()) { counts, item in
            for code in Set(item.scripts) { counts[code, default: 0] += 1 }
        }
        return counts.map { code, count in
            Script(code: code, name: Locale.current.localizedString(forScriptCode: code) ?? code, count: count)
        }
        .sorted { lhs, rhs in
            (lhs.code == "Latn") != (rhs.code == "Latn")
                ? lhs.code == "Latn"
                : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Scripts fewer fonts cover than this go in a submenu: over a hundred of them, most with one font.
    private static let listedScriptMinimum = 10

    /// Folds case, diacritics and width away, so "Noto Sans" matches "noto sans" and "Fira Code" "Fira Côde".
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    @concurrent
    nonisolated private static func foldAll(_ texts: [String]) async -> [String] {
        texts.map { fold($0) }
    }
}

/// A page pushed over the gallery: an article, a font's, or a foundry's or designer's.
enum GalleryPage: Hashable {
    case article(Article)
    case item(GalleryItem)
    case maker(Maker)
}
