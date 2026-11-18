import CoreText
import SwiftUI

/// Opens the Try It Out editor. Opt-in, since the editor needs the cask's full fonts: an installed cask's are on
/// the device already, but anything else downloads its On-Demand Resources tag, as Install does.
struct TryItOutButton: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer
    @State private var isPresented = false

    var body: some View {
        Button("Try It Out", systemImage: "character.cursor.ibeam") {
            isPresented = true
        }
        .buttonStyle(.glass)
        .accessibilityHint(installer.status(of: cask).isInstalled
            ? Text("Type in this font.")
            : Text("Downloads \(cask.bytes.formatted(.byteCount(style: .file))) to type in this font."))
        .accessibilityIdentifier("tryItOut")
        .sheet(isPresented: $isPresented) {
            TryItOutView(cask: cask)
                // A page on iPad, not a form sheet: an editor wants the room.
                .presentationSizing(.page)
        }
    }
}

/// An editor set in the cask's own fonts, which starts with what the face has to show off (see TryOutText): its
/// ligatures, its icons or another script's letters. Each face of the cask can be picked, a variable font's axes
/// moved, and a coding face's ligatures turned off.
struct TryItOutView: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer
    @Environment(\.dismiss) private var dismiss
    @State private var loader = TryOutLoader()
    @State private var text = ""
    @State private var face = 0
    @State private var size: Double = 24
    @State private var ligatures = true
    /// Each variable axis moved away from its default, by its identifier.
    @State private var variations: [Int: Double] = [:]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(cask.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    if case .loaded(let loaded) = loader.phase {
                        ToolbarItem(placement: .secondaryAction) {
                            Button("Restore Sample Text", systemImage: "arrow.counterclockwise") {
                                text = loaded.text
                            }
                        }
                    }
                }
        }
        .task {
            await loader.load(cask, installed: installer.status(of: cask).isInstalled,
                              sample: cask.sample ?? Catalog.bundled.sampleText)
            if case .loaded(let loaded) = loader.phase, text.isEmpty {
                text = loaded.text
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch loader.phase {
        case .loading:
            VStack(spacing: 12) {
                if installer.status(of: cask).isInstalled {
                    ProgressView("Loading…")
                } else {
                    ProgressView("Downloading \(cask.bytes.formatted(.byteCount(style: .file)))…",
                                 value: loader.progress)
                        .frame(maxWidth: 280)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load the Fonts", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .loaded(let loaded):
            VStack(spacing: 0) {
                controls(loaded)
                    .padding()
                Divider()
                TextEditor(text: $text)
                    .font(Font(font(loaded)))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .accessibilityIdentifier("tryItOutText")
            }
        }
    }

    @ViewBuilder private func controls(_ loaded: TryOutLoader.Loaded) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { faceAndSize(loaded) }
                VStack(alignment: .leading, spacing: 8) { faceAndSize(loaded) }
            }
            ForEach(loaded.faces[face].axes) { axis in
                let value = Binding { variations[axis.id] ?? axis.defaultValue } set: { variations[axis.id] = $0 }
                LabeledContent {
                    Slider(value: value, in: axis.range)
                        .accessibilityValue(Text(value.wrappedValue, format: .number.precision(.fractionLength(0))))
                } label: {
                    Text(axis.name)
                        .frame(minWidth: 70, alignment: .leading)
                }
            }
            if loaded.hasLigatures {
                Toggle("Ligatures", isOn: $ligatures)
                    .accessibilityIdentifier("tryItOutLigatures")
            }
        }
    }

    @ViewBuilder private func faceAndSize(_ loaded: TryOutLoader.Loaded) -> some View {
        if loaded.faces.count > 1 {
            Picker("Style", selection: Binding { face } set: { face = $0; variations = [:] }) {
                ForEach(loaded.faces) { face in
                    Text(face.name).tag(face.id)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("tryItOutStyle")
        }
        Slider(value: $size, in: 10...96) {
            Text("Size")
        } minimumValueLabel: {
            Image(systemName: "textformat.size.smaller")
                .accessibilityHidden(true)
        } maximumValueLabel: {
            Image(systemName: "textformat.size.larger")
                .accessibilityHidden(true)
        }
        .frame(minWidth: 200)
        .accessibilityValue(Text("\(Int(size)) points"))
    }

    /// The picked face at the size picked, its axes where they've been moved, and its ligatures off if asked.
    private func font(_ loaded: TryOutLoader.Loaded) -> CTFont {
        var attributes: [CFString: Any] = [:]
        if !variations.isEmpty {
            attributes[kCTFontVariationAttribute] = variations as [Int: Double] as CFDictionary
        }
        var descriptor = loaded.faces[face].descriptor
        if !attributes.isEmpty {
            descriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes as CFDictionary)
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return ligatures ? font : TryOutText.withoutLigatures(font)
    }
}

/// Finds the cask's full fonts for the editor: those installed, else its On-Demand Resources tag's, read from
/// the tag's data assets without installing them, so they're the app's alone and go with the editor.
@Observable
final class TryOutLoader {
    nonisolated struct Axis: Identifiable, Sendable {
        let id: Int
        let name: String
        let range: ClosedRange<Double>
        let defaultValue: Double
    }

    /// Core Text's descriptors are immutable, so a face can cross to the main actor.
    nonisolated struct Face: Identifiable, @unchecked Sendable {
        var id = 0
        let name: String
        let descriptor: CTFontDescriptor
        let axes: [Axis]
        /// Width from normal, width, italic and weight, which faces are listed by.
        let order: [Double]
    }

    struct Loaded {
        let faces: [Face]
        let text: String
        let hasLigatures: Bool
        /// What a font page's full specimen shows, from the same faces.
        let specimen: Specimen
    }

    enum Phase {
        case loading
        case loaded(Loaded)
        case failed(String)
    }

    private(set) var phase = Phase.loading
    private(set) var progress = 0.0

    /// Core Text's descriptors are immutable, so they can cross to the main actor.
    nonisolated private struct Prepared: Sendable {
        let faces: [Face]
        let text: TryOutText.Result
        let specimen: Specimen
    }

    func load(_ cask: Cask, installed: Bool, sample: String) async {
        let prepared: Prepared?
        if installed {
            prepared = await Self.prepare(Self.installed(cask.assets), sample: sample, glyphs: cask.glyphs)
        } else {
            let request = NSBundleResourceRequest(tags: [cask.pack ?? cask.token])
            let observation = request.progress.observe(\.fractionCompleted) { @Sendable [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in self?.progress = fraction }
            }
            defer { observation.invalidate() }
            do {
                try await request.beginAccessingResources()
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            // Copied out of the tag's pack, which the data assets map: ending access unmaps it, and the fonts made
            // from the mapping then read freed memory whenever anything draws them. Keeping the request while the
            // editor was open wasn't enough: UIKit lays out a text view's selection after its sheet has gone, and
            // build 17 crashed doing so in the background.
            let data = cask.assets.compactMap { name in
                NSDataAsset(name: name)?.data.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
            }
            request.endAccessingResources()
            prepared = await Self.prepare(.files(data), sample: sample, glyphs: cask.glyphs)
        }
        guard let prepared, !prepared.faces.isEmpty else {
            phase = .failed(String(localized: "This build's copy of the fonts couldn't be read."))
            return
        }
        phase = .loaded(Loaded(faces: prepared.faces, text: prepared.text.text,
                               hasLigatures: prepared.text.hasLigatures, specimen: prepared.specimen))
    }

    nonisolated private enum Source: @unchecked Sendable {
        /// The font files themselves.
        case files([Data])
        /// Installed fonts, which the system keeps where the app can't read the files, but can draw.
        case installed([CTFontDescriptor])
    }

    /// The installed faces that share a file with any of the cask's assets, which are named after a file's first
    /// face, as FontInstaller's uninstall finds them.
    private static func installed(_ assets: [String]) -> Source {
        let names = Set(assets)
        let registered = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
        func url(_ descriptor: CTFontDescriptor) -> URL? {
            CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
        }
        let files = Set(registered.filter { descriptor in
            (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String).map(names.contains) ?? false
        }.compactMap(url))
        return .installed(registered.filter { url($0).map(files.contains) ?? false })
    }

    /// The faces in reading order, regular before bold and upright before italic, the editor's text, made from the
    /// face nearest regular, and the page's specimen. Off the main actor: a CJK face's character set, the ligature
    /// checks and the language checks take a moment.
    @concurrent
    nonisolated private static func prepare(_ source: Source, sample: String, glyphs: Bool) async -> Prepared? {
        let descriptors: [CTFontDescriptor] = switch source {
        case .files(let files):
            files.flatMap { CTFontManagerCreateFontDescriptorsFromData($0 as CFData) as? [CTFontDescriptor] ?? [] }
        case .installed(let descriptors):
            descriptors
        }
        var seen = Set<String>()
        var faces = descriptors.compactMap { descriptor -> Face? in
            let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
            let postScriptName = CTFontCopyPostScriptName(font) as String
            guard seen.insert(postScriptName).inserted else { return nil }
            let traits = CTFontCopyTraits(font) as? [CFString: Any] ?? [:]
            let weight = traits[kCTFontWeightTrait] as? Double ?? 0
            let width = traits[kCTFontWidthTrait] as? Double ?? 0
            let italic = CTFontGetSymbolicTraits(font).contains(.traitItalic) ? 1.0 : 0
            let name = CTFontCopyName(font, kCTFontStyleNameKey) as String? ?? postScriptName
            return Face(name: name, descriptor: descriptor, axes: axes(of: font),
                        order: [abs(width), width, italic, weight])
        }
        .sorted { $0.order.lexicographicallyPrecedes($1.order) }
        for index in faces.indices {
            faces[index].id = index
        }
        // Regular is nearest zero weight and width, upright.
        func distance(_ order: [Double]) -> Double { order[0] + order[2] + abs(order[3]) }
        guard let regular = faces.min(by: { distance($0.order) < distance($1.order) }) else {
            return nil
        }
        let font = CTFontCreateWithFontDescriptor(regular.descriptor, 24, nil)
        return Prepared(faces: faces, text: TryOutText.make(font: font, sample: sample, glyphs: glyphs),
                        specimen: Specimen(faces: faces))
    }

    /// A variable face's axes that it doesn't hide, each with its name and range.
    nonisolated private static func axes(of font: CTFont) -> [Axis] {
        let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] ?? []
        return axes.compactMap { axis in
            guard axis[kCTFontVariationAxisHiddenKey] as? Bool != true,
                  let id = axis[kCTFontVariationAxisIdentifierKey] as? Int,
                  let low = axis[kCTFontVariationAxisMinimumValueKey] as? Double,
                  let high = axis[kCTFontVariationAxisMaximumValueKey] as? Double, low < high else { return nil }
            // The axis's tag, wght or wdth, where it has no name.
            let tag = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: id >> $0) }
            let fallback = String(bytes: tag, encoding: .ascii) ?? ""
            return Axis(id: id, name: axis[kCTFontVariationAxisNameKey] as? String ?? fallback, range: low...high,
                        defaultValue: axis[kCTFontVariationAxisDefaultValueKey] as? Double ?? low)
        }
    }
}
