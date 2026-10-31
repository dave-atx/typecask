import AppIntents
import SwiftUI

@main
struct TypecaskApp: App {
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
    }

    var body: some Scene {
        WindowGroup {
            GalleryView(model: model)
                .environment(installer)
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
