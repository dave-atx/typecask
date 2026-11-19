import XCTest

/// A font's page as a type specimen: the full fonts it loads when asked, the sections they add below the tester, the
/// ways into Try It Out from it, and the navigation bar's buttons once the page's own scroll away. Roboto for its
/// styles, a variable font's named instances; Fira Code for its features. Both are in the debug build's fonts.
final class SpecimenTests: XCTestCase {
    /// Asking for the full specimen adds its sections and leaves the tester as it was.
    @MainActor
    func testFullSpecimenAddsItsSections() {
        let app = openFullSpecimen("font-roboto")
        // Text, or a button where it opens Try It Out.
        XCTAssertTrue(app.descendants(matching: .any)["specimen"].exists, "the tester's sample went")
        XCTAssertTrue(app.sliders["specimenSize"].exists, "the tester's size went")
        let styles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'specimenStyle.'"))
        XCTAssertGreaterThan(styles.count, 1, "a variable font lists its named instances")
        for section in ["section.setting", "section.characters", "section.languages"] {
            XCTAssertTrue(scroll(to: app.staticTexts[section], in: app), "no \(section)")
        }
        keep(app.screenshot(), named: "roboto-full-specimen")
    }

    /// Tapping the sample opens Try It Out.
    @MainActor
    func testSampleOpensTryItOut() {
        let app = openFullSpecimen("font-roboto")
        let sample = app.descendants(matching: .any)["specimen"]
        XCTAssertTrue(scroll(to: sample, in: app, upward: true))
        sample.tap()
        XCTAssertTrue(app.textViews["tryItOutText"].waitForExistence(timeout: 10))
    }

    /// Tapping a style opens Try It Out in that style.
    @MainActor
    func testStyleOpensTryItOutInThatStyle() {
        let app = openFullSpecimen("font-roboto")
        // Not the first, which may be the regular Try It Out starts in anyway.
        let row = app.descendants(matching: .any)["specimenStyle.3"]
        XCTAssertTrue(scroll(to: row, in: app))
        let name = row.label
        row.tap()
        XCTAssertTrue(app.textViews["tryItOutText"].waitForExistence(timeout: 10))
        let style = app.buttons["tryItOutStyle"]
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        XCTAssertTrue(style.label.hasSuffix(name), "\(style.label) isn't in \(name)")
    }

