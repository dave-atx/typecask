import XCTest

/// The Home Screen's quick actions, chosen from the menu a long press on the app's icon shows.
final class QuickActionTests: XCTestCase {
    /// With the app in the background, Installed opens that collection.
    @MainActor
    func testInstalledOpensItsCollection() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-roboto")
        choose("Installed")
        XCTAssertTrue(app.navigationBars["Installed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.sliders["specimenSize"].exists)
    }

    /// The last font viewed reopens its page, here launching the app to do it.
    @MainActor
    func testLastFontReopensItsPage() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-roboto")
        XCTAssertTrue(app.sliders["specimenSize"].waitForExistence(timeout: 10))
        app.terminate()
        choose("Roboto")
        XCTAssertTrue(app.sliders["specimenSize"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.navigationBars["Roboto"].exists)
    }

    /// Search Fonts opens the gallery's search field, ready to type in.
    @MainActor
    func testSearchFocusesTheField() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-roboto")
        choose("Search Fonts")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true)
    }

    /// Long-presses the app's icon on the Home Screen, which may be a page or two along, and picks `title`.
    /// Slow: XCUITest waits a minute, twice, for SpringBoard's animations to finish, which it never reports.
    @MainActor
    private func choose(_ title: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        // On iPad the Dock's recent apps can hold a second icon.
        let icons = springboard.icons.matching(identifier: "Typecask")
        XCTAssertTrue(icons.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<5 where !icons.allElementsBoundByIndex.contains(where: \.isHittable) {
            springboard.swipeLeft()
        }
        let icon = icons.allElementsBoundByIndex.first(where: \.isHittable) ?? icons.firstMatch
        icon.press(forDuration: 1.5)
        // The font's action is labeled with its subtitle too, "Roboto, Last viewed".
        let action = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
    }
}
