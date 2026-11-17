import XCTest

final class DeepLinkTests: XCTestCase {
    /// typecask://font/TOKEN opens the font's page, with or without the token's font-, over whatever was showing.
    @MainActor
    func testSchemeOpensTheFontsPage() {
        let app = XCUIApplication.typecask()
        app.launch()
        XCTAssertTrue(app.buttons["sortOrder"].waitForExistence(timeout: 30))
        app.open(URL(string: "typecask://font/fira-code")!)
        XCTAssertTrue(app.navigationBars["Fira Code"].waitForExistence(timeout: 10))
        app.open(URL(string: "typecask://font/font-roboto")!)
        XCTAssertTrue(app.navigationBars["Roboto"].waitForExistence(timeout: 10))
    }
}
