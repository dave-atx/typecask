import CoreText
import Foundation
import Observation

/// Downloads a cask's On-Demand Resources tag and installs its fonts system-wide.
@Observable
final class FontInstaller {
    enum Status {
        case available
        case downloading(fractionCompleted: Double)
        case installing
        case installed
        case failed(String)

        var isInstalled: Bool {
            if case .installed = self { true } else { false }
        }
    }

    private var statuses: [Cask.ID: Status] = [:]

    func status(of cask: Cask) -> Status {
        statuses[cask.id] ?? .available
    }

    /// Checks fonts by resolving them, because on iOS 27.0 they can vanish after a reboot while still registered.
    func refresh(_ casks: [Cask]) {
        for cask in casks where Self.resolves(cask.primaryFont) {
            statuses[cask.id] = .installed
        }
    }

    func install(_ cask: Cask) async {
        // Deprecated in iOS 27, but fonts from its replacement, Background Assets, can't be installed system-wide.
        let request = NSBundleResourceRequest(tags: [cask.token])
        statuses[cask.id] = .downloading(fractionCompleted: 0)
        // The progress updates on a background queue, so SwiftUI can't observe it directly.
        let observation = request.progress.observe(\.fractionCompleted) { @Sendable [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.statuses[cask.id] {
                    self?.statuses[cask.id] = .downloading(fractionCompleted: fraction)
                }
            }
        }
        defer { observation.invalidate() }
        do {
            try await request.beginAccessingResources()
        } catch {
            statuses[cask.id] = .failed(error.localizedDescription)
            return
        }
        statuses[cask.id] = .installing
        var errors = await Self.register(cask.assets)
        if !errors.isEmpty, errors.allSatisfy({ $0.code == CTFontManagerError.alreadyRegistered.rawValue }) {
            _ = await Self.unregister(cask.assets)
            errors = await Self.register(cask.assets)
        }
        request.endAccessingResources()
        statuses[cask.id] = if errors.isEmpty {
            .installed
        } else if errors.contains(where: { $0.code == CTFontManagerError.cancelledByUser.rawValue }) {
            .available
        } else {
            .failed(errors[0].localizedDescription)
        }
    }

    nonisolated private static func resolves(_ postScriptName: String) -> Bool {
        CTFontCopyPostScriptName(CTFontCreateWithName(postScriptName as CFString, 0, nil)) as String == postScriptName
    }

    nonisolated private static func register(_ assets: [String]) async -> [NSError] {
        await perform { CTFontManagerRegisterFontsWithAssetNames(assets as CFArray, nil, .persistent, true, $0) }
    }

    nonisolated private static func unregister(_ assets: [String]) async -> [NSError] {
        await perform { handler in
            let names = Set(assets)
            let registered = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true)
            let stale = (registered as? [CTFontDescriptor] ?? []).filter { descriptor in
                let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
                return name.map(names.contains) ?? false
            }
            CTFontManagerUnregisterFontDescriptors(stale as CFArray, .persistent, handler)
        }
    }

    /// Collects the errors from a Core Text registration call. Runs off the main actor because registration blocks
    /// until the user answers the system's consent sheet, which needs the main thread.
    @concurrent
    nonisolated private static func perform(
        _ operation: @Sendable (@escaping @Sendable (CFArray, Bool) -> Bool) -> Void
    ) async -> [NSError] {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) var errors: [NSError] = []
            operation { batch, done in
                errors += (batch as NSArray) as? [NSError] ?? []
                if done {
                    continuation.resume(returning: errors)
                }
                return true
            }
        }
    }
}
