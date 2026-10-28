import Foundation
import StoreKit
import SwiftUI

extension View {
    /// Asks for an App Store rating once a font has installed, if it's time to; see `ReviewPrompt`.
    func promptsForReview(after cask: Cask) -> some View {
        modifier(ReviewPrompt(cask: cask))
    }
}

/// The system's App Store rating prompt, asked for on the page of someone's third successful install, when
/// they've just got what they came for, and at most once per build. iOS decides whether it appears at all,
/// and shows it no more than three times a year; TestFlight builds never show it.
private struct ReviewPrompt: ViewModifier {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer
    @Environment(\.requestReview) private var requestReview
    @AppStorage("completedInstalls") private var completedInstalls = 0
    @AppStorage("buildLastPromptedForReview") private var buildLastPrompted = ""
    @State private var isDue = false

    private static let installsBeforePrompt = 3

    func body(content: Content) -> some View {
        content
            .onChange(of: installer.status(of: cask)) { old, new in
                // An install or update finishing, not a refresh finding the cask already installed.
                guard old == .installing, new == .installed else { return }
                completedInstalls += 1
                isDue = completedInstalls >= Self.installsBeforePrompt && buildLastPrompted != Self.build
                    && !Self.isSuppressed
            }
            // A moment after the consent sheet has gone, so the two don't stack. Leaving the page cancels the
            // wait, so the prompt never lands on a page the person has moved on to.
            .task(id: isDue) {
                guard isDue else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                isDue = false
                buildLastPrompted = Self.build
                requestReview()
            }
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    private static var isSuppressed: Bool {
        #if DEBUG
        // Debug builds always show the prompt, which would sit over the UI tests' later taps.
        ProcessInfo.processInfo.environment["TYPECASK_NO_REVIEW"] != nil
        #else
        false
        #endif
    }
}
