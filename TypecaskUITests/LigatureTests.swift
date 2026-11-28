import XCTest

final class LigatureTests: XCTestCase {
    /// A coding face's Try It Out has a Ligatures chip, which turns them off and on; a face without them has none.
    /// Keeps a screenshot of each state, to see the text change.
    @MainActor
    func testLigaturesTurnOffAndOn() {
        let app = openTryItOut("font-fira-code")
        let chip = app.descendants(matching: .any)["tryItOutLigatures"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        keep(app.screenshot(), named: "ligatures-on")
        chip.tap()
        keep(app.screenshot(), named: "ligatures-off")
        chip.tap()
    }

    @MainActor
    func testFaceWithoutLigaturesHasNoChip() {
        let app = openTryItOut("font-roboto")
        XCTAssertFalse(app.descendants(matching: .any)["tryItOutLigatures"].exists)
    }

    @MainActor
    private func openTryItOut(_ token: String) -> XCUIApplication {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        let button = app.controls(for: token).buttons["tryItOut"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.textViews["tryItOutText"].waitForExistence(timeout: 60))
        return app
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
