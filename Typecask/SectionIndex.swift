import SwiftUI

/// A part of a font's page that the index beside it on a wide iPad jumps to.
enum PageSection: Hashable, CaseIterable, Identifiable {
    case nerdFont, styles, features, setting, characters, languages, about, license

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .nerdFont: "Nerd Font"
        case .styles: "Styles"
        case .features: "Features"
        case .setting: "Setting"
        case .characters: "Characters"
        case .languages: "Languages"
        case .about: "About"
        case .license: "License"
        }
    }
}

/// A font page's sections in a column beside it, each scrolling the page to it, with the one in view marked.
struct SectionIndex: View {
    let sections: [PageSection]
    let current: PageSection?
    let jump: (PageSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("On This Page")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Color(.captionText))
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(sections) { section in
                Button { jump(section) } label: {
                    Text(section.title)
                        .font(.subheadline.weight(section == current ? .semibold : .regular))
                        .foregroundStyle(section == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == current ? .isSelected : [])
            }
        }
        .frame(width: 160, alignment: .leading)
        .padding(.top, 24)
        .padding(.trailing, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sectionIndex")
    }
}
