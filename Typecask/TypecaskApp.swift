import SwiftUI

@main
struct TypecaskApp: App {
    @State private var installer = FontInstaller()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            GalleryView(catalog: .bundled)
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
