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
    /// place to go.
    static func markdown(_ text: String) -> AttributedString {
        var string = (try? AttributedString(markdown: text,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in string.runs where run.link?.scheme == "term" {
            string[run.range].underlineStyle = Text.LineStyle(pattern: .dot)
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
                }
                .padding(4)
            }
            .buttonStyle(CardButtonStyle(minHeight: 0))
            .padding(.vertical, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(line.text), set in \(cask.name)"))
            .accessibilityHint(Text("Opens the font's page"))
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("specimen-\(line.token)")
        }
    }
}

/// A paragraph of an article, whose `term:` links show the term's definition in a popover over the paragraph,
/// and whose other links go where the article sends them.
private struct ArticleParagraph: View {
    let text: String
    @Bindable var model: GalleryModel
    @State private var term: Article.Term?

    var body: some View {
        Text(Article.markdown(text))
            .font(.body)
            .environment(\.openURL, OpenURLAction { url in
                if let found = Article.term(for: url) {
                    term = found
                    return .handled
                }
                return model.follow(url) ? .handled : .systemAction
            })
            .popover(item: $term) { term in
                TermDefinition(term: term)
                    // A popover on iPhone too: a sheet for two lines of text would cover the paragraph they explain.
                    .presentationCompactAdaptation(.popover)
            }
    }
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
