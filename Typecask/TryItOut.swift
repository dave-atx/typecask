import CoreText
import SwiftUI

/// Opens the Try It Out editor. Opt-in, since the editor needs the cask's full fonts: an installed cask's are on
/// the device already, but anything else downloads its On-Demand Resources tag, as Install does. On a font's own
/// page it opens the page's editor, which zooms from the button and shares the page's fonts; a paired Nerd Font
/// version's button opens one of its own.
struct TryItOutButton: View {
    let cask: Cask
    @Environment(FontInstaller.self) private var installer
    @Environment(\.tryOut) private var opener
    @State private var isPresented = false
    @State private var loader = TryOutLoader()

    var body: some View {
        if let opener, opener.token == cask.token {
            button { opener.open(TryOutStart(source: "button")) }
                .matchedTransitionSource(id: "button", in: opener.namespace)
        } else {
            button { isPresented = true }
                .sheet(isPresented: $isPresented) {
                    TryItOutView(cask: cask, loader: loader)
                        // A page on iPad, not a form sheet: an editor wants the room.
                        .presentationSizing(.page)
                }
        }
    }

    private func button(_ action: @escaping () -> Void) -> some View {
        Button("Try It Out", systemImage: "character.cursor.ibeam", action: action)
            .buttonStyle(.glass)
            .accessibilityHint(installer.status(of: cask).isInstalled
                ? Text("Type in this font.")
                : Text("Downloads \(cask.bytes.formatted(.byteCount(style: .file))) to type in this font."))
            .accessibilityIdentifier("tryItOut")
    }
}

/// An editor set in the cask's own fonts, which starts with what the face has to show off (see TryOutText): its
/// ligatures, its OpenType features, its icons or another script's letters. The style and size are always to hand,
/// and so is a chip for each feature, so a face's features are seen rather than found; alignment, line height and a
/// variable face's axes are under Adjust, a side panel on iPad and a half sheet on iPhone, with the text in view.
struct TryItOutView: View {
    let cask: Cask
    /// The cask's full fonts, shared with its page when opened from there, so they download once.
    let loader: TryOutLoader
    @Environment(FontInstaller.self) private var installer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var text = ""
    /// What the text starts with: the line of the feature or the character the editor was opened from.
    private let insert: String?
    /// The style picked, by index into the specimen's; nil for its regular.
    @State private var style: Int?
    @State private var size: Double
    @State private var ligatures = true
    /// The style's axes moved away from its own values, by axis identifier.
    @State private var moved: [Int: Double] = [:]
    /// The OpenType features turned on, by tag.
    @State private var features: Set<String>
    @State private var alignment = TextAlignment.leading
    @State private var lineHeight = 1.0
    @State private var adjusting = false
    @FocusState private var editing: Bool

    init(cask: Cask, loader: TryOutLoader, start: TryOutStart? = nil) {
        self.cask = cask
        self.loader = loader
        insert = start?.insert ?? start?.feature?.sampleLine
        _style = State(initialValue: start?.style)
        _size = State(initialValue: min(max(start?.size ?? 24, 10), 96))
        _features = State(initialValue: Set([start?.feature?.tag].compactMap { $0 }))
    }

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
                        ToolbarItem(placement: .primaryAction) {
                            Button("Adjust", systemImage: "slider.horizontal.3") {
                                adjusting.toggle()
                                // The half sheet is for watching the text change, which the keyboard would cover.
                                if adjusting {
                                    editing = false
                                }
                            }
                                .accessibilityIdentifier("tryItOutAdjust")
                        }
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
        }
        .task(id: loader.isLoaded) {
            if case .loaded(let loaded) = loader.phase, text.isEmpty {
                text = insert.map { $0 + "\n\n" + loaded.text } ?? loaded.text
                // Beside the text where there's room for it, as Pages and Keynote keep theirs.
                adjusting = sizeClass == .regular
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
                VStack(alignment: .leading, spacing: 10) {
                    styleAndSize(loaded.specimen)
                        .padding(.horizontal)
                    chips(loaded)
                }
                .padding(.vertical, 10)
                Divider()
                TextEditor(text: $text)
                    .font(Font(font(loaded)))
                    .lineSpacing(size * (lineHeight - 1))
                    .multilineTextAlignment(alignment)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .accessibilityIdentifier("tryItOutText")
                    .focused($editing)
                    // On iPhone, typing closes the half sheet, which would sit behind the keyboard; on iPad the
                    // panel is beside the text, and stays.
                    .onChange(of: editing) { _, editing in
                        if editing, sizeClass != .regular {
                            adjusting = false
                        }
                    }
            }
            .inspector(isPresented: $adjusting) {
                adjustments(loaded.specimen)
                    .presentationDetents([.medium, .large])
                    // The text stays editable above the half sheet, to watch it change.
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }

    private func styleAndSize(_ specimen: Specimen) -> some View {
        HStack(spacing: 16) {
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
            .accessibilityValue(Text("\(Int(size)) points"))
        }
    }

    /// Ligatures and each feature as a chip, in a row that scrolls sideways, so they're in sight however many.
    @ViewBuilder private func chips(_ loaded: TryOutLoader.Loaded) -> some View {
        if loaded.hasLigatures || !loaded.specimen.features.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if loaded.hasLigatures {
                        chip("Ligatures", isOn: $ligatures)
                            .accessibilityIdentifier("tryItOutLigatures")
                    }
                    ForEach(loaded.specimen.features) { feature in
                        chip(feature.name, isOn: Binding { features.contains(feature.tag) } set: { isOn in
                            if isOn { features.insert(feature.tag) } else { features.remove(feature.tag) }
                        })
                        .accessibilityIdentifier("tryItOutFeature.\(feature.tag)")
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// A feature's switch as a chip: clear glass when off, filled with the tint and checked when on, so it reads at
    /// a glance and not by color alone. Still a toggle to VoiceOver, which reads its state.
    @ViewBuilder private func chip(_ title: String, isOn: Binding<Bool>) -> some View {
        let toggle = Toggle(isOn: isOn) {
            if isOn.wrappedValue {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .toggleStyle(.button)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        if isOn.wrappedValue {
            toggle.buttonStyle(.glassProminent)
        } else {
            toggle.buttonStyle(.glass)
        }
    }

    private func adjustments(_ specimen: Specimen) -> some View {
        let current = specimen.styles[style ?? specimen.regular]
        return Form {
            Section {
                Picker("Alignment", selection: $alignment) {
                    Label("Left", systemImage: "text.alignleft").tag(TextAlignment.leading)
                    Label("Center", systemImage: "text.aligncenter").tag(TextAlignment.center)
                    Label("Right", systemImage: "text.alignright").tag(TextAlignment.trailing)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                slider("Line Height") {
                    Slider(value: $lineHeight, in: 1...2)
                        .accessibilityValue(Text(lineHeight, format: .number.precision(.fractionLength(1))))
                }
            }
            if !current.face.axes.isEmpty {
                Section("Axes") {
                    ForEach(current.face.axes) { axis in
                        let value = Binding { moved[axis.id] ?? current.variation[axis.id] ?? axis.defaultValue } set: {
                            moved[axis.id] = $0
                        }
                        slider(LocalizedStringKey(axis.name)) {
                            Slider(value: value, in: axis.range)
                                .accessibilityValue(Text(value.wrappedValue,
                                                         format: .number.precision(.fractionLength(0))))
                        }
                    }
                }
            }
        }
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
