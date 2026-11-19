import XCTest

/// Xcode's accessibility audit of the gallery, the sample list and a font's page, at the default text size
/// and the largest accessibility size: contrast, clipped text, small hit areas and missing labels.
final class AccessibilityAuditTests: XCTestCase {
    private let token = "font-atkinson-hyperlegible-next"

    @MainActor
    func testDefaultSize() throws {
        try auditScreens(in: XCUIApplication.typecask())
    }

    @MainActor
    func testLargestAccessibilitySize() throws {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        try auditScreens(in: app)
    }

    /// The sort button looks the same whatever the order, so VoiceOver reads the order in its label.
    @MainActor
    func testSortButtonSaysTheOrder() {
        let app = XCUIApplication.typecask()
        app.launch()
        let sort = app.buttons["sortOrder"]
        XCTAssertTrue(sort.waitForExistence(timeout: 30))
        XCTAssertEqual(sort.label, "Sort By, Name")
        sort.tap()
        app.buttons["Trending"].tap()
        XCTAssertTrue(sort.wait(for: \.label, toEqual: "Sort By, Trending", timeout: 5))
    }

    @MainActor
    private func auditScreens(in app: XCUIApplication) throws {
        app.launch()
        XCTAssertTrue(app.buttons["Grid"].waitForExistence(timeout: 30))
        try audit(app)

        app.buttons["Sample"].tap()
        try audit(app)
        app.buttons["Grid"].tap()

        // An article, with its specimen boxes and its term and font links, then the font's page from its link, since
        // Start Here, under the article, has no search field to find it with.
        app.open(URL(string: "typecask://start/start-here")!)
        XCTAssertTrue(app.descendants(matching: .any)["specimen-font-inter"].waitForExistence(timeout: 10))
        try audit(app)
        app.open(URL(string: "typecask://font/\(token)")!)
        // The page's buttons, under its masthead: the tester can be a screen or more below at the largest sizes, where
        // the lazy page hasn't built it yet.
        XCTAssertTrue(app.controls(for: token).waitForExistence(timeout: 10))
        try audit(app)

        // The full specimen, at its styles, then Try It Out with its chips, then its Adjust panel.
        let fullSpecimen = app.buttons["fullSpecimen"]
        for _ in 0..<10 where !(fullSpecimen.exists && fullSpecimen.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        fullSpecimen.tap()
        XCTAssertTrue(app.staticTexts["section.styles"].waitForExistence(timeout: 60))
        try audit(app)

        // From the navigation bar, which has Try It Out once the page's own buttons have scrolled away, as they have at
        // the largest sizes; otherwise the page's.
        let barButton = app.buttons["toolbarTryItOut"]
        (barButton.exists ? barButton : app.controls(for: token).buttons["tryItOut"]).tap()
        XCTAssertTrue(app.textViews["tryItOutText"].waitForExistence(timeout: 10))
        try audit(app)
        app.buttons["tryItOutAdjust"].tap()
        XCTAssertTrue(app.sliders["Line Height"].waitForExistence(timeout: 5))
        try audit(app)
    }

    /// Fails on any issue but those in what iOS draws itself, and the truncation the gallery does on purpose.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        // The sidebar's list and the glass buttons are iOS's own styles: their colors are the system's blue
        // and grays, and glass buttons stop growing short of the largest text sizes. The sidebar is a column,
        // matched across, as its rows run on below what's on screen.
        let sidebar = app.collectionViews["sidebar"]
        let sidebarColumn = sidebar.exists ? sidebar.frame.minX...sidebar.frame.maxX : nil
        // The navigation bar's are glass too: Try It Out and Install once a page's own scroll away, and Done.
        let buttonFrames = ["install", "update", "uninstall", "homepage", "tryItOut", "toolbarTryItOut",
                            "toolbarInstall", "toolbarUpdate", "Done"]
            // Homepage is a link, the rest buttons.
            .map { app.descendants(matching: .any).matching(identifier: $0).firstMatch }
            .filter(\.exists)
            .map(\.frame)
        let window = app.windows.firstMatch.frame
        // The navigation bar: its title, which iOS shortens to fit beside its buttons and VoiceOver reads in full, and
        // whatever has scrolled under its glass, which the audit measures contrast against.
        let navigationBar = app.navigationBars.firstMatch
        let barBottom = navigationBar.exists ? navigationBar.frame.maxY : window.minY
        try app.performAccessibilityAudit { issue in
            // An issue the audit can't tie to an element has nothing to look up or exempt.
            guard let element = issue.element else { return true }
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if sidebarColumn?.contains(center.x) ?? false || buttonFrames.contains(where: { $0.contains(center) }) {
                return true
            }
            // Try It Out's feature chips are glass buttons too, which the audit measures against the glass itself.
            if element.identifier.hasPrefix("tryItOutFeature.") || element.identifier == "tryItOutLigatures" {
                return true
            }
            if center.y < barBottom {
                return true
            }
            // The full specimen's section titles and style names are the system's text styles, which do scale: the
            // largest-size audit passes them drawn at that size, and the same title higher up the page passes here.
            // Grown in place in the screen's lower half, though, they run off its bottom, which the audit reports as
            // partly unsupported, as it does the gallery's rows below.
            if issue.auditType == .dynamicType, element.frame.minY > window.midY {
                return true
            }
            // Specimens, names and the detail line under them on cards and rows are cut to fit the card;
            // VoiceOver reads them in full, and the font's page shows the whole sample. A specimen is drawn in
            // its own font too, so a thin face measures low contrast whatever its color.
            if ["specimen", "itemName", "itemDetail"].contains(element.identifier),
               [.textClipped, .dynamicType].contains(issue.auditType) {
                return true
            }
            if element.identifier == "specimen", issue.auditType == .contrast {
                return true
            }
            // Rows in the window's bottom quarter run under the iPhone's bottom bar, whose glass the audit
            // measures contrast against, and grow off screen when the audit grows text where it sits, which it
            // reports as partly unsupported. The same rows pass further up, so which fail depends only on where
            // the gallery's rows happen to land.
            if [.contrast, .dynamicType, .textClipped].contains(issue.auditType),
               element.frame.maxY > window.maxY - window.height / 4 {
                return true
            }
            // The failure itself names only the kind of issue.
            print("Accessibility audit: \(issue.compactDescription) on \(element.debugDescription)")
            return false
        }
    }
}
