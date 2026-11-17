import SwiftUI

/// A paired cask's Nerd Font version: the same family patched with Nerd Fonts' icons, under its own name, with
/// its own install, version, size and license. It installs alongside the plain cask rather than instead of it,
/// since Nerd Fonts renames the families it patches.
struct NerdFontVersion: View {
    let cask: Cask
    let catalog: Catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nerd Font Version")
                    .font(.headline)
                Text("\(Self.shortName(cask.name)), with Nerd Fonts' icons for terminal prompts and code editors.")
                    .font(.callout)
                    .foregroundStyle(Color(.captionText))
            }
            .accessibilityElement(children: .combine)
            CaskSpecimen(cask: cask, catalog: catalog, size: 17, relativeTo: .body, lineLimit: 2)
                .accessibilityHidden(true)
            CaskActions(cask: cask, isNerdVersion: true)
            VStack(spacing: 8) {
                if let version = cask.version {
                    LabeledContent("Version", value: version)
                }
                LabeledContent("Download", value: cask.bytes, format: .byteCount(style: .file))
            }
            .labeledContentStyle(.detailRow)
            DisclosureGroup("Nerd Font License") {
                LicenseText(token: cask.token)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
        .padding()
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The cask's name without what Nerd Fonts adds after the family's: "FiraCode Nerd Font" rather than
    /// "FiraCode Nerd Font (Fira Code)", which the page's title already says, or "… Nerd Font families (…)".
    static func shortName(_ name: String) -> String {
        name.replacing(/\s*\([^)]*\)\s*$/, with: "").replacing(/\s+families$/, with: "")
    }
}
