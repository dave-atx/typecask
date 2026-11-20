import SwiftUI

/// A getting-started article, from Articles.json, which scripts/articles.py writes from articles/*.md. The site
/// publishes the same articles under /start/.
nonisolated struct Article: Decodable, Hashable, Identifiable, Sendable {
    let slug: String
    let title: String
    /// Inline Markdown, as the paragraphs are.
    let summary: String
    let blocks: [Block]

    var id: String { slug }

    var specimens: [SpecimenLine] {
        blocks.compactMap { block in
            if case .specimen(let line) = block { line } else { nil }
        }
    }

    nonisolated enum Block: Decodable, Hashable, Sendable {
        case heading(String)
        case paragraph(String)
        case specimen(SpecimenLine)

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: ArticleBlockKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "heading": self = .heading(try container.decode(String.self, forKey: .text))
            case "specimen": self = .specimen(try SpecimenLine(from: decoder))
            // A kind a newer articles.py writes reads as a paragraph rather than failing every article.
            default: self = .paragraph(try container.decode(String.self, forKey: .text))
            }
        }
    }

    /// A line set in a cask's face. `font` is a file of its own, cut to the line's characters, since a
    /// preview font holds only the gallery's sample; it's already instanced at the line's axis values.
    nonisolated struct SpecimenLine: Decodable, Hashable, Sendable {
        let token: String
        let text: String
        let font: String
        /// OpenType features turned on or off, by tag.
        var features: [String: Bool]?
        /// The line's meaning, for a line in another language, set under it in the system font.
        var gloss: String?
    }

    /// A type term from articles/glossary.md, which a `term:` link in an article shows in a popover.
    nonisolated struct Term: Decodable, Hashable, Identifiable, Sendable {
        let term: String
        /// Inline Markdown, with no links.
        let definition: String

        var id: String { term }
    }

    private nonisolated struct File: Decodable {
        let articles: [Article]
        /// By slug, as `term:` links name them. Absent from an Articles.json older than the glossary.
        var terms: [String: Term]?
    }

    private static let file: File = {
        guard let url = Bundle.main.url(forResource: "Articles", withExtension: "json") else {
            return File(articles: [], terms: nil)
        }
        do {
            return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        } catch {
            // An article is an extra: the gallery works without them. articles.py check catches this in CI.
            assertionFailure("Articles.json is malformed: \(error)")
            return File(articles: [], terms: nil)
        }
    }()

    static let bundled: [Article] = file.articles
    static let glossary: [String: Term] = file.terms ?? [:]

    /// The term a `term:` link names, if the glossary has it.
    static func term(for url: URL) -> Term? {
        guard url.scheme == "term" else { return nil }
        return glossary[String(url.absoluteString.trimmingPrefix("term:"))]
    }

    /// Paragraph text as the app draws it: bold, italic and links, which the site draws the same way. A term's
    /// link takes a dotted underline, as an <abbr> on the site does, so it reads as a definition rather than a
    /// place to go. A link to the web, a foundry's site or a typeface's history, is the site's alone: in the app
    /// it's plain text, so every link stays in the app.
    static func markdown(_ text: String) -> AttributedString {
        var string = (try? AttributedString(markdown: text,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let runs = string.runs.compactMap { run in run.link.map { (run.range, $0.scheme) } }
        for (range, scheme) in runs {
            switch scheme {
            case "term": string[range].underlineStyle = Text.LineStyle(pattern: .dot)
            case "http", "https": string[range].link = nil
            default: break
            }
        }
        return string
    }
}

private enum ArticleBlockKeys: String, CodingKey {
    case kind, text
}

/// The page the app opens on the first time: the articles, each a card showing a few of its fonts.
struct StartHereView: View {
    @Bindable var model: GalleryModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("More than 2,000 free fonts. Here are some to start with.")
                    .font(.callout)
                    .foregroundStyle(Color(.captionText))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(model.articles) { article in
                        NavigationLink(value: GalleryPage.article(article)) {
                            ArticleCard(article: article)
                        }
                        .buttonStyle(CardButtonStyle(minHeight: 0))
                        .accessibilityIdentifier("article-\(article.slug)")
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Start Here")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Search lives on All Fonts; this takes you there with the field ready.
            ToolbarItem(placement: .primaryAction) {
                Button("Search", systemImage: "magnifyingglass") {
                    model.search("")
                }
                .accessibilityIdentifier("startSearch")
            }
            ToolbarItem(placement: .primaryAction) {
                PageShareLink(url: SiteLink.startHere, title: String(localized: "Start Here"))
            }
        }
    }
}

