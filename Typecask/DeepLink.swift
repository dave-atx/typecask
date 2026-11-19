import Foundation

/// The links that open a font's page or an article in the app: typecask.app's page for it, which the site's Smart
/// App Banner hands the app as its `app-argument`, and `typecask://font/TOKEN` or `typecask://start/SLUG`, which
/// the site's Open in Typecask links use. A font's token may leave off its `font-`, and the site's own path for
/// the font works there too. `typecask://start` and typecask.app/start/ open Start Here.
nonisolated enum DeepLink {
    static let scheme = "typecask"
    static let hosts: Set<String> = ["typecask.app", "www.typecask.app"]

    /// Where a link to the articles goes: Start Here, or one article.
    enum Start: Equatable {
        case startHere
        case article(Article)
    }

    /// Start Here or the article the link names, or nil for a link to anything else. An article the app doesn't
    /// have, one newer than this version, opens Start Here, the nearest page it has.
    static func start(for url: URL, in articles: [Article]) -> Start? {
        let path = url.pathComponents.filter { $0 != "/" }
        let slug: String?
        if url.scheme == scheme, url.host() == "start" {
            slug = path.first
        } else if let host = url.host(), hosts.contains(host), path.first == "start" {
            slug = path.dropFirst().first
        } else {
            return nil
        }
        return articles.first { $0.slug == slug }.map(Start.article) ?? .startHere
    }

    /// The cask the link names, or nil for a link to anything else, which just opens the app.
    static func cask(for url: URL, in catalog: Catalog) -> Cask? {
        let path = url.pathComponents.filter { $0 != "/" }
        let name: String
        if url.scheme == scheme, url.host() == "font", let first = path.first {
            name = first
        } else if let host = url.host(), hosts.contains(host), path.count >= 2, path[0] == "fonts" {
            name = path[1]
        } else {
            return nil
        }
        return catalog.casks.first { $0.token == name || $0.token == "font-" + name || slug(of: $0.token) == name }
    }

    /// A cask's path under typecask.app/fonts/, as site/layouts/_partials/cask-slug.html makes it: the token
    /// without `font-`, and a + spelled out, since Cloudflare redirects a + in a path.
    static func slug(of token: String) -> String {
        String(token.trimmingPrefix("font-")).replacing("+", with: "-plus")
    }
}
