import XCTest

final class StartHereTests: XCTestCase {
    /// The app opens on Start Here the first time, an article's specimen line opens its font's page, and the
    /// next launch comes back to that page, with the article and Start Here behind it.
    @MainActor
    func testStartHereOpensAnArticleAndComesBack() {
        let app = XCUIApplication.typecask()
        // As on a first launch: no last page.
        app.launchArguments += ["-lastPage", "start"]
        app.launch()
        let article = app.buttons["article-start-here"]
        XCTAssertTrue(article.waitForExistence(timeout: 30))
        article.tap()
        let specimen = app.descendants(matching: .any)["specimen-font-inter"]
        XCTAssertTrue(specimen.waitForExistence(timeout: 10))
        specimen.tap()
        XCTAssertTrue(app.navigationBars["Inter"].waitForExistence(timeout: 10))

        // Without the launch argument, so the page the app saved is the one it reads.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-lastPage" || $0 == "start" || $0 == "collection:allFonts" }
        app.launch()
        XCTAssertTrue(app.navigationBars["Inter"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["specimen-font-inter"].waitForExistence(timeout: 10))
    }

    /// The font's name in the paragraph after its line opens its page, as the line's box does.
    @MainActor
    func testFontsNameInTheParagraphOpensItsPage() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "start|article:start-here"]
        app.launch()
        let link = app.links["Inter"]
        XCTAssertTrue(link.waitForExistence(timeout: 30))
        link.tap()
        XCTAssertTrue(app.navigationBars["Inter"].waitForExistence(timeout: 10))
    }

    /// A type term in an article shows its definition in a popover, without leaving the article.
    @MainActor
    func testTermShowsItsDefinition() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "start|article:start-here"]
        app.launch()
        let link = app.links["x-height"]
        XCTAssertTrue(link.waitForExistence(timeout: 30))
        link.tap()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 10))
        XCTAssertTrue(popover.staticTexts["x-height"].exists)
        XCTAssertTrue(popover.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The height of lowercase'"))
            .firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["specimen-font-inter"].exists)
    }

    /// A collection named in an article opens that collection.
    @MainActor
    func testCollectionLinkOpensTheCollection() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "start|article:start-here"]
        app.launch()
        let link = app.links["Legibility"]
        XCTAssertTrue(app.descendants(matching: .any)["specimen-font-inter"].waitForExistence(timeout: 30))
        for _ in 0..<12 where !link.isHittable {
            app.swipeUp()
        }
        link.tap()
        XCTAssertTrue(app.staticTexts["collectionSummary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Legibility"].exists)
    }
}
