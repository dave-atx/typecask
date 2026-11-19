import Foundation

/// Following an article's links, and reopening where the app was last time.
extension GalleryModel {
    /// Follows a link in an article: to a collection, which it shows, or to a font, a foundry, a designer or another
    /// article, whose page it pushes. False for any other link, which opens in Safari.
    func follow(_ url: URL) -> Bool {
        switch url.scheme {
        case "collection":
            guard let collection = FontCollection(key: url.absoluteString.trimmingPrefix("collection:").description)
            else { return false }
            browse(collection)
            return true
        case "font":
            let token = url.absoluteString.trimmingPrefix("font:")
            guard let cask = catalog.casks.first(where: { $0.token == token }) else { return false }
            path.append(.item(.cask(catalog.shown(cask))))
            return true
        case "foundry", "designer":
            let kind: Maker.Kind = url.scheme == "foundry" ? .foundry : .designer
            let slug = String(url.absoluteString.drop { $0 != ":" }.dropFirst())
            guard let entry = makers(kind).first(where: { Maker.slug(of: $0.maker.name) == slug }) else { return false }
            path.append(.maker(entry.maker))
            return true
        case "article":
            let slug = url.absoluteString.trimmingPrefix("article:")
            guard let article = articles.first(where: { $0.slug == slug }) else { return false }
            path.append(.article(article))
            return true
        default:
            return false
        }
    }

    /// Start Here, or an article over it, as a link from the site opens them, over whatever was showing.
    func showStart(_ start: DeepLink.Start) {
        showsAbout = false
        let pages: [GalleryPage] = if case .article(let article) = start { [.article(article)] } else { [] }
        guard root != .start else {
            path = pages
            return
        }
        root = .start
        path = []
        // A new root resets the split view's stack once it shows, which dropped an article pushed with it.
        Task { @MainActor in path = pages }
    }

    /// The maker's page, if the catalog still credits them with a font.
    private func maker(_ maker: Maker) -> GalleryPage? {
        items(by: maker).isEmpty ? nil : .maker(maker)
    }

    // MARK: The last page

    /// Where the app was, as a launch argument can set it too: the root, then each page over it, joined by |,
    /// as "start|article:start-here|font:font-inter". The UI tests start on "collection:allFonts".
    private static let lastPageKey = "lastPage"

    func remember() {
        guard !isRestoring else { return }
        let root = switch root {
        case .start: "start"
        case .collection(let collection): "collection:\(collection.key)"
        case .makers(let kind): "makers:\(kind.rawValue)"
        }
        let pages = path.map { page in
            switch page {
            case .article(let article): "article:\(article.slug)"
            case .item(.cask(let cask)): "font:\(cask.token)"
            case .item(.apple(let family)): "apple:\(family.name)"
            case .maker(let maker): "\(maker.kind.rawValue):\(maker.name)"
            }
        }
        UserDefaults.standard.set(([root] + pages).joined(separator: "|"), forKey: Self.lastPageKey)
    }

    /// Back where the app was last time, as far as it can still find: Start Here the first time, or when the
    /// collection remembered is gone. A page it can't find, a font a fonts release dropped, ends the path there.
    func restore() {
        isRestoring = true
        defer { isRestoring = false }
        let parts = (UserDefaults.standard.string(forKey: Self.lastPageKey) ?? "start").split(separator: "|")
            .map(String.init)
        if let first = parts.first, first.hasPrefix("collection:"),
           let collection = FontCollection(key: String(first.dropFirst("collection:".count))) {
            self.collection = collection
            root = .collection(collection)
        } else if let first = parts.first, first.hasPrefix("makers:"),
                  let kind = Maker.Kind(rawValue: String(first.dropFirst("makers:".count))) {
            root = .makers(kind)
        } else {
            root = .start
        }
        var pages: [GalleryPage] = []
        for part in parts.dropFirst() {
            let (kind, name) = (part.prefix { $0 != ":" }, part.drop { $0 != ":" }.dropFirst())
            let page: GalleryPage? = switch kind {
            case "article": articles.first { $0.slug == name }.map(GalleryPage.article)
            case "font": catalog.casks.first { $0.token == name }.map { .item(.cask($0)) }
            case "apple": catalog.appleFonts.first { $0.name == name }.map { .item(.apple($0)) }
            case "foundry", "designer": maker(Maker(kind: Maker.Kind(rawValue: String(kind)) ?? .foundry,
                                                    name: String(name)))
            default: nil
            }
            guard let page else { break }
            pages.append(page)
        }
        path = pages
    }
}
