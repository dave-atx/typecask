import SwiftUI

/// The gallery. On iPad the collections live in a sidebar, as in Font Book; where the layout is
/// compact they move into a toolbar menu so the fonts themselves stay the root view.
struct GalleryView: View {
    @State private var model: GalleryModel
    @Environment(FontInstaller.self) private var installer
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(catalog: Catalog) {
        _model = State(wrappedValue: GalleryModel(catalog: catalog))
    }

    var body: some View {
        // Both branches read the same model, so switching between them — rotating, resizing a Split View
        // — keeps the search text, the collection and the view mode.
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    CollectionSidebar(model: model)
                } detail: {
                    NavigationStack {
                        GalleryBrowser(model: model, showsCollectionMenu: false)
                    }
                }
            } else {
                NavigationStack {
                    GalleryBrowser(model: model, showsCollectionMenu: true)
                }
            }
        }
        .onChange(of: installer.installed, initial: true) { _, installed in
            model.installed = installed
        }
    }
}

/// Font Book's collections: All Fonts and Installed, the design styles, then Nerd Fonts and Apple's.
private struct CollectionSidebar: View {
    @Bindable var model: GalleryModel

    var body: some View {
        List(selection: $model.selectedCollection) {
            row(.allFonts)
            row(.installed)
            Section("Design Style") {
                ForEach(model.styles, id: \.style) { entry in
                    row(.style(entry.style))
                }
            }
            Section("Collections") {
                row(.nerdFonts)
                row(.appleFonts)
            }
        }
        .navigationTitle("Typecask")
    }

    private func row(_ collection: FontCollection) -> some View {
        Label {
            Text(collection.name)
        } icon: {
            Image(systemName: collection.symbol)
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
        model.collection == .installed ? "Fonts you install appear here." : "Nothing in this collection."
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

/// The compact-width stand-in for the sidebar.
private struct CollectionMenu: View {
    @Bindable var model: GalleryModel

    var body: some View {
        Menu {
            Picker("Collection", selection: $model.collection) {
                Text(FontCollection.allFonts.name).tag(FontCollection.allFonts)
                Text(FontCollection.installed.name).tag(FontCollection.installed)
                Section("Design Style") {
                    ForEach(model.styles, id: \.style) { entry in
                        Text(entry.style.name).tag(FontCollection.style(entry.style))
                    }
                }
                Section("Collections") {
                    Text(FontCollection.nerdFonts.name).tag(FontCollection.nerdFonts)
                    Text(FontCollection.appleFonts.name).tag(FontCollection.appleFonts)
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
