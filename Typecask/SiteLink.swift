import SwiftUI

/// typecask.app's page for what the app is showing, which Share sends: a font's, an article's, a maker's or a
/// collection's. Pages the site has no counterpart for, like Installed or Apple's fonts, have no link.
enum SiteLink {
    static let site = URL(string: "https://typecask.app/")!

    static func cask(_ cask: Cask) -> URL {
        page("fonts", DeepLink.slug(of: cask.token))
    }

    static let startHere = page("start")

    static func article(_ article: Article) -> URL {
        page("start", article.slug)
    }

    /// The site keeps each maker's page at the slug the articles link it by: see
    /// site/layouts/_partials/maker-slug.html.
    static func maker(_ maker: Maker) -> URL {
        page(maker.kind.sitePath, Maker.slug(of: maker.name))
    }

    static func makers(_ kind: Maker.Kind) -> URL {
        page(kind.sitePath)
    }

    /// All fonts, and the collections the site has a page for: the design styles and Nerd Fonts.
    static func collection(_ collection: FontCollection) -> URL? {
        switch collection {
        case .allFonts: page("fonts")
        case .style(let style): page("styles", style.siteSlug)
        case .nerdFonts: page("styles", "nerd-fonts")
        case .installed, .ligatures, .legibility, .symbols, .appleFonts, .holiday: nil
        }
    }

    /// The path with a trailing slash, as the site's pages are, and anything outside ASCII percent-encoded.
    private static func page(_ components: String...) -> URL {
        components.reduce(site) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }
}

extension Maker.Kind {
    var sitePath: String {
        switch self {
        case .foundry: "foundries"
        case .designer: "designers"
        }
    }
}

extension DesignStyle {
    /// The style's page on the site, from its English name as Hugo urlizes it.
    var siteSlug: String {
        switch self {
        case .monospaced: "fixed-width"
        case .serif: "serif"
        case .sansSerif: "sans-serif"
        case .display: "display"
        case .handwriting: "handwriting"
        }
    }
}

/// Shares the page's link on typecask.app, for the toolbar.
struct PageShareLink: View {
    let url: URL
    let title: String

    var body: some View {
        ShareLink(item: url, subject: Text(title), preview: SharePreview(title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("share")
    }
}
