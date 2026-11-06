import Foundation

/// typecask.app's pages, opened in the app. A universal link hands the app the page's URL, and so does
/// Safari's Smart App Banner, as its `app-argument`.
///
/// The site names a font's page by the cask's token less "font-" and a style's page by the style's name,
/// as `site/content/fonts/_content.gotmpl` and the footer build them: `/fonts/caveat/` opens Caveat and
/// `/styles/fixed-width/` opens Fixed Width. The site's `apple-app-site-association` lists the same paths.
enum SiteLinks {
    static let host = "typecask.app"

    enum Destination: Equatable {
        case cask(token: String)
        case collection(FontCollection)
    }

    /// Where the URL leads in the app, or nil for a page with no counterpart there, such as the privacy policy.
    static func destination(of url: URL) -> Destination? {
        guard url.scheme == "https", url.host() == host || url.host() == "www.\(host)" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (parts.first, parts.count) {
        case ("fonts"?, 1):
            return .collection(.allFonts)
        case ("fonts"?, 2):
            return .cask(token: "font-" + parts[1])
        case ("styles"?, 2):
            return styles[parts[1]].map { .collection($0) }
        default:
            return nil
        }
    }

    /// The site's style pages, by the urlized names its footer links to.
    private static let styles: [String: FontCollection] = [
        "fixed-width": .style(.monospaced),
        "serif": .style(.serif),
        "sans-serif": .style(.sansSerif),
        "display": .style(.display),
        "handwriting": .style(.handwriting),
        "nerd-fonts": .nerdFonts
    ]

    /// Opens what the URL names. False for a page the app has nothing for, which leaves the app as it was.
    ///
    /// The site lists the catalog of the latest build, so it can link a font an older copy of the app doesn't
    /// carry. That becomes a search for the font's name, which finds it under a renamed token, or shows that
    /// it isn't there.
    @MainActor
    @discardableResult
    static func open(_ url: URL, in gallery: GalleryModel) -> Bool {
        switch destination(of: url) {
        case .cask(let token):
            if let cask = gallery.catalog.casks.first(where: { $0.token == token }) {
                gallery.show(cask)
            } else {
                gallery.search(String(token.dropFirst("font-".count)).replacing("-", with: " "))
            }
        case .collection(let collection):
            gallery.browse(collection)
        case nil:
            return false
        }
        return true
    }
}
