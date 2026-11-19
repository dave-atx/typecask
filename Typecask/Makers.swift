import SwiftUI

/// A foundry or a designer the catalog credits with some of its fonts, from scripts/makers.json's sorting of
/// Google Fonts' credits and the fonts' own name tables.
struct Maker: Hashable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case foundry
        case designer

        /// The sidebar's row and the index's title.
        var title: LocalizedStringResource {
            switch self {
            case .foundry: "Foundries"
            case .designer: "Designers"
            }
        }

        var symbol: String {
            switch self {
            case .foundry: "building.2"
            case .designer: "person.2"
            }
        }

        /// What the index says above the names.
        var summary: LocalizedStringResource {
            switch self {
            case .foundry:
                "The studios and companies that made the fonts."
            case .designer:
                "The people who drew the fonts."
            }
        }
    }

    let kind: Kind
    let name: String

    var id: Self { self }

    /// The name as an article's link spells it, "foundry:the-league-of-moveable-type": lower case, with each run of
    /// anything but letters and digits a hyphen, as scripts/articles.py's maker_slug() makes it.
    static func slug(of name: String) -> String {
        name.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: "-")
    }

    /// The names a cask credits as this kind of maker.
    static func names(_ kind: Kind, of cask: Cask) -> [String] {
        switch kind {
        case .foundry: cask.foundries ?? []
        case .designer: cask.designers ?? []
        }
    }
}

/// A maker in the index, with how many of the gallery's cards it's credited on.
struct MakerEntry: Hashable, Identifiable {
    let maker: Maker
    let count: Int

    var id: Maker { maker }
}

/// Every foundry or every designer, A to Z or by how many fonts each made, each opening its fonts.
struct MakerIndex: View {
    @Bindable var model: GalleryModel
    let kind: Maker.Kind
    @State private var searchText = ""
    @AppStorage("makerOrder") private var byCount = false

