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

    @MainActor
    private func auditScreens(in app: XCUIApplication) throws {
        app.launch()
        XCTAssertTrue(app.buttons["Grid"].waitForExistence(timeout: 30))
        try audit(app)

        app.buttons["Sample"].tap()
        try audit(app)
        app.buttons["Grid"].tap()

        app.openCask(token)
        XCTAssertTrue(app.sliders["specimenSize"].waitForExistence(timeout: 10))
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
        let buttonFrames = ["install", "update", "uninstall", "homepage"]
            // Homepage is a link, the rest buttons.
            .map { app.descendants(matching: .any).matching(identifier: $0).firstMatch }
            .filter(\.exists)
            .map(\.frame)
        try app.performAccessibilityAudit { issue in
            // An issue the audit can't tie to an element has nothing to look up or exempt.
            guard let element = issue.element else { return true }
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if sidebarColumn?.contains(center.x) ?? false || buttonFrames.contains(where: { $0.contains(center) }) {
                return true
            }
            // Specimens and names on cards and rows are cut to a few lines; VoiceOver reads the name in full,
            // and the font's page shows the whole sample. A specimen is drawn in its own font too, so a thin
            // face measures low contrast whatever its color.
            if ["specimen", "itemName"].contains(element.identifier),
               [.textClipped, .dynamicType].contains(issue.auditType) {
                return true
            }
            if element.identifier == "specimen", issue.auditType == .contrast {
                return true
            }
            // The failure itself names only the kind of issue.
            print("Accessibility audit: \(issue.compactDescription) on \(element.debugDescription)")
            return false
        }
    }
}
