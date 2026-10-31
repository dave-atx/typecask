import SwiftUI

/// The gallery. On iPad the collections live in a sidebar, as in Font Book; where the layout is
/// compact they move into a toolbar menu so the fonts themselves stay the root view.
struct GalleryView: View {
    @Bindable var model: GalleryModel
    @Environment(FontInstaller.self) private var installer
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // Both branches read the same model, so switching between them — rotating, resizing a Split View
        // — keeps the search text, the collection and the view mode.
        Group {
            NavigationSplitView {
                CollectionSidebar(model: model)
            } detail: {
                NavigationStack(path: $model.path) {
                    GalleryBrowser(model: model, showsCollectionMenu: false)
                }
            }
        }
        .onChange(of: installer.installed, initial: true) { _, installed in
            model.installed = installed
        }
    }
}

/// Font Book's collections: All Fonts and Installed, the design styles, then Nerd Fonts and Apple's, and
/// the holidays.
private struct CollectionSidebar: View {
    @Bindable var model: GalleryModel
    @State private var showsAbout = false

    var body: some View {
        List(selection: $model.selectedCollection) {
            row(.allFonts)
            row(.installed)
            Section("Design Style") {
                ForEach(model.styles, id: \.self) { style in
                    row(.style(style))
                }
            }
            Section("Collections") {
                row(.nerdFonts)
                row(.appleFonts)
            }
            if !model.holidays.isEmpty {
                Section("Holidays") {
                    ForEach(model.holidays, id: \.self) { holiday in
                        row(.holiday(holiday))
                    }
                }
            }
        }
        .navigationTitle("Typecask")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("About Typecask", systemImage: "info.circle") {
                    showsAbout = true
                }
                .accessibilityIdentifier("about")
            }
        }
        .sheet(isPresented: $showsAbout) {
            AboutView(catalog: model.catalog)
        }
    }

    private func row(_ collection: FontCollection) -> some View {
        Label {
            Text(collection.name)
        } icon: {
            if collection == .style(.serif) {
                // Serif's symbol, "Abc", is half again as wide as the others and overruns the icon column
                // at accessibility sizes. Sans Serif's "Aa" set in New York pairs with it and fits.
                Text(verbatim: "Aa")
                    .fontDesign(.serif)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: collection.symbol)
            }
        }
        .badge(model.count(of: collection))
        .tag(collection)
    }
}

private struct GalleryBrowser: View {
    @Bindable var model: GalleryModel
    let showsCollectionMenu: Bool

