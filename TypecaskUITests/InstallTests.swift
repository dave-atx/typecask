import AppIntentsTesting
import XCTest

final class InstallTests: XCTestCase {
    /// The cask to install, which needs font assets (see README); override with
    /// `TEST_RUNNER_TYPECASK_CASK=<token> xcodebuild test`.
    private let token = ProcessInfo.processInfo.environment["TYPECASK_CASK"] ?? "font-departure-mono-nerd-font"

    @MainActor
    func testInstalledCaskStaysInstalledAfterRelaunch() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        app.buttons["install"].tap()
        XCTAssertTrue(waitForInstall(in: app))

        app.terminate()
        app.launch()
        app.openCask(token)
        XCTAssertTrue(app.buttons["uninstall"].waitForExistence(timeout: 10))
    }

    /// Installs the cask, uninstalls it, and checks it stays uninstalled after a relaunch. Run it on its own
    /// cask: it leaves that cask uninstalled.
    @MainActor
    func testUninstalledCaskStaysUninstalledAfterRelaunch() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        if app.buttons["install"].waitForExistence(timeout: 10) {
            app.buttons["install"].tap()
            XCTAssertTrue(waitForInstall(in: app))
        }
        app.buttons["uninstall"].tap()
        XCTAssertTrue(app.buttons["install"].waitForExistence(timeout: 30))

        app.terminate()
        app.launch()
        app.openCask(token)
        XCTAssertTrue(app.buttons["install"].waitForExistence(timeout: 10))
    }

    /// Installs the cask, relaunches with it marked outdated, and updates it. A debug build reads TYPECASK_OUTDATED,
    /// since a real update needs two releases of the font.
    @MainActor
    func testOutdatedCaskUpdates() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        if app.buttons["install"].waitForExistence(timeout: 10) {
            app.buttons["install"].tap()
            XCTAssertTrue(waitForInstall(in: app))
        }

        app.terminate()
        app.launchEnvironment["TYPECASK_OUTDATED"] = token
        app.launch()
        app.openCask(token)
        XCTAssertTrue(app.buttons["update"].waitForExistence(timeout: 10))
        app.buttons["update"].tap()
        XCTAssertTrue(waitForInstall(in: app))
        XCTAssertFalse(app.buttons["update"].exists)
    }

    /// Installs the cask the way Shortcuts and Siri do, through InstallFontIntent, which opens the cask's page
    /// for the consent sheet and the download. Uninstalls it first if an earlier test left it installed, then
    /// relaunches, so the shortcut starts from the gallery.
    @MainActor
    func testShortcutInstallsCask() async throws {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        if app.buttons["uninstall"].waitForExistence(timeout: 10) {
            app.buttons["uninstall"].tap()
            XCTAssertTrue(app.buttons["install"].waitForExistence(timeout: 30))
        }
        app.terminate()
        app.launch()

        let definitions = IntentDefinitions(bundleIdentifier: "org.marquard.Typecask")
        let fonts = definitions.entities["FontEntity"]
        let intent = definitions.intents["InstallFontIntent"].makeIntent(font: fonts.makeReference(identifier: token))
        let run = Task.detached { try await intent.run() }
        XCTAssertTrue(waitForInstall(in: app))
        // A returned entity carries its properties but not its ID, so it's checked by name.
        let installed: String = try await run.value.value.name
        let found = try await fonts.entities(identifiers: [token])
        let expected: String = try XCTUnwrap(found.first).name
        XCTAssertEqual(installed, expected)
    }

    /// Installs the cask from its card's menu, without opening its page, then uninstalls it the same way.
    @MainActor
    func testCardMenuInstallsAndUninstallsCask() {
        let app = XCUIApplication.typecask()
        app.launch()
        let card = app.findCask(token)
        if card.value as? String == "Installed" {
            card.press(forDuration: 1)
            app.buttons["Uninstall"].tap()
            XCTAssertTrue(waitForValue(nil, of: card))
        }

        card.press(forDuration: 1)
        app.buttons["Install"].tap()
        XCTAssertTrue(waitForInstall(in: app) { card.value as? String == "Installed" })

        card.press(forDuration: 1)
        XCTAssertFalse(app.buttons["Install"].exists)
        app.buttons["Uninstall"].tap()
        XCTAssertTrue(waitForValue(nil, of: card))
    }

    /// ⌘D installs the cask whose page is showing, from the File menu, and does nothing once it's installed.
    @MainActor
    func testKeyboardInstallsCask() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        if app.buttons["uninstall"].waitForExistence(timeout: 10) {
            app.buttons["uninstall"].tap()
            XCTAssertTrue(app.buttons["install"].waitForExistence(timeout: 30))
        }
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(waitForInstall(in: app))
        app.typeKey("d", modifierFlags: .command)
        XCTAssertFalse(app.buttons["uninstall"].waitForNonExistence(timeout: 3))
    }

    /// "Install this font with Typecask" on a font's page: given no font, the intent installs the one showing.
    @MainActor
    func testShortcutInstallsCaskOnScreen() async throws {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        if app.buttons["uninstall"].waitForExistence(timeout: 10) {
            app.buttons["uninstall"].tap()
            XCTAssertTrue(app.buttons["install"].waitForExistence(timeout: 30))
        }

        let definitions = IntentDefinitions(bundleIdentifier: "org.marquard.Typecask")
        let intent = definitions.intents["InstallFontIntent"].makeIntent()
        let run = Task.detached { try await intent.run() }
        XCTAssertTrue(waitForInstall(in: app))
        let installed: String = try await run.value.value.name
        let found = try await definitions.entities["FontEntity"].entities(identifiers: [token])
        let expected: String = try XCTUnwrap(found.first).name
        XCTAssertEqual(installed, expected)
    }

    /// A cask whose primary face iOS already has under the same PostScript name can't be registered (Core Text
    /// error 305, duplicated name), so the app says it's built in instead of offering an Install that fails.
    @MainActor
    func testCaskBuiltIntoIOSOffersNoInstall() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-noto-sans-armenian")
        XCTAssertTrue(app.staticTexts["Built into iOS"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["install"].exists)
    }

    /// Opens the cask's license, which the app inflates from Licenses.deflate when it's first shown.
    @MainActor
    func testLicenseShows() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        let disclosure = app.buttons["License"]
        // Below the description and details, off screen on a smaller device.
        for _ in 0..<6 where !(disclosure.exists && disclosure.isHittable) {
            app.swipeUp()
        }
        disclosure.tap()
        let license = app.staticTexts["licenseText"]
        XCTAssertTrue(license.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(license.label.count, 100)
    }

    /// Waits for `installed`, by default the Uninstall button, which only an installed cask's page has; with an
    /// Installed collection in the sidebar, the word alone proves nothing. Accepts the system's font consent
    /// sheet if it appears. The system asks only once per app, remembering the answer even across reinstalls,
    /// and the sheet ignores taps while animating in.
    @MainActor
    private func waitForInstall(in app: XCUIApplication,
                                until installed: (() -> Bool)? = nil) -> Bool {
        let installed = installed ?? { app.buttons["uninstall"].exists }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Excludes the app's own Install button, which can linger for a moment after being tapped.
        let consent = NSPredicate(format: "label == 'Install' AND identifier != 'install'")
        // The sheet isn't consistently in either the app's or SpringBoard's hierarchy.
        let buttons = [app, springboard].map { $0.buttons.matching(consent).firstMatch }
        let deadline = Date.now.addingTimeInterval(120)
        while Date.now < deadline {
            if installed() {
                return true
            }
            if let button = buttons.first(where: { $0.exists && $0.isHittable }) {
                button.tap()
                _ = button.waitForNonExistence(timeout: 3)
            }
        }
        return false
    }

    /// Waits for a card's status, which VoiceOver reads as its value: nil, or empty, for an available cask.
    @MainActor
    private func waitForValue(_ value: String?, of card: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            let current = (card.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            if current == value {
                return true
            }
            _ = card.waitForNonExistence(timeout: 1)
        }
        return false
    }
}
