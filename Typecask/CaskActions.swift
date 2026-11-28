import SwiftUI

/// Install or Uninstall, and the homepage, as glass buttons. Not in a GlassEffectContainer: inside one,
/// the buttons dropped out of the accessibility tree once the cask was installed, Uninstall included.
/// Identified by the cask's token, so the UI tests can tell a page's two sets apart, the plain cask's and its
/// Nerd Font version's, which share their buttons' identifiers.
struct CaskActions: View {
    let cask: Cask
    /// Whether these are a paired page's Nerd Font version's, which leave out the homepage and name the
    /// version to VoiceOver, so the page's two Install buttons don't sound alike.
    var isNerdVersion = false
    /// Loads the page's full specimen, where the page offers it: nil once it's asked for, and on a paired Nerd
    /// Font version's buttons, which share the page's.
    var fullSpecimen: (() -> Void)?
    @Environment(FontInstaller.self) private var installer

    var body: some View {
        // The same spacing as the page's own, which these were part of before they were grouped.
        VStack(alignment: .leading, spacing: 24) {
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("controls.\(cask.token)")
    }

    @ViewBuilder private var content: some View {
        // In rows, each button onto the next where it doesn't fit, rather than squeezed: at an accessibility text
        // size a single row broke every label mid-word. Wrapping keeps the labels, which icons alone wouldn't, and
        // with Install on Mac there are four, which no iPhone fits in one row.
        WrappingRows(spacing: 12) { buttons }
        if !cask.isBundled, installer.status(of: cask) != .builtIn {
            // The release left this cask's fonts out (see README), or this is a debug build carrying a few
            // casks', so there is no On-Demand Resources tag to download, and offering Install would just fail.
            Label("Fonts not included in this build", systemImage: "arrow.down.circle.dotted")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if case .failed(let message) = installer.status(of: cask) {
            // Red on the icon alone: red text is 3.5:1 on white, short of the 4.5:1 text needs.
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        // An installed cask can be removed even when this build no longer ships it, and one iOS has built in
        // says so whatever the build carries.
        let status = installer.status(of: cask)
        if cask.isBundled || status.isInstalled || status == .builtIn {
            InstallControl(cask: cask, isNerdVersion: isNerdVersion)
        }
        if (cask.isBundled || status.isInstalled) && status != .builtIn {
            TryItOutButton(cask: cask)
        }
        if let fullSpecimen {
            Button("Full Specimen", systemImage: "text.book.closed", action: fullSpecimen)
                .buttonStyle(.glass)
                .accessibilityHint(Text("""
                    Adds every style, passages, the whole character set and the languages it covers. \
                    Downloads \(cask.bytes.formatted(.byteCount(style: .file))).
                    """))
                .accessibilityIdentifier("fullSpecimen")
        }
        if cask.isBundled {
            InstallOnMacButton(cask: cask, isNerdVersion: isNerdVersion)
        }
        if !isNerdVersion {
            Link(destination: cask.homepage) {
                Label("Homepage", systemImage: "safari")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("homepage")
        }
    }
}

/// The control for the cask's status. When an install or uninstall finishes, VoiceOver's focus moves to
/// whatever replaced the button it was on, rather than being lost with that button.
private struct InstallControl: View {
    let cask: Cask
    var isNerdVersion = false
    @Environment(FontInstaller.self) private var installer
    @AccessibilityFocusState private var focus: Control?

    private enum Control: Hashable {
        case install
        case uninstall
    }

    var body: some View {
        content
            .onChange(of: installer.status(of: cask)) { old, new in
                guard old.isBusy else { return }
                switch new {
                case .installed: focus = .uninstall
                case .available, .failed: focus = .install
                default: break
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch installer.status(of: cask) {
        case .available:
            installButton("Install")
        case .failed:
            installButton("Try Again")
        case .downloading:
            ProgressView("Downloading…", value: installer.progress(of: cask))
                .frame(maxWidth: 220)
        case .installing:
            ProgressView("Installing…")
        case .uninstalling:
            ProgressView("Uninstalling…")
        case .updating:
            ProgressView("Updating…")
        case .updateAvailable:
            Button("Update", systemImage: "arrow.down.circle") {
                Task { await installer.run(.update, on: cask) }
            }
            .buttonStyle(.glassProminent)
            .disabled(!cask.isBundled)
            .accessibilityLabel(isNerdVersion ? "Update Nerd Font" : "Update")
            .accessibilityIdentifier("update")
            uninstallButton
        case .builtIn:
            Label("Built into iOS", systemImage: "checkmark.seal")
                .foregroundStyle(.secondary)
        case .installed:
            // Green on the icon alone: green text is about 2:1 on white.
            Label {
                Text("Installed")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(.installedBadge))
            }
            uninstallButton
        }
    }

    private var uninstallButton: some View {
        Button("Uninstall", systemImage: "trash", role: .destructive) {
            Task { await installer.run(.uninstall, on: cask) }
        }
        .buttonStyle(.glass)
        .accessibilityLabel(isNerdVersion ? "Uninstall Nerd Font" : "Uninstall")
        .accessibilityFocused($focus, equals: .uninstall)
        .accessibilityIdentifier("uninstall")
    }

    private func installButton(_ title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "arrow.down.circle") {
            Task { await installer.run(.install, on: cask) }
        }
        .buttonStyle(.glassProminent)
        // The visible title, or which version it installs on a paired page. Try Again stays as it is.
        .accessibilityLabel(isNerdVersion && title == "Install" ? "Install Nerd Font" : title)
        .accessibilityFocused($focus, equals: .install)
        .accessibilityIdentifier("install")
    }
}

#Preview {
    let catalog = Catalog.bundled
    let cask = catalog.casks.first { $0.token == "font-aboreto" } ?? catalog.casks[0]
    NavigationStack {
        CaskDetailView(cask: cask, catalog: catalog)
    }
    .environment(FontInstaller())
}

#if DEBUG
#Preview("Installed") {
    let catalog = Catalog.bundled
    let cask = catalog.casks.first { $0.token == "font-aboreto" } ?? catalog.casks[0]
    NavigationStack {
        CaskDetailView(cask: cask, catalog: catalog)
    }
    .environment(FontInstaller(previewing: .installed, for: cask))
}

#Preview("Installed, AX1") {
    let catalog = Catalog.bundled
    let cask = catalog.casks.first { $0.token == "font-aboreto" } ?? catalog.casks[0]
    NavigationStack {
        CaskDetailView(cask: cask, catalog: catalog)
    }
    .environment(FontInstaller(previewing: .installed, for: cask))
    .dynamicTypeSize(.accessibility1)
}
#endif
