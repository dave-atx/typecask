import UIKit

/// The Home Screen's quick actions, in the menu a long press on the app's icon shows: Search Fonts, Installed,
/// Trending, and the font whose page was last open.
///
/// They're dynamic, set each launch, rather than declared in the Info.plist, which the project generates
/// from build settings that can't hold a list. So the first three appear once the app has run.
@MainActor
enum QuickActions {
    private enum Kind: String {
        case search = "org.marquard.Typecask.search"
        case installed = "org.marquard.Typecask.installed"
        case trending = "org.marquard.Typecask.trending"
        case font = "org.marquard.Typecask.font"
    }

    /// The gallery the actions open, set as the app launches, before a scene connects with an action.
    static var gallery: GalleryModel?

    /// Sets the actions, keeping the last font's from an earlier launch.
    static func update() {
        let font = UIApplication.shared.shortcutItems?.first { $0.type == Kind.font.rawValue }
        UIApplication.shared.shortcutItems = fixed + [font].compactMap(\.self)
    }

    /// Makes the cask the last font's action.
    static func remember(_ cask: Cask) {
        let item = UIApplicationShortcutItem(
            type: Kind.font.rawValue,
            localizedTitle: cask.name,
            localizedSubtitle: String(localized: "Last viewed"),
            icon: UIApplicationShortcutIcon(systemImageName: "textformat"),
            userInfo: ["token": cask.token as NSString]
        )
        UIApplication.shared.shortcutItems = fixed + [item]
    }

    /// Opens what the action names. False for one this build doesn't know, or a font it no longer has.
    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard let gallery, let kind = Kind(rawValue: item.type) else { return false }
        switch kind {
        case .search:
            gallery.search("")
        case .installed:
            gallery.browse(.installed)
        case .trending:
            gallery.browse(.allFonts, sortedBy: .trending)
        case .font:
            guard let token = item.userInfo?["token"] as? String,
                  let cask = gallery.catalog.casks.first(where: { $0.token == token }) else { return false }
            gallery.show(cask)
        }
        return true
    }

    private static var fixed: [UIApplicationShortcutItem] {
        [
            UIApplicationShortcutItem(type: Kind.search.rawValue, localizedTitle: String(localized: "Search Fonts"),
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass")),
            UIApplicationShortcutItem(type: Kind.installed.rawValue, localizedTitle: String(localized: "Installed"),
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "checkmark.circle")),
            UIApplicationShortcutItem(type: Kind.trending.rawValue, localizedTitle: String(localized: "Trending"),
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "chart.line.uptrend.xyaxis"))
        ]
    }
}

/// Hands each scene a `QuickActionSceneDelegate`: SwiftUI has no way of its own to receive a quick action.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

/// Receives a quick action, whether it launched the app or brought it forward.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem {
            QuickActions.perform(item)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async
        -> Bool {
        QuickActions.perform(shortcutItem)
    }
}