/// An article's title and summary. Its fonts wait for the article itself.
private struct ArticleCard: View {
    let article: Article

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.leading)
            Text(Article.markdown(article.summary))
                .font(.callout)
                .foregroundStyle(Color(.captionText))
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// An article: its sections, each font's line set in that font, opening the font's page when tapped.
struct ArticleView: View {
    let article: Article
    @Bindable var model: GalleryModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Grows with Dynamic Type, but not without limit: at the largest sizes a line of display type broke after
    /// every word.
    @ScaledMetric(relativeTo: .largeTitle) private var scale = 1.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(article.title)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let text):
                        Text(Article.markdown(text))
                            .font(.title2.weight(.semibold))
                            .padding(.top, 16)
                            .accessibilityAddTraits(.isHeader)
                    case .paragraph(let text):
                        ArticleParagraph(text: text, model: model)
                    case .specimen(let line):
                        specimen(line)
                    }
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PageShareLink(url: SiteLink.article(article), title: article.title)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            model.follow(url) ? .handled : .systemAction
        })
    }

    @ViewBuilder
    private func specimen(_ line: Article.SpecimenLine) -> some View {
        if let cask = model.catalog.casks.first(where: { $0.token == line.token }) {
            NavigationLink(value: GalleryPage.item(.cask(model.catalog.shown(cask)))) {
                // A shaded box, as the cards in the gallery, with the font's name inside it above the line.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) {
                        Text(cask.name)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(.captionText))
                    Text(line.text)
                        .font(PreviewFonts.font(line.font, size: sampleSize(sizeClass) * min(scale, 1.6),
                                                features: line.features ?? [:]))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let gloss = line.gloss {
                        Text(gloss)
                            .font(.callout)
                            .foregroundStyle(Color(.captionText))
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(4)
            }
            .buttonStyle(CardButtonStyle(minHeight: 0))
            .padding(.vertical, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(line.text), set in \(cask.name)" + (line.gloss.map { ". \($0)" } ?? "")))
            .accessibilityHint(Text("Opens the font's page"))
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("specimen-\(line.token)")
        }
    }
}

/// A paragraph of an article, whose `term:` links show the term's definition in a popover pointing at the term,
/// and whose other links go where the article sends them.
private struct ArticleParagraph: View {
    let text: String
    @Bindable var model: GalleryModel
    @State private var shown: ShownTerm?

    var body: some View {
        paragraph
            .font(.body)
            .environment(\.openURL, OpenURLAction { url in
                if let term = Article.term(for: url) {
                    shown = ShownTerm(term: term, link: url)
                    return .handled
                }
                return model.follow(url) ? .handled : .systemAction
            })
            // Each term's popover hangs off a clear view laid over the term, found in the paragraph's text layout,
            // so its arrow points at the word tapped; anchored to the whole Text, it pointed at the paragraph. The
            // views are there before any tap: one moved onto the term as the popover opened kept its old frame.
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    ForEach(Self.terms(in: layouts, proxy: proxy), id: \.link) { place in
                        // The popover before the position, which fills the paragraph: after it, it pointed there.
                        Color.clear
                            .frame(width: place.rect.width, height: place.rect.height)
                            .popover(item: shown(at: place.link)) { shown in
                                TermDefinition(term: shown.term)
                                    // A popover on iPhone too: a sheet for two lines of text would cover the
                                    // paragraph they explain.
                                    .presentationCompactAdaptation(.popover)
                            }
                            .position(x: place.rect.midX, y: place.rect.midY)
                    }
                }
            }
    }

    /// The paragraph, with each term's link marked so its place in the text layout can be found.
    private var paragraph: Text {
        let string = Article.markdown(text)
        return string.runs.reduce(Text(verbatim: "")) { text, run in
            let piece = Text(AttributedString(string[run.range]))
            guard let link = run.link, link.scheme == "term" else { return Text("\(text)\(piece)") }
            return Text("\(text)\(piece.customAttribute(TermLink(url: link)))")
        }
    }

    /// The term shown, for the view over `link` only.
    private func shown(at link: URL) -> Binding<ShownTerm?> {
        Binding(get: { shown?.link == link ? shown : nil }, set: { shown = $0 })
    }

    /// Where each term's link sits in the paragraph, at its first run: a term broken across lines points at its
    /// first part, and a term linked twice at its first mention.
    private static func terms(in layouts: [Text.LayoutKey.AnchoredLayout],
                              proxy: GeometryProxy) -> [(link: URL, rect: CGRect)] {
        var places: [(link: URL, rect: CGRect)] = []
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line {
                    guard let link = run[TermLink.self]?.url, !places.contains(where: { $0.link == link }) else {
                        continue
                    }
                    places.append((link, run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)))
                }
            }
        }
        return places
    }
}

/// A term's link in a paragraph's text, marked so the popover can find where the term was drawn.
private struct TermLink: TextAttribute {
    let url: URL
}

/// The term a paragraph's popover shows, and the link tapped to show it.
private struct ShownTerm: Identifiable {
    let term: Article.Term
    let link: URL

    var id: URL { link }
}

/// A term and its definition, as a popover shows them.
private struct TermDefinition: View {
    let term: Article.Term

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(term.term)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(Article.markdown(term.definition))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(idealWidth: 320, maxWidth: 360, alignment: .leading)
    }
}

#Preview("Start Here") {
    NavigationStack {
        StartHereView(model: GalleryModel(catalog: .bundled))
    }
    .environment(FontInstaller())
}

#Preview("Article") {
    NavigationStack {
        if let article = Article.bundled.first {
            ArticleView(article: article, model: GalleryModel(catalog: .bundled))
        }
    }
    .environment(FontInstaller())
}
