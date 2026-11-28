import XCTest

/// Share, which sends typecask.app's page for what's showing, and Install on Mac, which sends a font's files.
final class ShareTests: XCTestCase {
    /// A font's page, an article, a designer and a style each offer Share; Installed, which is yours alone, doesn't.
    @MainActor
    func testPagesShareTheirLinks() {
        for page in ["collection:allFonts|font:font-fira-code", "start|article:start-here",
                     "makers:designer|designer:Łukasz Dziedzic", "collection:serif"] {
            let app = XCUIApplication.typecask()
            app.launchArguments += ["-lastPage", page]
            app.launch()
            let share = app.buttons["share"]
            XCTAssertTrue(share.waitForExistence(timeout: 30), "\(page) has no Share")
            share.tap()
            XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10), "\(page)'s Share opened no share sheet")
            app.terminate()
        }
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "collection:installed"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Installed"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["share"].exists, "Installed has no page on the site to share")
    }

    /// Install on Mac hands the share sheet a zip of the font's files, here saved to Files rather than AirDropped.
    @MainActor
    func testInstallOnMacSendsTheFonts() {
        let app = XCUIApplication.typecask()
        app.launchArguments += ["-lastPage", "collection:allFonts|font:font-fira-code"]
        app.launch()
        let send = app.controls(for: "font-fira-code").buttons["installOnMac"]
        XCTAssertTrue(send.waitForExistence(timeout: 30))
        send.tap()
        let download = app.buttons["downloadForMac"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        download.tap()
        let ready = app.buttons["sendToMac"]
        XCTAssertTrue(ready.waitForExistence(timeout: 60))
        ready.tap()
        let saveToFiles = app.cells["Save to Files"]
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 10))
        saveToFiles.tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 30))
        save.tap()
        // Back on the sheet once the zip is saved, and then the font's page.
        XCTAssertTrue(ready.waitForExistence(timeout: 30))
        app.buttons["installOnMacDone"].tap()
        XCTAssertTrue(send.waitForExistence(timeout: 10))
    }
}