    var body: some View {
        ScrollView {
            if model.visibleItems.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("No Fonts", systemImage: model.collection.symbol,
                                           description: Text(emptyDescription))
                        .padding(.top, 60)
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                        .padding(.top, 60)
                }
            } else if model.viewMode == .grid {
                GalleryGrid(items: model.visibleItems, catalog: model.catalog)
            } else {
                GallerySampleList(items: model.visibleItems, catalog: model.catalog)
            }
        }
        .navigationTitle(Text(model.collection.name))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText, prompt: Text("Search Fonts"))
        .toolbar {
            if showsCollectionMenu {
                ToolbarItem(placement: .topBarLeading) {
                    CollectionMenu(model: model)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SortMenu(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                ScriptMenu(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                ViewModePicker(model: model)
            }
            .visibilityPriority(.high)
        }
        .navigationDestination(for: GalleryItem.self) { item in
            switch item {
            case .cask(let cask):
                CaskDetailView(cask: cask, catalog: model.catalog)
            case .apple(let family):
                AppleFontDetailView(family: family, sampleText: model.catalog.sampleText)
            }
        }
    }

    private var emptyDescription: LocalizedStringKey {
        if !model.selectedScripts.isEmpty {
            "No fonts in this collection cover the selected writing systems."
        } else if model.collection == .installed {
            "Fonts you install appear here."
        } else {
            "Nothing in this collection."
        }
    }
}

private struct ViewModePicker: View {
    @Bindable var model: GalleryModel

    var body: some View {
        Picker("View", selection: $model.viewMode) {
            Label("Grid", systemImage: "square.grid.2x2")
                .tag(GalleryModel.ViewMode.grid)
            Label("Sample", systemImage: "text.alignleft")
                .tag(GalleryModel.ViewMode.sample)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        // Its natural width. Otherwise it stretches to fill the toolbar at first, then shrinks inside
        // its glass capsule after a detail page is popped, leaving a dead gap on iPhone.
        .fixedSize()
        .accessibilityIdentifier("viewMode")
    }
}

private struct SortMenu: View {
    @Bindable var model: GalleryModel

    var body: some View {
        Menu {
            Picker("Sort By", selection: $model.sortOrder) {
                ForEach(GalleryModel.SortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("sortOrder")
    }
}

/// Filters the gallery to fonts covering any of the scripts picked. It stays open as scripts are toggled,
/// so several can be picked at once.
private struct ScriptMenu: View {
    @Bindable var model: GalleryModel

    var body: some View {
        Menu {
            if !model.selectedScripts.isEmpty {
                Button("Any Writing System", systemImage: "xmark.circle") {
                    model.selectedScripts = []
                }
            }
            Section("Writing Systems") {
                ForEach(model.scripts) { script in
                    toggle(script)
                }
            }
            if !model.moreScripts.isEmpty {
                Menu("More Writing Systems") {
                    ForEach(model.moreScripts) { script in
                        toggle(script)
                    }
                }
            }
        } label: {
            Label("Writing System", systemImage: model.selectedScripts.isEmpty
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityIdentifier("scripts")
    }

    private func toggle(_ script: GalleryModel.Script) -> some View {
        Toggle(isOn: Binding {
            model.selectedScripts.contains(script.code)
        } set: { isOn in
            if isOn {
                model.selectedScripts.insert(script.code)
            } else {
                model.selectedScripts.remove(script.code)
            }
        }) {
            Text(script.name)
            Text("^[\(script.count) font](inflect: true)")
        }
    }
}

/// The compact-width stand-in for the sidebar.
private struct CollectionMenu: View {
    @Bindable var model: GalleryModel

    var body: some View {
        Menu {
            Picker("Collection", selection: $model.collection) {
                Text(FontCollection.allFonts.name).tag(FontCollection.allFonts)
                Text(FontCollection.installed.name).tag(FontCollection.installed)
                Section("Design Style") {
                    ForEach(model.styles, id: \.self) { style in
                        Text(style.name).tag(FontCollection.style(style))
                    }
                }
                Section("Collections") {
                    Text(FontCollection.nerdFonts.name).tag(FontCollection.nerdFonts)
                    Text(FontCollection.appleFonts.name).tag(FontCollection.appleFonts)
                }
                if !model.holidays.isEmpty {
                    Section("Holidays") {
                        ForEach(model.holidays, id: \.self) { holiday in
                            Text(holiday.name).tag(FontCollection.holiday(holiday))
                        }
                    }
                }
            }
        } label: {
            Label("Collection", systemImage: model.collection == .allFonts
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("designStyle")
    }
}
#Preview {
    GalleryView(model: GalleryModel(catalog: .bundled))
        .environment(FontInstaller())
}

#Preview("AX5") {
    GalleryView(model: GalleryModel(catalog: .bundled))
        .environment(FontInstaller())
        .dynamicTypeSize(.accessibility5)
}

/// The gallery filtered to fonts for Arabic or Hebrew, with the script menu's button filled.
#Preview("Script Filter") {
    let model = GalleryModel(catalog: .bundled)
    model.selectedScripts = ["Arab", "Hebr"]
    return NavigationStack {
        GalleryBrowser(model: model, showsCollectionMenu: false)
    }
    .environment(FontInstaller())
}

/// The sidebar slid over the gallery on iPhone Duo's exterior display in portrait, at AX1.
#Preview("Sidebar, AX1", traits: .fixedLayout(width: 340, height: 1000)) {
    NavigationStack {
        CollectionSidebar(model: GalleryModel(catalog: .bundled))
            .listStyle(.sidebar)
    }
    .dynamicTypeSize(.accessibility1)
}
