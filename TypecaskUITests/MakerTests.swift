import XCTest

/// Foundries and Designers: their indexes, a maker's page, and the links to it from a font's page. TypeTogether and
/// Literata, Łukasz Dziedzic and Lato, from Google Fonts' credits, which scripts/makers.json sorts.
final class MakerTests: XCTestCase {
    /// A foundry found in the index opens its page, which shows its fonts.
    @MainActor
    func testFoundryIndexOpensItsFonts() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "makers:foundry"]
        app.launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("TypeTogether")
        let row = app.buttons["makerRow.TypeTogether"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["makerPage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.card(for: "font-literata").waitForExistence(timeout: 10), "Literata isn't TypeTogether's")
    }

    /// A designer's name on a font's page opens the designer's page, whose fonts include that one.
    @MainActor
    func testFontPageLinksToItsDesigner() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "collection:allFonts|font:font-lato"]
        app.launch()
        let link = app.buttons["maker.Łukasz Dziedzic"]
        XCTAssertTrue(link.waitForExistence(timeout: 30))
        link.tap()
        XCTAssertTrue(app.navigationBars["Łukasz Dziedzic"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.card(for: "font-lato").waitForExistence(timeout: 10))
    }

    /// A designer's name in an article opens the designer's page.
    @MainActor
    func testArticleLinksToItsDesigner() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "start|article:start-here"]
        app.launch()
        let link = app.links["Rasmus Andersson"]
        for _ in 0..<10 where !(link.exists && link.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Start Here has no link to Rasmus Andersson")
        link.tap()
        XCTAssertTrue(app.navigationBars["Rasmus Andersson"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.card(for: "font-inter").waitForExistence(timeout: 10))
    }

    /// A maker's page is where the app reopens, as any other page is.
    @MainActor
    func testMakerPageIsRemembered() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "makers:designer|designer:Łukasz Dziedzic"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Łukasz Dziedzic"].waitForExistence(timeout: 30))
    }
}
