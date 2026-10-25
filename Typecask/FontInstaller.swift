import CoreText
import Foundation
import Observation

/// Downloads a cask's On-Demand Resources tag and installs its fonts system-wide, and removes them again.
@Observable
final class FontInstaller {
    enum Status {
        case available
        case downloading(fractionCompleted: Double)
        case installing
        case installed
        /// Installed, but the copy installed declares a different version from the one this build ships.
        case updateAvailable
        case updating
        case uninstalling
        /// iOS has a font of its own under the cask's primary PostScript name. Registering it fails with
        /// a duplicated-name error, so there's nothing to install: every app already has the font.
        case builtIn
        case failed(String)

        var isInstalled: Bool {
            switch self {
            case .installed, .updateAvailable: true
            default: false
            }
        }
    }

    private var statuses: [Cask.ID: Status] = [:] {
        didSet {
            let installed = Set(statuses.compactMap { $0.value.isInstalled ? $0.key : nil })
            if installed != self.installed {
                self.installed = installed
            }
        }
    }

    /// The casks installed now, which the Installed collection lists.
    private(set) var installed: Set<Cask.ID> = []

    func status(of cask: Cask) -> Status {
        statuses[cask.id] ?? .available
    }

    /// Marks the casks whose fonts this app registered, and those iOS has built in. A name that merely
    /// resolves doesn't mean the cask is installed: iOS has its own Noto Sans Armenian, Chakma and others
    /// under the same PostScript names. Registered fonts are resolved as well, because on iOS 27.0 they can
    /// vanish after a reboot while still registered.
    ///
    /// An installed cask whose face declares a different version (name ID 5) from the one this build
    /// ships is offered as an update.
    func refresh(_ casks: [Cask]) async {
        let (installed, builtIn) = await Self.scan(casks.map(\.primaryFont))
        #if DEBUG
        // Lets the UI tests exercise an update without two releases of a font to hand.
        let outdated = Set((ProcessInfo.processInfo.environment["TYPECASK_OUTDATED"] ?? "").split(separator: ","))
        #else
        let outdated: Set<Substring> = []
        #endif
        for cask in casks {
            if let version = installed[cask.primaryFont] {
                let current = cask.fontVersion.map { $0 == version } ?? true
                statuses[cask.id] = current && !outdated.contains(Substring(cask.token)) ? .installed : .updateAvailable
            } else if builtIn.contains(cask.primaryFont) {
                statuses[cask.id] = .builtIn
            }
        }
    }

    /// Replaces the installed fonts with this build's: removes them, then installs as new.
    func update(_ cask: Cask) async {
        statuses[cask.id] = .updating
        let errors = await Self.unregister(cask.assets + [cask.primaryFont])
        guard errors.isEmpty else {
            statuses[cask.id] = .failed(errors[0].localizedDescription)
            return
        }
        await install(cask)
    }

    func install(_ cask: Cask) async {
        // Deprecated in iOS 27, but fonts from its replacement, Background Assets, can't be installed system-wide.
        // A shared pack downloads its other casks too, but only this cask's assets get registered below.
        let request = NSBundleResourceRequest(tags: [cask.pack ?? cask.token])
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

    /// Removes the cask's fonts from every app. Fonts this app installed are the only ones it can remove.
    func uninstall(_ cask: Cask) async {
        statuses[cask.id] = .uninstalling
        // The primary face too, so a cask a later build stopped shipping, with no assets left to name,
        // can still be removed.
        let errors = await Self.unregister(cask.assets + [cask.primaryFont])
        if errors.isEmpty || !Self.resolves(cask.primaryFont) {
            statuses[cask.id] = .available
        } else {
            statuses[cask.id] = .failed(errors[0].localizedDescription)
        }
    }

    /// Which of `postScriptNames` this app has installed, with the version each declares, and which iOS
    /// has built in.
    @concurrent
    nonisolated private static func scan(
        _ postScriptNames: [String]
    ) async -> (installed: [String: String], builtIn: Set<String>) {
        let registered = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
        let names = Set(registered.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String })
        var installed: [String: String] = [:], builtIn: Set<String> = []
        for name in postScriptNames {
            let font = CTFontCreateWithName(name as CFString, 0, nil)
            guard CTFontCopyPostScriptName(font) as String == name else { continue }
            if names.contains(name) {
                let version = CTFontCopyName(font, kCTFontVersionNameKey) as String? ?? ""
                installed[name] = version.trimmingCharacters(in: .whitespaces)
            } else if let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
                      url.path().contains("/System/Library/Fonts/") {
                builtIn.insert(name)
            }
        }
        return (installed, builtIn)
    }

    nonisolated private static func resolves(_ postScriptName: String) -> Bool {
        CTFontCopyPostScriptName(CTFontCreateWithName(postScriptName as CFString, 0, nil)) as String == postScriptName
    }

    nonisolated private static func register(_ assets: [String]) async -> [NSError] {
        await perform { CTFontManagerRegisterFontsWithAssetNames(assets as CFArray, nil, .persistent, true, $0) }
    }

    /// Unregisters every face in the cask's files. Assets are named after a file's first face, so the
    /// other faces of a collection are found by sharing its file.
    nonisolated private static func unregister(_ assets: [String]) async -> [NSError] {
        await perform { handler in
            let names = Set(assets)
            let registered = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
            func url(_ descriptor: CTFontDescriptor) -> URL? {
                CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
            }
            let files = Set(registered.filter { descriptor in
                let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
                return name.map(names.contains) ?? false
            }.compactMap(url))
            let stale = registered.filter { url($0).map(files.contains) ?? false }
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
