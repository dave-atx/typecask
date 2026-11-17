import Foundation

/// The links that open a font's page in the app: typecask.app's page for it, which the site's Smart App Banner
/// hands the app as its `app-argument`, and `typecask://font/TOKEN`, which the site's Open in Typecask link uses.
/// The token may leave off its `font-`, and the site's own path for the font works there too.
nonisolated enum DeepLink {
    static let scheme = "typecask"
    static let hosts: Set<String> = ["typecask.app", "www.typecask.app"]

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
