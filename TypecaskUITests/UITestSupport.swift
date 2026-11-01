import XCTest

extension XCUIApplication {
    /// The app, with the App Store rating prompt held back: a debug build always shows it, over the next tap.
    @MainActor
    static func typecask() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TYPECASK_NO_REVIEW"] = "1"
        return app
    }

    @MainActor
    func openCask(_ token: String) {
        findCask(token).tap()
    }

    /// Searches for the cask's card rather than scrolling to it: sorted by name, the catalog runs to hundreds
    /// of casks.
    @MainActor
    func findCask(_ token: String) -> XCUIElement {
        let search = searchFields.firstMatch
        // Where the toolbar has no room for the field, as on an 11-inch iPad, it's a Search button.
        let searchButton = buttons["Search"]
        let launched = Date.now
        while !search.exists, !searchButton.exists, Date.now.timeIntervalSince(launched) < 30 {
            _ = search.waitForExistence(timeout: 1)
        }
        if !search.exists {
            searchButton.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(token)
        let card = buttons[token]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        return card
    }
}
