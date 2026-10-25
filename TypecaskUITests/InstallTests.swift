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
        XCTAssertTrue(app.staticTexts["Installed"].waitForExistence(timeout: 10))
    }

    /// Accepts the system's font consent sheet if it appears. The system asks only once per app, remembering the answer
    /// even across reinstalls, and the sheet ignores taps while animating in.
    @MainActor
    private func waitForInstall(in app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Excludes the app's own Install button, which can linger for a moment after being tapped.
        let consent = NSPredicate(format: "label == 'Install' AND identifier != 'install'")
        // The sheet isn't consistently in either the app's or SpringBoard's hierarchy.
        let buttons = [app, springboard].map { $0.buttons.matching(consent).firstMatch }
        let deadline = Date.now.addingTimeInterval(120)
        while Date.now < deadline {
            if app.staticTexts["Installed"].exists {
                return true
            }
            if let button = buttons.first(where: { $0.exists && $0.isHittable }) {
                button.tap()
                _ = button.waitForNonExistence(timeout: 3)
            }
        }
        return false
    }

    @MainActor
    private func openCask(in app: XCUIApplication) {
        let card = app.buttons[token]
        for _ in 0..<40 where !(card.exists && card.isHittable) {
            app.swipeUp()
        }
        card.tap()
    }
}
