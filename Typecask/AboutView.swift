import SwiftUI

/// About and help, opened from the sidebar: the questions typecask.app/support answers, where to report a
/// problem, and the app's version, privacy and licensing.
struct AboutView: View {
    let catalog: Catalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                AboutHeader(fonts: catalog.casks.count)
                Section("Help") {
                    ForEach(HelpTopic.all) { topic in
                        DisclosureGroup(topic.question) {
                            Text(topic.answer)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Link(destination: Links.support) {
                        Label("Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: Links.issues) {
                        Label("Report a Problem or Request a Font", systemImage: "exclamationmark.bubble")
                    }
                    Link(destination: Links.review) {
                        Label("Write a Review", systemImage: "star")
                    }
                    ShareLink(item: Links.site) {
                        Label("Share Typecask", systemImage: "square.and.arrow.up")
                    }
                }
                Section {
                    Link(destination: Links.privacy) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: Links.licenses) {
                        Label("Font Licenses", systemImage: "doc.text")
                    }
                    Link(destination: Links.source) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } footer: {
                    Text("""
                        Typecask collects no data. Every font belongs to its designers and ships under its own \
                        license, which you can read on its page. Typecask isn't affiliated with Homebrew, Google \
                        or Apple.
                        """)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private enum Links {
        static let site = URL(string: "https://typecask.app")!
        static let support = URL(string: "https://typecask.app/support/")!
        static let privacy = URL(string: "https://typecask.app/privacy/")!
        static let licenses = URL(string: "https://typecask.app/licenses/")!
        static let issues = URL(string: "https://github.com/dave-atx/typecask/issues")!
        static let source = URL(string: "https://github.com/dave-atx/typecask")!
        /// Opens the App Store's review sheet directly. The system's own prompt, `ReviewPrompt`, can't be asked
        /// for from a button: iOS may not show it, and a button that does nothing reads as broken.
        static let review = URL(string: "https://apps.apple.com/app/id6826936046?action=write-review")!
    }
}

/// The app's icon, name and version, centered above the list like Settings' own About pages.
private struct AboutHeader: View {
    let fonts: Int

    var body: some View {
        VStack(spacing: 8) {
            // A copy of the icon at 88 points: an app icon set can't be loaded as an image.
            Image(.aboutIcon)
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(.rect(cornerRadius: 20))
                // The icon's near-black ground would vanish into a dark sheet without an edge.
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.separator)
                }
                .accessibilityHidden(true)
            Text(verbatim: "Typecask")
                .font(.title.bold())
            Text("Version \(Self.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("""
                \(fonts, format: .number) free fonts for your iPhone and iPad, in any app that lets you pick \
                a font.
                """)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    /// "1.0 (12)": the marketing version and the TestFlight build number.
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// The common questions from typecask.app/support, kept short enough to read in a list.
private struct HelpTopic: Identifiable {
    let question: LocalizedStringKey
    let answer: LocalizedStringKey
    let id: String

    static let all = [
        HelpTopic(question: "How do I install a font?", answer: """
            Open it, tap Install and approve the system's prompt. It shows up in Settings › General › Fonts, and \
            in any app that lets you pick a font.
            """, id: "install"),
        HelpTopic(question: "Can I change my iPhone's system font?", answer: """
            No. iOS doesn't let any app replace the font Settings, the Home Screen and the rest of the system use. \
            Installed fonts are for apps that let you choose one for what you're making.
            """, id: "systemFont"),
        HelpTopic(question: "I installed a font and can't find it in an app", answer: """
            Not every app lets you change fonts. Pages, Keynote, Numbers, Procreate and plenty of others do; lots \
            of apps only use their own. If the font is listed in Settings › General › Fonts, it installed fine.
            """, id: "find"),
        HelpTopic(question: "Does deleting Typecask remove my fonts?", answer: """
            No. The system keeps its own copy, so fonts stay installed through updates and reinstalls. To remove \
            one, tap Uninstall on its page or use Settings › General › Fonts before you delete the app.
            """, id: "remove"),
        HelpTopic(question: "How do fonts get updated?", answer: """
            When a new release of Typecask carries a newer version of a font you've installed, its page offers \
            Update.
            """, id: "update"),
        HelpTopic(question: "A font says “Built into iOS” and won't install", answer: """
            iOS already ships a font under that same internal name, so installing another copy fails and every \
            app has the font anyway. Nothing is broken.
            """, id: "builtIn"),
        HelpTopic(question: "Can Typecask install Apple's fonts?", answer: """
            No. Apple Fonts lists what's built into iOS and what Settings can download, so you can see what you \
            already have. Only Settings › General › Fonts › More Fonts can install those for every app.
            """, id: "apple"),
        HelpTopic(question: "What are Nerd Fonts?", answer: """
            Fixed-width fonts patched with an extra icon set, so a shell prompt, status line or file tree renders \
            the glyphs it expects. If you don't already know what they're for, you don't need them.
            """, id: "nerd")
    ]
}

#Preview {
    AboutView(catalog: .bundled)
}

#Preview("AX1") {
    AboutView(catalog: .bundled)
        .dynamicTypeSize(.accessibility1)
}
