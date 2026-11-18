import SwiftUI

/// What Try It Out opens to, from the part of a font's page that was tapped: the sample at the page's size, a style,
/// a feature turned on, or a character to type with.
struct TryOutStart: Identifiable {
    let id = UUID()
    /// The view the editor zooms from, by its matched transition identifier.
    let source: String
    var size: Double?
    var style: Int?
    var feature: SpecimenFeature?
    /// A character or line put at the top of the editor's text.
    var insert: String?
}

/// Opens a font page's Try It Out, which the page's specimen hands down so any part of it can.
struct TryOutOpener {
    /// The cask whose page this is, so a paired Nerd Font version's own Try It Out isn't taken for it.
    let token: String
    let namespace: Namespace.ID
    let open: (TryOutStart) -> Void
}

extension EnvironmentValues {
    @Entry var tryOut: TryOutOpener?
}

extension View {
    /// Makes this part of the specimen open Try It Out, which zooms from it. VoiceOver gets an action rather than a
    /// button trait, so the text stays text: "Try It Out" in the actions rotor.
    func opensTryOut(_ start: @escaping @autoclosure () -> TryOutStart) -> some View {
        modifier(OpensTryOut(start: start))
    }
}

private struct OpensTryOut: ViewModifier {
    let start: () -> TryOutStart
    @Environment(\.tryOut) private var opener

    func body(content: Content) -> some View {
        if let opener {
            let start = start()
            content
                .contentShape(Rectangle())
                .matchedTransitionSource(id: start.source, in: opener.namespace)
                .onTapGesture { opener.open(start) }
                .accessibilityAction(named: Text("Try It Out")) { opener.open(start) }
        } else {
            content
        }
    }
}

/// The mark beside a style or feature that opens Try It Out with it, shown only where Try It Out can open.
struct TryOutMark: View {
    @Environment(\.tryOut) private var opener

    var body: some View {
        if opener != nil {
            Image(systemName: "character.cursor.ibeam")
                .font(.callout)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
    }
}
