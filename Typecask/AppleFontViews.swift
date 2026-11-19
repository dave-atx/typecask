import SwiftUI
import UIKit

/// A family's sample: a built-in family set live in its own face, and a downloadable one, which isn't
/// on the device to draw with, from its shipped subset or, failing that, a rendered image.
struct AppleFontSpecimen: View {
    let family: AppleFontFamily
    let sampleText: String
    let kind: AppleFontFamily.PreviewKind
    let lineLimit: Int?
    @ScaledMetric private var size: CGFloat

    init(family: AppleFontFamily, sampleText: String, kind: AppleFontFamily.PreviewKind, lineLimit: Int?,
         rowSize: CGFloat = 64) {
        self.family = family
        self.sampleText = sampleText
        self.kind = kind
        self.lineLimit = lineLimit
        _size = ScaledMetric(wrappedValue: kind == .card ? 20 : rowSize,
                             relativeTo: kind == .card ? .title3 : .largeTitle)
    }

    var body: some View {
        let text = family.sample ?? sampleText
        if family.builtIn {
            Text(text)
                .font(family.font(size: size))
                .lineLimit(lineLimit)
                .accessibilityIdentifier("specimen")
        } else if let file = family.previewFile {
            Text(text)
                .font(PreviewFonts.font(file, size: size))
                .lineLimit(lineLimit)
                .accessibilityIdentifier("specimen")
        } else if let image = family.previewImage(kind) {
            Image(uiImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                // Never larger than it was rendered, but shrinks where the card or screen is narrower.
                .frame(maxWidth: image.size.width, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
                .accessibilityIdentifier("specimen")
        } else {
            Text(text)
                .font(.system(size: size))
                .lineLimit(lineLimit)
                .accessibilityIdentifier("specimen")
                .foregroundStyle(.tertiary)
        }
    }
}

struct AppleFontCard: View {
    let family: AppleFontFamily
    let sampleText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppleFontSpecimen(family: family, sampleText: sampleText, kind: .card, lineLimit: 3)
            Spacer(minLength: 0)
            CardFooter(title: family.name) {
                AppleFontSource(family: family)
            }
        }
    }
}

struct AppleFontSampleRow: View {
    let family: AppleFontFamily
    let sampleText: String
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SampleRowHeader(title: family.name) {
                AppleFontSource(family: family)
            }
            AppleFontSpecimen(family: family, sampleText: sampleText, kind: .row, lineLimit: 2,
                              rowSize: sampleSize(horizontalSizeClass))
        }
        .sampleRowLayout()
    }
}

/// Where an Apple family comes from, in place of a cask's install count.
private struct AppleFontSource: View {
    let family: AppleFontFamily

    var body: some View {
        Label(family.builtIn ? "Built In" : "In Settings", systemImage: "applelogo")
            .labelStyle(.titleAndIcon)
    }
}

/// An Apple family's page. A built-in family's faces are on the device, so its page has the full specimen a cask's
/// has, its styles, features, setting, characters and languages, and opens Try It Out from any of them. A
/// downloadable family's has only its preview, since resolving one through Core Text would download it.
struct AppleFontDetailView: View {
    let family: AppleFontFamily
    let sampleText: String
    @State private var loader = TryOutLoader()
    /// Try It Out, while it's open, and what it opened to.
    @State private var tryOut: TryOutStart?
    @Namespace private var tryOutNamespace

    var body: some View {
        ScrollView {
            // Lazy for the character grid's pinned header (see SpecimenCharacters).
            LazyVStack(alignment: .leading, spacing: 32, pinnedViews: .sectionHeaders) {
                VStack(alignment: .leading, spacing: 24) {
                    AppleFontSpecimen(family: family, sampleText: sampleText, kind: .row, lineLimit: nil)
                        .opensTryOut(TryOutStart(source: "sample"),
                                     hint: Text("Opens Try It Out, to type in this font."))
                    AppleFontStatus(builtIn: family.builtIn)
                    if family.builtIn {
                        Button("Try It Out", systemImage: "character.cursor.ibeam") {
                            tryOut = TryOutStart(source: "button")
                        }
                        .buttonStyle(.glass)
                        .accessibilityHint(Text("Type in this font."))
                        .matchedTransitionSource(id: "button", in: tryOutNamespace)
                        .accessibilityIdentifier("tryItOut")
                    }
                    VStack(spacing: 8) {
                        LabeledContent("Styles", value: family.faces, format: .number)
                        LabeledContent("Design Style") { Text(family.style.name) }
                    }
                    .labeledContentStyle(.detailRow)
                }
                if case .loaded(let loaded) = loader.phase {
                    let specimen = loaded.specimen
                    SpecimenStyles(specimen: specimen, sample: sample, ligatures: true)
                    SpecimenFeatures(specimen: specimen)
                    SpecimenSetting(specimen: specimen, ligatures: true)
                    SpecimenCharacters(specimen: specimen)
                    SpecimenLanguages(specimen: specimen)
                }
            }
            .padding()
        }
        .navigationTitle(family.name)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.tryOut, family.builtIn ? TryOutOpener(token: "apple/\(family.name)", namespace: tryOutNamespace,
                                                             open: { tryOut = $0 }) : nil)
        .sheet(item: $tryOut) { start in
            TryItOutView(fonts: .apple(family), loader: loader, start: start)
                // A page on iPad, not a form sheet: an editor wants the room.
                .presentationSizing(.page)
                .navigationTransition(.zoom(sourceID: start.source, in: tryOutNamespace))
        }
        .task {
            if family.builtIn {
                await loader.load(family, sample: sample)
            }
        }
    }

    private var sample: String { family.sample ?? sampleText }
}

/// What someone can do with an Apple family: nothing for a built-in one, which every app already has,
/// and install a downloadable one from Settings, the only place that installs these for every app.
private struct AppleFontStatus: View {
    let builtIn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if builtIn {
                // Green on the icon alone: green text is about 2:1 on white.
                Label {
                    Text("Built into iOS")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(.installedBadge))
                }
                .font(.headline)
                Text("Every app can already use this font.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label("Install from Settings", systemImage: "gearshape")
                    .font(.headline)
                Text("""
                    Apple provides this font. To use it in other apps, install it from \
                    Settings › General › Fonts › More Fonts.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("appleFontStatus")
    }
}
