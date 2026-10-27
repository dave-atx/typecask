import CoreText
import Foundation
import Observation

/// Downloads a cask's On-Demand Resources tag and installs its fonts system-wide, and removes them again.
@Observable
final class FontInstaller {
    enum Status: Equatable {
        case available
        /// Downloading the cask's On-Demand Resources tag; `progress(of:)` says how far along.
        case downloading
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

        /// An install, update or uninstall under way, which a refresh leaves alone.
        var isBusy: Bool {
            switch self {
            case .downloading, .installing, .updating, .uninstalling: true
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

    /// Download progress, apart from `statuses`: every card in the gallery reads a status, and a progress
    /// tick written there redrew all of them, the gallery under the detail page included.
    private var downloads: [Cask.ID: Double] = [:]

    /// The casks installed now, which the Installed collection lists.
    private(set) var installed: Set<Cask.ID> = []

    /// The primary faces iOS has built in, found by the first refresh. They change only with iOS itself,
    /// and finding them means resolving every cask's name, so later refreshes reuse them.
    @ObservationIgnored private var builtIn: Set<String>?
    @ObservationIgnored private var isRefreshing = false

    func status(of cask: Cask) -> Status {
        statuses[cask.id] ?? .available
    }

    /// How much of the cask's download has arrived, from 0 to 1.
    func progress(of cask: Cask) -> Double {
        downloads[cask.id] ?? 0
    }

    /// Marks the casks whose fonts this app registered, and those iOS has built in. A name that merely
    /// resolves doesn't mean the cask is installed: iOS has its own Noto Sans Armenian, Chakma and others
    /// under the same PostScript names. Registered fonts are resolved as well, because on iOS 27.0 they can
    /// vanish after a reboot while still registered.
    ///
    /// An installed cask whose face declares a different version (name ID 5) from the one this build
    /// ships is offered as an update. Runs each time the app comes to the foreground, since fonts can be
    /// removed in Settings › General › Fonts meanwhile: a cask whose fonts are gone reads as available.
    func refresh(_ casks: [Cask]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let before = statuses
        let (installed, builtIn) = await Self.scan(casks.map(\.primaryFont), builtIn: self.builtIn)
        self.builtIn = builtIn
        #if DEBUG
        // Lets the UI tests exercise an update without two releases of a font to hand.
        let outdated = Set((ProcessInfo.processInfo.environment["TYPECASK_OUTDATED"] ?? "").split(separator: ","))
        #else
        let outdated: Set<Substring> = []
        #endif
        for cask in casks {
            let status = statuses[cask.id]
            // An install, update or uninstall under way, or one that finished while the scan ran, knows
            // better than the scan does.
            guard status == before[cask.id], !(status?.isBusy ?? false) else { continue }
            if let version = installed[cask.primaryFont] {
                let current = cask.fontVersion.map { $0 == version } ?? true
                statuses[cask.id] = current && !outdated.contains(Substring(cask.token)) ? .installed : .updateAvailable
            } else if builtIn.contains(cask.primaryFont) {
                statuses[cask.id] = .builtIn
            } else if status?.isInstalled ?? false {
                statuses[cask.id] = .available
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
        statuses[cask.id] = .downloading
        downloads[cask.id] = 0
        defer { downloads[cask.id] = nil }
        // The progress updates on a background queue, so SwiftUI can't observe it directly.
        let observation = request.progress.observe(\.fractionCompleted) { @Sendable [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if self?.statuses[cask.id] == .downloading {
                    self?.downloads[cask.id] = fraction
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
        if !errors.isEmpty {
            // Some of the cask's files may have registered before one failed. Left in place, they'd
            // read as an installed cask on the next launch with faces missing, so all or nothing.
            _ = await Self.unregister(cask.assets)
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
    /// has built in. Given the built-in names from an earlier scan, it resolves only registered names.
    @concurrent
    nonisolated private static func scan(
        _ postScriptNames: [String], builtIn known: Set<String>?
    ) async -> (installed: [String: String], builtIn: Set<String>) {
        let registered = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
        let names = Set(registered.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String })
        var installed: [String: String] = [:], builtIn: Set<String> = []
        for name in postScriptNames where known == nil || names.contains(name) {
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
        return (installed, known ?? builtIn)
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

#if DEBUG
extension FontInstaller {
    /// An installer that reports the given status for a cask, for previews. Set after `init()` so that
    /// `statuses`' observer keeps `installed` in step.
    convenience init(previewing status: Status, for cask: Cask) {
        self.init()
        statuses[cask.id] = status
    }
}
#endif
