import SwiftUI

extension FontInstaller {
    enum Action {
        case install
        case update
        case uninstall
    }

    /// Installs, updates or uninstalls the cask as the app's own controls do, then tells VoiceOver how it
    /// ended: otherwise one button just swaps for another, or an error appears only as text. Not for
    /// shortcuts, whose dialog says how it went. High priority, so VoiceOver restoring focus after the
    /// consent sheet doesn't cut it off.
    func run(_ action: Action, on cask: Cask) async {
        guard !status(of: cask).isBusy else { return }
        switch action {
        case .install: await install(cask)
        case .update: await update(cask)
        case .uninstall: await uninstall(cask)
        }
        guard let announcement = Self.announcement(of: action, on: cask, endingIn: status(of: cask)) else { return }
        var text = AttributedString(localized: announcement)
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
    }

    private static func announcement(of action: Action, on cask: Cask,
                                     endingIn status: Status) -> LocalizedStringResource? {
        let name = cask.name
        return switch (action, status) {
        case (.install, .installed): "\(name) installed"
        case (.install, .available): "Install cancelled"
        case (.install, .failed(let message)): "Couldn't install \(name). \(message)"
        case (.update, .installed): "\(name) updated"
        // An update removes the old fonts before installing the new, so declining it leaves neither.
        case (.update, .available): "Update cancelled. \(name) is no longer installed."
        case (.update, .failed(let message)): "Couldn't update \(name). \(message)"
        case (.uninstall, .available): "\(name) uninstalled"
        case (.uninstall, .failed(let message)): "Couldn't uninstall \(name). \(message)"
        default: nil
        }
    }
}

extension View {
    /// Offers the cask's install, update or uninstall, and its homepage, without opening its page: in a
    /// menu on a long press, and as actions to VoiceOver and Voice Control.
    func caskActions(_ cask: Cask) -> some View {
        modifier(CaskActionsModifier(cask: cask))
    }
}

private struct CaskActionsModifier: ViewModifier {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer

    func body(content: Content) -> some View {
        // The installer is passed in rather than read from the environment, which a context menu's content
        // isn't sure to share.
        content
            .contextMenu {
                CaskActionButtons(cask: cask, installer: installer)
            }
            .accessibilityActions {
                CaskActionButtons(cask: cask, installer: installer)
            }
    }
}

private struct CaskActionButtons: View {
    let cask: Cask
    let installer: FontInstaller
    @Environment(\.openURL) private var openURL

    var body: some View {
        let status = installer.status(of: cask)
        switch status {
        case .available, .failed:
            if cask.isBundled {
                button("Install", systemImage: "arrow.down.circle", action: .install)
            }
        case .updateAvailable:
            if cask.isBundled {
                button("Update", systemImage: "arrow.down.circle", action: .update)
            }
            button("Uninstall", systemImage: "trash", action: .uninstall)
        case .installed:
            button("Uninstall", systemImage: "trash", action: .uninstall)
        default:
            EmptyView()
        }
        Button("Homepage", systemImage: "safari") {
            openURL(cask.homepage)
        }
    }

    private func button(_ title: LocalizedStringKey, systemImage: String, action: FontInstaller.Action) -> some View {
        Button(title, systemImage: systemImage, role: action == .uninstall ? .destructive : nil) {
            Task { await installer.run(action, on: cask) }
        }
    }
}
