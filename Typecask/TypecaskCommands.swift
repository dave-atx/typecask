import SwiftUI

extension FocusedValues {
    /// The cask whose page is showing, for the File menu.
    @Entry var cask: Cask?
}

/// Install or Update, and Uninstall, in the iPad menu bar's File menu, for the font whose page is showing.
/// SwiftUI enables each as the page and its status change.
struct TypecaskCommands: Commands {
    let installer: FontInstaller
    @FocusedValue(\.cask) private var cask

    var body: some Commands {
        let status = cask.map(installer.status(of:))
        let isBundled = cask?.isBundled ?? false
        CommandGroup(after: .newItem) {
            // ⌘D, as in download. iPadOS swallows ⌘I, Italic's, though the app has nothing to italicize, and
            // ⌘⌫ too, so Uninstall has no shortcut.
            if status == .updateAvailable {
                button("Update", action: .update)
                    .keyboardShortcut("d")
                    .disabled(!isBundled)
            } else {
                button("Install", action: .install)
                    .keyboardShortcut("d")
                    .disabled(!isBundled || !(status == .available || status?.isFailed == true))
            }
            button("Uninstall", action: .uninstall)
                .disabled(!(status?.isInstalled ?? false))
        }
    }

    private func button(_ title: LocalizedStringKey, action: FontInstaller.Action) -> some View {
        Button(title) {
            if let cask {
                Task { await installer.run(action, on: cask) }
            }
        }
    }
}

private extension FontInstaller.Status {
    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}