    var body: some View {
        let entries = shownEntries
        List {
            Section {
                ForEach(entries) { entry in
                    NavigationLink(value: GalleryPage.maker(entry.maker)) {
                        LabeledContent {
                            // The system's secondary gray is 3.5:1 on white, short of the 4.5:1 this size needs.
                            Text(entry.count, format: .number)
                                .foregroundStyle(Color(.captionText))
                        } label: {
                            Text(entry.maker.name)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("makerRow.\(entry.maker.name)")
                }
            } header: {
                if searchText.isEmpty {
                    CollectionSummary(text: kind.summary)
                        .textCase(nil)
                        .padding(.bottom, 4)
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle(Text(kind.title))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text(kind == .foundry ? "Search Foundries" : "Search Designers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $byCount) {
                        Text("Name").tag(false)
                        Text("Most Fonts").tag(true)
                    }
                } label: {
                    Label("Sort By", systemImage: "arrow.up.arrow.down")
                        .accessibilityLabel(Text(byCount ? "Sort By, Most Fonts" : "Sort By, Name"))
                        .accessibilityInputLabels([Text("Sort By"), Text("Sort")])
                }
                .accessibilityIdentifier("makerOrder")
            }
        }
        .accessibilityIdentifier("makers")
    }

    private var shownEntries: [MakerEntry] {
        let query = GalleryModel.fold(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        let entries = model.makers(kind).filter { query.isEmpty || GalleryModel.fold($0.maker.name).contains(query) }
        // The index is already A to Z, so a stable sort keeps names with as many fonts in that order.
        return byCount ? entries.enumerated().sorted { ($1.element.count, $0.offset) < ($0.element.count, $1.offset) }
            .map(\.element) : entries
    }
}

/// A foundry's or a designer's fonts, most popular first, and the makers they share them with.
struct MakerPage: View {
    let maker: Maker
    let model: GalleryModel

    var body: some View {
        let items = model.items(by: maker)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MakerHeader(maker: maker, count: items.count, related: model.related(to: maker))
                    .padding([.horizontal, .top])
                if model.viewMode == .grid {
                    GalleryGrid(items: items, catalog: model.catalog, summary: nil)
                } else {
                    GallerySampleList(items: items, catalog: model.catalog, summary: nil)
                }
            }
        }
        .navigationTitle(maker.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("makerPage")
    }
}

/// "Foundry · 12 fonts", then whom else the fonts credit, each a link to their own page.
private struct MakerHeader: View {
    let maker: Maker
    let count: Int
    let related: [Maker]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(maker.kind == .foundry ? "Foundry · ^[\(count) font](inflect: true)"
                : "Designer · ^[\(count) font](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(Color(.captionText))
            if !related.isEmpty {
                // Wrapped rather than scrolled sideways, so every name is on screen.
                WrappingRows(spacing: 8) { links }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var links: some View {
        ForEach(related) { other in
            NavigationLink(value: GalleryPage.maker(other)) {
                Label(other.name, systemImage: other.kind.symbol)
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            // Ink rather than the tint, which on its own tinted fill measured short of 4.5:1.
            .tint(.primary)
        }
    }
}

/// Its subviews left to right, onto a new row where the next doesn't fit.
private struct WrappingRows: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for subview in subviews {
            // No wider than the row, so a long name wraps inside its capsule rather than running off the screen.
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: CGSize(width: min(size.width, width), height: size.height)))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

/// A font page's credits, each name a link to that maker's page.
struct MakerLinks: View {
    let kind: Maker.Kind
    let names: [String]

    var body: some View {
        // A link per name, so each opens its own page; joined as a list would read them.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { content }
            VStack(alignment: .leading, spacing: 2) { content }
        }
    }

    @ViewBuilder private var content: some View {
        ForEach(Array(names.enumerated()), id: \.offset) { index, name in
            NavigationLink(value: GalleryPage.maker(Maker(kind: kind, name: name))) {
                Text(name + (index < names.count - 1 ? "," : ""))
                    .multilineTextAlignment(.leading)
                    // A hit area tall enough to tap, given back to the layout below, so the facts keep their spacing.
                    .padding(.vertical, 12)
                    .contentShape(.rect)
            }
            .padding(.vertical, -12)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.trailing, 4)
            // The name alone: the comma is for the eye.
            .accessibilityLabel(Text(name))
            .accessibilityIdentifier("maker.\(name)")
        }
    }
}

extension GalleryModel {
    /// Every foundry or every designer, A to Z, with how many fonts each made.
    func makers(_ kind: Maker.Kind) -> [MakerEntry] {
        makerIndex[kind] ?? []
    }

    /// The fonts the maker is credited with, most popular first.
    func items(by maker: Maker) -> [GalleryItem] {
        (makerItems[maker] ?? []).map { sortedItems[$0] }
    }

    /// Whom the maker's fonts credit besides them, those credited most first, at most `limit`: a foundry's
    /// designers, and a designer's foundries and the people they designed with.
    func related(to maker: Maker, limit: Int = 8) -> [Maker] {
        var counts: [Maker: Int] = [:]
        for item in items(by: maker) {
            guard case .cask(let cask) = item else { continue }
            for kind in Maker.Kind.allCases {
                for name in Maker.names(kind, of: cask) where Maker(kind: kind, name: name) != maker {
                    counts[Maker(kind: kind, name: name), default: 0] += 1
                }
            }
        }
        // Foundries first, then by how often they're credited, then by name, so the order is the same every time.
        return counts.sorted { lhs, rhs in
            if lhs.key.kind != rhs.key.kind { return lhs.key.kind == .foundry }
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.name.localizedStandardCompare(rhs.key.name) == .orderedAscending
        }
        .prefix(limit).map(\.key)
    }

    /// Each maker's items, as indices into `items` in `order`, and every maker of each kind, A to Z, with its count.
    static func indexMakers(of items: [GalleryItem], inOrder order: [Int])
        -> ([Maker: [Int]], [Maker.Kind: [MakerEntry]]) {
        var makerItems: [Maker: [Int]] = [:]
        for index in order {
            guard case .cask(let cask) = items[index] else { continue }
            for kind in Maker.Kind.allCases {
                for name in Maker.names(kind, of: cask) {
                    makerItems[Maker(kind: kind, name: name), default: []].append(index)
                }
            }
        }
        let index = Dictionary(grouping: makerItems.map { MakerEntry(maker: $0.key, count: $0.value.count) },
                               by: \.maker.kind)
            .mapValues { entries in
                entries.sorted { $0.maker.name.localizedStandardCompare($1.maker.name) == .orderedAscending }
            }
        return (makerItems, index)
    }

    /// What a search matches after an item's name: a cask's makers, so a search for Tunni or TypeTogether finds their
    /// fonts after those named for them, and its description.
    nonisolated static func searchedText(of item: GalleryItem) -> String {
        switch item {
        case .cask(let cask):
            ((cask.foundries ?? []) + (cask.designers ?? []) + [cask.description ?? ""]).joined(separator: " ")
        case .apple: ""
        }
    }
}
