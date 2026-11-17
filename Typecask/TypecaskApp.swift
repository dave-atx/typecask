import AppIntents
import SwiftUI

@main
struct TypecaskApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var installer: FontInstaller
    @State private var model: GalleryModel
    @Environment(\.scenePhase) private var scenePhase

    /// Registers the installer and the gallery for shortcuts here, the first code to run on every launch:
    /// a shortcut can launch the app and run before any view appears.
    init() {
        let installer = FontInstaller()
        let model = GalleryModel(catalog: .bundled)
        _installer = State(initialValue: installer)
        _model = State(initialValue: model)
        AppDependencyManager.shared.add(dependency: installer)
        AppDependencyManager.shared.add(dependency: model)
        TypecaskShortcuts.updateAppShortcutParameters()
        QuickActions.gallery = model
        QuickActions.update()
    }

    /// Shows the font a link names; any other link just brings the app up as it was.
    private func open(_ url: URL) {
        if let cask = DeepLink.cask(for: url, in: model.catalog) {
            model.show(cask)
        }
    }

    var body: some Scene {
        WindowGroup {
            GalleryView(model: model)
                .environment(installer)
                .task(priority: .background) { await FontSpotlight.update() }
                .onOpenURL { open($0) }
                // typecask.app's pages, should they become universal links.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    activity.webpageURL.map(open)
                }
        }
        .commands {
            TypecaskCommands(installer: installer)
        }
        // On every return to the foreground, not just at launch: fonts can be removed in Settings ›
        // General › Fonts while the app is in the background.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await installer.refresh(Catalog.bundled.casks) }
            }
        }
    }
}
