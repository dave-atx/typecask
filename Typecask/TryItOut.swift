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
/// ligatures, its OpenType features, its icons or another script's letters. Any style of the cask can be picked, a
/// variable font's named instances among them, its axes moved, its features and ligatures turned on and off, and
/// the text sized, aligned and spaced, as specimen-builder's type tester has.
struct TryItOutView: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer
    @Environment(\.dismiss) private var dismiss
    @State private var loader = TryOutLoader()
    @State private var text = ""
    /// The style picked, by index into the specimen's; nil for its regular.
    @State private var style: Int?
    @State private var size: Double = 24
    @State private var ligatures = true
    /// The style's axes moved away from its own values, by axis identifier.
    @State private var moved: [Int: Double] = [:]
    /// The OpenType features turned on, by tag.
    @State private var features: Set<String> = []
    @State private var alignment = TextAlignment.leading
    @State private var lineHeight = 1.0

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
                // Scrolls once there's more than a third of the screen of it, so the editor keeps its room.
                ScrollView {
                    controls(loaded)
                        .padding()
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                TextEditor(text: $text)
                    .font(Font(font(loaded)))
                    .lineSpacing(size * (lineHeight - 1))
                    .multilineTextAlignment(alignment)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .accessibilityIdentifier("tryItOutText")
            }
        }
    }

    @ViewBuilder private func controls(_ loaded: TryOutLoader.Loaded) -> some View {
        let specimen = loaded.specimen
        let current = specimen.styles[style ?? specimen.regular]
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { styleAndSize(specimen) }
                VStack(alignment: .leading, spacing: 8) { styleAndSize(specimen) }
            }
            HStack {
                Text("Alignment")
                Spacer()
                Picker("Alignment", selection: $alignment) {
                    Label("Left", systemImage: "text.alignleft").tag(TextAlignment.leading)
                    Label("Center", systemImage: "text.aligncenter").tag(TextAlignment.center)
                    Label("Right", systemImage: "text.alignright").tag(TextAlignment.trailing)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .fixedSize()
            }
            slider("Line Height") {
                Slider(value: $lineHeight, in: 1...2)
                    .accessibilityValue(Text(lineHeight, format: .number.precision(.fractionLength(1))))
            }
            ForEach(current.face.axes) { axis in
                let value = Binding { moved[axis.id] ?? current.variation[axis.id] ?? axis.defaultValue } set: {
                    moved[axis.id] = $0
                }
                slider(LocalizedStringKey(axis.name)) {
                    Slider(value: value, in: axis.range)
                        .accessibilityValue(Text(value.wrappedValue, format: .number.precision(.fractionLength(0))))
                }
            }
            if loaded.hasLigatures {
                Toggle("Ligatures", isOn: $ligatures)
                    .accessibilityIdentifier("tryItOutLigatures")
            }
            ForEach(specimen.features) { feature in
                Toggle(feature.name, isOn: Binding { features.contains(feature.tag) } set: { isOn in
                    if isOn { features.insert(feature.tag) } else { features.remove(feature.tag) }
                })
                .accessibilityIdentifier("tryItOutFeature.\(feature.tag)")
            }
        }
    }

    @ViewBuilder private func styleAndSize(_ specimen: Specimen) -> some View {
        if specimen.styles.count > 1 {
            Picker("Style", selection: Binding { style ?? specimen.regular } set: { style = $0; moved = [:] }) {
                ForEach(specimen.styles) { style in
                    Text(style.name).tag(style.id)
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

    private func slider(_ label: LocalizedStringKey, @ViewBuilder slider: () -> some View) -> some View {
        LabeledContent {
            slider()
        } label: {
            Text(label)
                .frame(minWidth: 90, alignment: .leading)
        }
    }

    /// The picked style at the size picked, its axes where they've been moved, its features on and its ligatures off
    /// as asked.
    private func font(_ loaded: TryOutLoader.Loaded) -> CTFont {
        let specimen = loaded.specimen
        let descriptor = specimen.styles[style ?? specimen.regular].descriptor(moving: moved)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return SpecimenFeature.font(font, features: features, ligatures: ligatures)
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
        let specimen = Specimen(faces: faces)
        let made = TryOutText.make(font: font, sample: sample, glyphs: glyphs)
        // A line for each feature the face has, to see it change when its switch is turned on.
        let lines = specimen.features.map(\.sampleLine)
        let text = lines.isEmpty ? made.text : made.text + "\n\n" + lines.joined(separator: "\n")
        return Prepared(faces: faces, text: TryOutText.Result(text: text, hasLigatures: made.hasLigatures),
                        specimen: specimen)
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
