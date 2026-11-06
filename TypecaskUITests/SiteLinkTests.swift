import XCTest

/// typecask.app's pages opened in the app, as a universal link or Safari's Smart App Banner opens them.
/// `XCUIApplication.open` hands the app the URL directly, so these don't depend on Apple's CDN having
/// fetched the site's apple-app-site-association.
final class SiteLinkTests: XCTestCase {
    /// A font's page opens the font's page, with the app already running on another one.
    @MainActor
    func testFontPageOpensTheFont() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-roboto")
        XCTAssertTrue(app.navigationBars["Roboto"].waitForExistence(timeout: 10))

        app.open(URL(string: "https://typecask.app/fonts/lexend/")!)
        XCTAssertTrue(app.sliders["specimenSize"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Lexend"].waitForExistence(timeout: 10))
    }

    /// A font's page launches the app to the font when it wasn't running.
    @MainActor
    func testFontPageLaunchesTheApp() {
        let app = XCUIApplication.typecask()
        app.open(URL(string: "https://typecask.app/fonts/lexend/")!)
        XCTAssertTrue(app.navigationBars["Lexend"].waitForExistence(timeout: 30))
    }

    /// A style's page opens that collection.
    @MainActor
    func testStylePageOpensTheCollection() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.open(URL(string: "https://typecask.app/styles/fixed-width/")!)
        XCTAssertTrue(app.navigationBars["Fixed Width"].waitForExistence(timeout: 10))
    }

    /// A font this build doesn't carry, as the site can list before the app ships it, becomes a search.
    @MainActor
    func testUnknownFontSearches() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.open(URL(string: "https://typecask.app/fonts/no-such-typeface/")!)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "no such typeface")
    }
}
