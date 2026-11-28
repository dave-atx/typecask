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
        // By its identifier: on iPhone Duo's outer display the back button isn't inside the navigation bar.
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["specimen-font-inter"].waitForExistence(timeout: 10))
    }

    /// Start Here in the sidebar goes back to Start Here from a font opened in an article, rather than leaving the
    /// font showing because Start Here was already the sidebar's choice. iPad only: on iPhone the sidebar is behind
    /// every page pushed over it.
    @MainActor
    func testStartHereInTheSidebarLeavesTheFont() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The sidebar shows beside a page only on iPad.")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "start|article:start-here"]
        app.launch()
        let link = app.links["Inter"]
        XCTAssertTrue(link.waitForExistence(timeout: 30))
        link.tap()
        XCTAssertTrue(app.navigationBars["Inter"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["startHere"].firstMatch.tap()
        XCTAssertTrue(app.buttons["article-start-here"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Inter"].exists)
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
        // It points at the term, just above or below it, rather than at the middle of the paragraph.
        let term = link.frame, box = popover.frame
        XCTAssertTrue(box.minX <= term.midX && term.midX <= box.maxX, "\(box) isn't over \(term)")
        XCTAssertTrue(abs(box.maxY - term.minY) < 12 || abs(box.minY - term.maxY) < 12, "\(box) is far from \(term)")
        XCTAssertTrue(popover.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The height of lowercase'"))
            .firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["specimen-font-inter"].exists)
    }

    /// Another article named in an article opens it over the first, and a link to the web, which the site has,
    /// is plain text in the app.
    @MainActor
    func testArticleLinkOpensTheArticle() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "start|article:workhorses"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["specimen-font-inter"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.links["Android's system font since 2011"].exists)
        let link = app.links["Inspired by the classics"].firstMatch
        for _ in 0..<12 where !link.isHittable {
            app.swipeUp()
        }
        link.tap()
        XCTAssertTrue(app.navigationBars["Inspired by the classics"].waitForExistence(timeout: 10))
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
