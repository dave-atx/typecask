import AppIntentsTesting
import XCTest

/// The font Shortcuts and Siri look up by name, through FontEntityQuery in the installed app.
final class ShortcutTests: XCTestCase {
    private let fonts = IntentDefinitions(bundleIdentifier: "org.marquard.Typecask").entities["FontEntity"]

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
}
