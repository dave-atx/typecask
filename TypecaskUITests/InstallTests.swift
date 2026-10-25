import XCTest

final class InstallTests: XCTestCase {
    /// The cask to install, which needs font assets (see README); override with
    /// `TEST_RUNNER_TYPECASK_CASK=<token> xcodebuild test`.
    private let token = ProcessInfo.processInfo.environment["TYPECASK_CASK"] ?? "font-departure-mono-nerd-font"

    @MainActor
    func testInstalledCaskStaysInstalledAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        openCask(in: app)
        app.buttons["install"].tap()
        XCTAssertTrue(waitForInstall(in: app))

        app.terminate()
        app.launch()
        openCask(in: app)
        XCTAssertTrue(app.buttons["uninstall"].waitForExistence(timeout: 10))
    }

    /// Installs the cask, uninstalls it, and checks it stays uninstalled after a relaunch. Run it on its own
    /// cask: it leaves that cask uninstalled.
    @MainActor
    func testUninstalledCaskStaysUninstalledAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        openCask(in: app)
        if app.buttons["install"].waitForExistence(timeout: 10) {
            app.buttons["install"].tap()
            XCTAssertTrue(waitForInstall(in: app))
        }
        app.buttons["uninstall"].tap()
        XCTAssertTrue(app.buttons["install"].waitForExistence(timeout: 30))

        app.terminate()
        app.launch()
        openCask(in: app)
        XCTAssertTrue(app.buttons["install"].waitForExistence(timeout: 10))
    }

    /// Installs the cask, relaunches with it marked outdated, and updates it. A debug build reads TYPECASK_OUTDATED,
    /// since a real update needs two releases of the font.
    @MainActor
    func testOutdatedCaskUpdates() {
        let app = XCUIApplication()
        app.launch()
        openCask(in: app)
        if app.buttons["install"].waitForExistence(timeout: 10) {
            app.buttons["install"].tap()
            XCTAssertTrue(waitForInstall(in: app))
        }

        app.terminate()
        app.launchEnvironment["TYPECASK_OUTDATED"] = token
        app.launch()
        openCask(in: app)
        XCTAssertTrue(app.buttons["update"].waitForExistence(timeout: 10))
        app.buttons["update"].tap()
        XCTAssertTrue(waitForInstall(in: app))
        XCTAssertFalse(app.buttons["update"].exists)
    }

    /// A cask whose primary face iOS already has under the same PostScript name can't be registered (Core Text
    /// error 305, duplicated name), so the app says it's built in instead of offering an Install that fails.
    @MainActor
    func testCaskBuiltIntoIOSOffersNoInstall() {
        let app = XCUIApplication()
        app.launch()
        openCask("font-noto-sans-armenian", in: app)
        XCTAssertTrue(app.staticTexts["Built into iOS"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["install"].exists)
    }

    /// Waits for the Uninstall button, which only an installed cask has; with an Installed collection in the
    /// sidebar, the word alone proves nothing. Accepts the system's font consent sheet if it appears. The system
    /// asks only once per app, remembering the answer even across reinstalls, and the sheet ignores taps while
    /// animating in.
    @MainActor
    private func waitForInstall(in app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Excludes the app's own Install button, which can linger for a moment after being tapped.
        let consent = NSPredicate(format: "label == 'Install' AND identifier != 'install'")
        // The sheet isn't consistently in either the app's or SpringBoard's hierarchy.
        let buttons = [app, springboard].map { $0.buttons.matching(consent).firstMatch }
        let deadline = Date.now.addingTimeInterval(120)
        while Date.now < deadline {
            if app.buttons["uninstall"].exists {
                return true
            }
            if let button = buttons.first(where: { $0.exists && $0.isHittable }) {
                button.tap()
                _ = button.waitForNonExistence(timeout: 3)
            }
        }
        return false
    }

    /// Searches for the card rather than scrolling to it: sorted by name, the catalog runs to hundreds of casks.
    @MainActor
    private func openCask(_ token: String? = nil, in app: XCUIApplication) {
        let token = token ?? self.token
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText(token)
        let card = app.buttons[token]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
    }
}
