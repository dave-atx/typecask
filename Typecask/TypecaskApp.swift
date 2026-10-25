import SwiftUI

@main
struct TypecaskApp: App {
    @State private var installer = FontInstaller()

    var body: some Scene {
        WindowGroup {
            GalleryView(catalog: .bundled)
                .environment(installer)
                .task { installer.refresh(Catalog.bundled.casks) }
        }
    }
}
