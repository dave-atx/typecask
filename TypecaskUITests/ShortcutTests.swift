import AppIntentsTesting
import XCTest

/// The font Shortcuts and Siri look up by name, through FontEntityQuery in the installed app.
final class ShortcutTests: XCTestCase {
    private let definitions = IntentDefinitions(bundleIdentifier: "org.marquard.Typecask")
    private var fonts: AppEntityDefinition { definitions.entities["FontEntity"] }

    /// "Lexend" names a family that has Lexend Deca, Exa and the rest too, more popular than some of them.
    func testExactNameComesFirst() async throws {
        let results = try await fonts.entities(matching: "Lexend")
        XCTAssertGreaterThan(results.count, 1)
        XCTAssertEqual(results.first?.identifier.instanceIdentifier, "font-lexend")
    }

    /// Every word has to match, in any order, and "font" is ignored, as in "Atkinson Next font".
    func testEveryWordMatches() async throws {
        let results = try await fonts.entities(matching: "Atkinson next font")
        XCTAssertEqual(results.map(\.identifier.instanceIdentifier), ["font-atkinson-hyperlegible-next"])
    }

    func testSuggestionsAreTheMostPopular() async throws {
        let suggested = try await fonts.suggestedEntities()
        XCTAssertEqual(suggested.count, 200)
    }

    /// Opens Lexend's page over the About sheet, which goes, and tells Siri the page is showing Lexend.
    @MainActor
    func testOpenFontShowsItsPage() async throws {
        let app = XCUIApplication.typecask()
        app.launch()
        // On iPhone, About is in the sidebar, behind the gallery.
        let about = app.buttons["about"]
        if about.waitForExistence(timeout: 10) {
            about.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        }

        let lexend = fonts.makeReference(identifier: "font-lexend")
        try await definitions.intents["OpenFontIntent"].makeIntent(target: lexend).run()
        XCTAssertTrue(app.sliders["specimenSize"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Lexend"].exists)
        XCTAssertFalse(app.buttons["Close"].exists)

        let annotations = try await fonts.viewAnnotations()
        let annotation = try XCTUnwrap(annotations.first)
        XCTAssertEqual(annotation.entity.identifier.instanceIdentifier, "font-lexend")
    }

    /// Searches the whole gallery, whatever collection was showing.
    @MainActor
    func testSearchShowsMatches() async throws {
        let app = XCUIApplication.typecask()
        app.launch()
        try await definitions.intents["SearchFontsIntent"].makeIntent(criteria: "hyperlegible").run()
        XCTAssertTrue(app.buttons["font-atkinson-hyperlegible-next"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["font-roboto"].exists)
    }

    /// The app indexes the catalog in Spotlight once it's launched.
    @MainActor
    func testSpotlightFindsFonts() async throws {
        XCUIApplication.typecask().launch()
        var hits: [AnyAppEntity] = []
        for _ in 0..<30 where hits.isEmpty {
            try await Task.sleep(for: .seconds(1))
            hits = try await fonts.spotlightQuery("Lexend Deca")
        }
        XCTAssertTrue(hits.map(\.identifier.instanceIdentifier).contains("font-lexend-deca"))
    }
}
