import XCTest

final class LigatureTests: XCTestCase {
    /// A coding face's page offers a switch that turns its ligatures off in the samples and back on; a page for a
    /// face without them has none. Keeps a screenshot of each state, to see the samples change.
    @MainActor
    func testLigaturesTurnOffAndOn() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-fira-code")
        let toggle = app.switches["ligatures"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        // Under the page's masthead, below the screen on an iPhone, or under its bottom bar, which takes the tap. Short
        // drags bring it into the screen's top part without overshooting it.
        let window = app.windows.firstMatch
        for _ in 0..<12 where !(toggle.isHittable && toggle.frame.maxY < window.frame.height * 0.6) {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertEqual(toggle.value as? String, "1")
        keep(app.screenshot(), named: "ligatures-on")

        // The switch's own frame is the whole row; its control is at the trailing end.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue("0", of: toggle))
        keep(app.screenshot(), named: "ligatures-off")

        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue("1", of: toggle))
    }

    @MainActor
    func testFaceWithoutLigaturesHasNoSwitch() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-roboto")
        // Text, or a button where it opens Try It Out.
        XCTAssertTrue(app.descendants(matching: .any)["specimen"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["ligatures"].exists)
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.value as? String == value {
                return true
            }
            _ = element.waitForNonExistence(timeout: 0.5)
        }
        return false
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