    /// Tapping a feature opens Try It Out with it on, and its line at the top of the text.
    @MainActor
    func testFeatureOpensTryItOutWithItOn() {
        let app = openFullSpecimen("font-fira-code")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'specimenFeature.'")).firstMatch
        XCTAssertTrue(scroll(to: row, in: app), "Fira Code shows no features")
        let tag = String(row.identifier.dropFirst("specimenFeature.".count))
        let line = row.label
        row.tap()
        let text = app.textViews["tryItOutText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String ?? "").hasPrefix(line), "the text doesn't start with \(line)")
        XCTAssertTrue(isOn(app.descendants(matching: .any)["tryItOutFeature.\(tag)"]), "\(tag) isn't on")
        keep(app.screenshot(), named: "fira-code-\(tag)")
    }

    /// A feature's chip turns it on and off.
    @MainActor
    func testFeatureChipTurnsOn() {
        let app = openFullSpecimen("font-fira-code")
        app.controls(for: "font-fira-code").buttons["tryItOut"].tap()
        XCTAssertTrue(app.textViews["tryItOutText"].waitForExistence(timeout: 10))
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tryItOutFeature.'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertFalse(isOn(chip))
        chip.tap()
        XCTAssertTrue(wait(for: chip, isOn: true))
        chip.tap()
        XCTAssertTrue(wait(for: chip, isOn: false))
    }

    /// The character tapped shows in the detail above the grid, which stays in sight as the grid scrolls by.
    @MainActor
    func testCharacterDetailFollowsTheGrid() {
        let app = openFullSpecimen("font-roboto")
        let detail = app.descendants(matching: .any)["characterDetail"]
        XCTAssertTrue(scroll(to: detail, in: app))
        let letter = app.buttons["Latin Capital Letter B"]
        XCTAssertTrue(scroll(to: letter, in: app))
        letter.tap()
        XCTAssertTrue(detail.wait(for: \.label, toEqual: "Latin Capital Letter B, U+0042", timeout: 5),
                      "the detail reads \(detail.label)")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(detail.isHittable, "the detail scrolled away with the grid")
    }

    /// Once the page's Install and Try It Out scroll away, the navigation bar has them; scrolled back, it doesn't.
    @MainActor
    func testNavigationBarKeepsTryItOutOnceScrolled() {
        let app = openFullSpecimen("font-roboto")
        let pageButton = app.controls(for: "font-roboto").buttons["tryItOut"]
        let barButton = app.buttons["toolbarTryItOut"]
        for _ in 0..<10 where pageButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(barButton.waitForExistence(timeout: 5), "the bar has no Try It Out")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(barButton.isHittable, "the bar's Try It Out went as the page scrolled on")
        barButton.tap()
        XCTAssertTrue(app.textViews["tryItOutText"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        for _ in 0..<15 where !pageButton.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(barButton.waitForNonExistence(timeout: 5), "the bar kept Try It Out with the page's in sight")
    }

    /// On iPhone, Adjust puts the keyboard away so its half sheet shows over the text, and typing again closes it.
    @MainActor
    func testAdjustPutsTheKeyboardAway() throws {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-roboto")
        let button = app.controls(for: "font-roboto").buttons["tryItOut"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if app.windows.firstMatch.horizontalSizeClass == .regular {
            throw XCTSkip("On iPad, Adjust is a panel beside the text, and the keyboard stays.")
        }
        button.tap()
        let text = app.textViews["tryItOutText"]
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        text.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["tryItOutAdjust"].tap()
        let lineHeight = app.sliders["Line Height"]
        XCTAssertTrue(lineHeight.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard stayed over Adjust")
        text.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(lineHeight.waitForNonExistence(timeout: 5), "Adjust stayed behind the keyboard")
    }

    /// On iPhone in landscape, Adjust is a column beside the text rather than a sheet, which there would be the
    /// screen's whole height and cover the text it changes.
    @MainActor
    func testAdjustLeavesTheTextInSightInLandscape() throws {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-roboto")
        let button = app.controls(for: "font-roboto").buttons["tryItOut"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if app.windows.firstMatch.horizontalSizeClass == .regular {
            throw XCTSkip("On iPad, Adjust is a panel beside the text in either orientation.")
        }
        button.tap()
        let text = app.textViews["tryItOutText"]
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["tryItOutAdjust"].tap()
        XCTAssertTrue(app.sliders["Line Height"].waitForExistence(timeout: 5))
        XCTAssertTrue(text.isHittable, "Adjust covered the text")
    }

    /// On iPhone, Adjust's half sheet scrolls to every one of Shantell Sans's four axes without growing over the text
    /// they change.
    @MainActor
    func testAdjustReachesEveryAxisWithTheTextInSight() throws {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("font-shantell-sans")
        let button = app.controls(for: "font-shantell-sans").buttons["tryItOut"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if app.windows.firstMatch.horizontalSizeClass == .regular {
            throw XCTSkip("On iPad, Adjust is a panel beside the text, as tall as the screen.")
        }
        button.tap()
        let text = app.textViews["tryItOutText"]
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        app.buttons["tryItOutAdjust"].tap()
        let lineHeight = app.sliders["Line Height"]
        XCTAssertTrue(lineHeight.waitForExistence(timeout: 5))
        // Below the sliders' track, so the swipe scrolls the sheet rather than moving one.
        let sheet = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9))
        for axis in ["Weight", "Informality", "Bounce", "Spacing"] {
            let slider = app.sliders[axis]
            for _ in 0..<6 where !(slider.exists && slider.isHittable) {
                sheet.press(forDuration: 0.05, thenDragTo: sheet.withOffset(CGVector(dx: 0, dy: -150)))
            }
            XCTAssertTrue(slider.isHittable, "no way to reach \(axis)")
            XCTAssertTrue(text.isHittable, "the sheet grew over the text to reach \(axis)")
        }
        keep(app.screenshot(), named: "shantell-sans-adjust")
    }

    /// A family built into iOS has a full specimen of its own, from the faces on the device, and opens Try It Out.
    @MainActor
    func testBuiltInAppleFamilyHasASpecimen() {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask("Baskerville")
        XCTAssertTrue(app.staticTexts["section.styles"].waitForExistence(timeout: 15), "no full specimen")
        XCTAssertGreaterThan(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'specimenStyle.'")).count, 1)
        XCTAssertTrue(scroll(to: app.staticTexts["section.characters"], in: app), "no characters")
        let button = app.buttons["tryItOut"].firstMatch
        XCTAssertTrue(scroll(to: button, in: app, upward: true))
        button.tap()
        XCTAssertTrue(app.textViews["tryItOutText"].waitForExistence(timeout: 10))
        keep(app.screenshot(), named: "baskerville-try-it-out")
    }

    /// Opens the cask's page and asks for its full specimen, waiting for the styles it adds.
    @MainActor
    private func openFullSpecimen(_ token: String) -> XCUIApplication {
        let app = XCUIApplication.typecask()
        app.launch()
        app.openCask(token)
        let styles = app.staticTexts["section.styles"]
        // An installed cask's page loads it unasked.
        let button = app.buttons["fullSpecimen"]
        if !styles.waitForExistence(timeout: 3) {
            XCTAssertTrue(scroll(to: button, in: app), "no Show Full Specimen")
            button.tap()
        }
        XCTAssertTrue(styles.waitForExistence(timeout: 60), "the full specimen didn't load")
        return app
    }

    /// Swipes until the element is on screen, in a lazy stack that builds it only as it nears.
    @MainActor
    private func scroll(to element: XCUIElement, in app: XCUIApplication, swipes: Int = 30,
                        upward: Bool = false) -> Bool {
        for _ in 0..<swipes {
            if element.exists, element.isHittable {
                return true
            }
            if upward {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
        return element.exists && element.isHittable
    }

    /// A toggle's value is 1 or "1" depending on how it's drawn.
    private func isOn(_ element: XCUIElement) -> Bool {
        "\(element.value ?? "")" == "1"
    }

    @MainActor
    private func wait(for element: XCUIElement, isOn expected: Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if isOn(element) == expected {
                return true
            }
            _ = element.waitForNonExistence(timeout: 0.3)
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
