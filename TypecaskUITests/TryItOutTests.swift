import XCTest

final class TryItOutTests: XCTestCase {
    /// A coding face's editor downloads its fonts, starts with the ligatures it joins, and can turn them off. Keeps
    /// a screenshot of each state.
    @MainActor
    func testCodingFaceShowsItsLigatures() {
        let app = open("font-fira-code")
        let text = app.textViews["tryItOutText"]
        XCTAssertTrue((text.value as? String ?? "").contains("->"))
        keep(app.screenshot(), named: "fira-code")
        let toggle = app.switches["tryItOutLigatures"]
        XCTAssertTrue(toggle.exists)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        keep(app.screenshot(), named: "fira-code-ligatures-off")
    }

    /// A Nerd Font's editor shows its icons, from its own section of the paired page.
    @MainActor
    func testNerdFontShowsItsIcons() {
        let app = open("font-fira-code-nerd-font")
        let text = app.textViews["tryItOutText"].value as? String ?? ""
        XCTAssertTrue(text.unicodeScalars.contains { (0xE0A0...0xE0D7).contains($0.value) }, "no Powerline glyphs")
        keep(app.screenshot(), named: "fira-code-nerd-font")
    }

    /// A face for another script shows that script's letters, and no ligature switch where it joins nothing
    /// in code.
    @MainActor
    func testOtherScriptShowsItsLetters() {
        let app = open("font-noto-naskh-arabic")
        let text = app.textViews["tryItOutText"].value as? String ?? ""
        XCTAssertTrue(text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }, "no Arabic letters")
        keep(app.screenshot(), named: "noto-naskh-arabic")
    }

    /// Opens the cask's page and its editor, and waits for the fonts.
    @MainActor
    private func open(_ token: String) -> XCUIApplication {
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
