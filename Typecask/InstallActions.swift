import SwiftUI

extension FontInstaller {
    /// The status a card shows for the cask and its Nerd Font version together: the plain cask's, unless
    /// that's merely available or failed while the Nerd Font version is installed, busy or out of date, so
    /// one badge says the family is installed whichever version is.
    func cardStatus(of cask: Cask, in catalog: Catalog) -> Status {
        let plain = status(of: cask)
        guard let nerd = catalog.nerdVersions[cask.token] else { return plain }
        switch plain {
        case .available, .failed:
            let other = status(of: nerd)
            return other == .available ? plain : other
        default:
            return plain
        }
    }

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
    /// menu on a long press, and as actions to VoiceOver and Voice Control. A card that also stands for a Nerd
    /// Font version offers that version's too.
    func caskActions(_ cask: Cask, nerdVersion: Cask? = nil) -> some View {
        modifier(CaskActionsModifier(cask: cask, nerdVersion: nerdVersion))
    }
}

private struct CaskActionsModifier: ViewModifier {
    let cask: Cask
    let nerdVersion: Cask?
    @Environment(FontInstaller.self) private var installer

    func body(content: Content) -> some View {
        // The installer is passed in rather than read from the environment, which a context menu's content
        // isn't sure to share.
        content
            .contextMenu { buttons }
            .accessibilityActions { buttons }
    }

    @ViewBuilder private var buttons: some View {
        CaskActionButtons(cask: cask, installer: installer, isNerdVersion: false)
        if let nerdVersion {
            CaskActionButtons(cask: nerdVersion, installer: installer, isNerdVersion: true)
        }
    }
}

private struct CaskActionButtons: View {
    let cask: Cask
    let installer: FontInstaller
    /// Whether this is a paired card's Nerd Font version, whose actions say so: the card already has an Install.
    let isNerdVersion: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        let status = installer.status(of: cask)
        switch status {
        case .available, .failed:
            if cask.isBundled {
                button(isNerdVersion ? "Install Nerd Font" : "Install", systemImage: "arrow.down.circle",
                       action: .install)
            }
        case .updateAvailable:
            if cask.isBundled {
                button(isNerdVersion ? "Update Nerd Font" : "Update", systemImage: "arrow.down.circle",
                       action: .update)
            }
            uninstallButton
        case .installed:
            uninstallButton
        default:
            EmptyView()
        }
        if !isNerdVersion {
            Button("Homepage", systemImage: "safari") {
                openURL(cask.homepage)
            }
        }
    }

    private var uninstallButton: some View {
        button(isNerdVersion ? "Uninstall Nerd Font" : "Uninstall", systemImage: "trash", action: .uninstall)
    }

    private func button(_ title: LocalizedStringKey, systemImage: String, action: FontInstaller.Action) -> some View {
        Button(title, systemImage: systemImage, role: action == .uninstall ? .destructive : nil) {
            Task { await installer.run(action, on: cask) }
        }
    }
}
