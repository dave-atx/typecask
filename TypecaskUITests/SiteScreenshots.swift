import XCTest

/// The screenshots typecask.app shows, taken by `scripts/screenshots.sh`, which runs these on an iPhone and an
/// iPad, sets the status bar and the dark appearance, and copies each attachment out under its name. Each test
/// runs on one idiom and skips on the other.
final class SiteScreenshots: XCTestCase {
    /// A handwriting cask, the style least like the rest, with a Google Fonts description, so the detail page
    /// shows everything it can.
    private let detailToken = ProcessInfo.processInfo.environment["TYPECASK_SCREENSHOT_CASK"] ?? "font-caveat"

    /// `outer` or `inner` on an iPhone Duo, which `scripts/screenshots.sh` runs folded and then unfolded: the phone
    /// shots are named for the display they came from, so the two runs don't overwrite each other.
    private let duoDisplay = ProcessInfo.processInfo.environment["TYPECASK_SCREENSHOT_DISPLAY"].flatMap {
        $0.isEmpty ? nil : $0
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// All Fonts by Trending, as sample lines, scrolled to start at the first handwriting font. The top of the
    /// list is mostly monospaced fonts, which look alike; from the handwriting font on it's a mix of styles.
    @MainActor
    func testPhoneSamples() throws {
        try requireIdiom(.phone)
        let trending = try Self.trending()
        let first = try XCTUnwrap(trending.first)
        let handwriting = try XCTUnwrap(trending.first { $0.style == "handwriting" })
        let app = launch()
        sort(app, by: "Trending")
        // Unfolded, an iPhone Duo lays out like an iPad, sidebar and gallery, and takes the iPad's shot: synthesized
        // drags don't reach its inner display, so the list can't be scrolled there anyway.
        if duoDisplay != "inner" {
            app.buttons["Sample"].tap()
            scroll(app, to: handwriting.token, from: first.token)
        }
        snap("iphone-samples")
    }

    @MainActor
    func testPhoneDetail() throws {
        try requireIdiom(.phone)
        let app = launch()
        open(detailToken, in: app)
        snap("iphone-detail")
    }

    @MainActor
    func testPadGallery() throws {
        try requireIdiom(.pad)
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        sort(app, by: "Trending")
        snap("ipad-gallery")
    }

    @MainActor
    private func requireIdiom(_ idiom: UIUserInterfaceIdiom) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == idiom, "Only on \(idiom == .pad ? "iPad" : "iPhone")")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // Input sent right after launch can be dropped, so wait for the gallery to be up first.
        XCTAssertTrue(app.buttons["sortOrder"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func sort(_ app: XCUIApplication, by order: String) {
        app.buttons["sortOrder"].tap()
        let item = app.buttons[order]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        _ = item.waitForNonExistence(timeout: 5)
    }

    /// Drags the list until the row for `token` sits where the row for `top`, the list's first, started out,
    /// measured from the bottom of the navigation bar: on an iPhone Duo's outer display the bar shrinks once the
    /// list scrolls, so a fixed point can't be reached. Slow drags that hold at the end, so the list doesn't coast,
    /// and as many as it takes. The scroll view keeps the first few points of each drag before it moves, so each
    /// drag adds what the last one lost, up to 30 points.
    @MainActor
    private func scroll(_ app: XCUIApplication, to token: String, from top: String) {
        let first = app.buttons[top]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let bar = app.navigationBars.firstMatch
        let gap = first.frame.minY - bar.frame.maxY
        let row = app.buttons[token]
        for _ in 0..<20 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Each drag starts mid-screen, so it can go at most this far before it leaves the screen. A tall display,
        // like an unfolded iPhone Duo's, can start the row further off than that.
        let reach = app.frame.height * 0.4
        var lost: CGFloat = 0
        for _ in 0..<15 {
            let before = row.frame.minY
            let distance = min(max(bar.frame.maxY + gap - before, -reach), reach)
            if abs(distance) < 2 {
                break
            }
            let drag = distance < 0 ? distance - lost : distance + lost
            let start = origin.withOffset(CGVector(dx: row.frame.midX, dy: app.frame.midY))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: drag)),
                        withVelocity: .slow, thenHoldForDuration: 0.5)
            lost = min(max(abs(drag) - abs(row.frame.minY - before), 0), 30)
        }
        // On an iPhone Duo's outer display the list won't settle with the row exactly there, and stops up to a bar's
        // height short, so a Duo takes the row anywhere in that span.
        let slack = duoDisplay == nil ? 2 : bar.frame.height
        XCTAssertEqual(row.frame.minY, bar.frame.maxY + gap, accuracy: slack)
    }

    /// Searches for the card, as InstallTests does.
    @MainActor
    private func open(_ token: String, in app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        // Where the toolbar has no room for the field, as on an iPhone Duo's outer display, it's a Search button.
        if !search.waitForExistence(timeout: 5) {
            app.buttons["Search"].tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(token)
        let card = app.buttons[token]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.buttons["install"].waitForExistence(timeout: 10))
    }

    /// The screen the app is on. Unfolded, an iPhone Duo draws on its inner display, which isn't the main screen;
    /// the main one, the outer display, is off and comes out black. The inner display is the larger.
    @MainActor
    private var screen: XCUIScreen {
        guard duoDisplay == "inner" else {
            return XCUIScreen.main
        }
        return XCUIScreen.screens.max { pixels($0) < pixels($1) } ?? XCUIScreen.main
    }

    @MainActor
    private func pixels(_ screen: XCUIScreen) -> CGFloat {
        let image = screen.screenshot().image
        return image.size.width * image.size.height * image.scale * image.scale
    }

    /// Waits out the transition and the cards' fonts loading, then attaches the whole screen.
    @MainActor
    private func snap(_ name: String) {
        Thread.sleep(forTimeInterval: 2)
        let attachment = XCTAttachment(image: upright(screen.screenshot().image))
        if let duoDisplay, name.hasPrefix("iphone-") {
            attachment.name = "duo-\(duoDisplay)-" + name.dropFirst("iphone-".count)
        } else {
            attachment.name = name
        }
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The casks in the order the app sorts them by Trending, from the catalog the app was built with. The test
    /// reads it out of the source tree, which the simulator can see.
    private static func trending() throws -> [Cask] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Typecask/Catalog.json")
        let casks = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).casks
        return casks.filter { $0.trending != nil }.sorted { ($0.trending ?? 0) < ($1.trending ?? 0) }
    }

    private struct Catalog: Decodable {
        let casks: [Cask]
    }

    private struct Cask: Decodable {
        let token: String
        let style: String
        let trending: Int?
    }

    /// The screen comes back in the device's portrait orientation whichever way it's held, so a landscape
    /// screenshot is turned the way the app was drawn.
    @MainActor
    private func upright(_ image: UIImage) -> UIImage {
        let orientation: UIImage.Orientation
        switch XCUIDevice.shared.orientation {
        case .landscapeLeft: orientation = .left
        case .landscapeRight: orientation = .right
        // An unfolded iPhone Duo draws its landscape layout across the inner display's portrait framebuffer. The
        // image's own size already reads landscape; its pixels don't.
        case _ where duoDisplay == "inner" && (image.cgImage.map { $0.width < $0.height } ?? false):
            orientation = .right
        default: return image
        }
        guard let cgImage = image.cgImage else { return image }
        let turned = UIImage(cgImage: cgImage, scale: image.scale, orientation: orientation)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: turned.size, format: format).image { _ in
            turned.draw(at: .zero)
        }
    }
}
