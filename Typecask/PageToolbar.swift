import SwiftUI

/// Try It Out and Install in the navigation bar, for once the page's own buttons have scrolled away, as the App
/// Store keeps Get in sight. Homepage stays in the masthead: it's wanted once, not while reading the specimen.
/// Identified apart from the page's buttons, which are still in the accessibility tree while scrolled off.
struct PageToolbarActions: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer
    @Environment(\.tryOut) private var opener

    var body: some View {
        if let opener {
            Button("Try It Out", systemImage: "character.cursor.ibeam") {
                opener.open(TryOutStart(source: "toolbar"))
            }
            .matchedTransitionSource(id: "toolbar", in: opener.namespace)
            .accessibilityIdentifier("toolbarTryItOut")
        }
        install
    }

    @ViewBuilder private var install: some View {
        switch installer.status(of: cask) {
        case .available, .failed:
            if cask.isBundled {
                Button("Install") {
                    Task { await installer.run(.install, on: cask) }
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("toolbarInstall")
            }
        case .updateAvailable:
            if cask.isBundled {
                Button("Update") {
                    Task { await installer.run(.update, on: cask) }
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("toolbarUpdate")
            }
        case .downloading:
            ProgressView(value: installer.progress(of: cask))
                .progressViewStyle(.circular)
                .accessibilityLabel("Downloading")
        case .installing, .updating, .uninstalling:
            ProgressView()
        case .installed, .builtIn:
            EmptyView()
        }
    }
}
