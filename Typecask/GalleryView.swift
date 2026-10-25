import SwiftUI

/// The gallery. On iPad the style collections live in a sidebar, as in Font Book; where the layout is
/// compact they move into a toolbar menu so the fonts themselves stay the root view.
struct GalleryView: View {
    @State private var model: GalleryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(catalog: Catalog) {
        _model = State(wrappedValue: GalleryModel(catalog: catalog))
    }

    var body: some View {
        // Both branches read the same model, so switching between them — rotating, resizing a Split View
        // — keeps the search text, the collection and the view mode.
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                StyleSidebar(model: model)
            } detail: {
                NavigationStack {
                    CaskBrowser(model: model, showsStyleMenu: false)
                }
            }
        } else {
            NavigationStack {
                CaskBrowser(model: model, showsStyleMenu: true)
            }
        }
    }
}

/// Font Book's collections: All Fonts, then one row per style present in the catalog.
private struct StyleSidebar: View {
    @Bindable var model: GalleryModel

    var body: some View {
        List(selection: $model.selectedCollection) {
            Label("All Fonts", systemImage: "square.grid.2x2")
                .badge(model.catalog.casks.count)
                .tag(FontCollection.allFonts)
            Section("Design Style") {
                ForEach(model.collections, id: \.style) { collection in
                    Label {
                        Text(collection.style.name)
                    } icon: {
                        Image(systemName: collection.style.symbol)
                    }
                    .badge(collection.count)
                    .tag(FontCollection.style(collection.style))
                }
            }
        }
        .navigationTitle("Typecask")
    }
}

private struct CaskBrowser: View {
    @Bindable var model: GalleryModel
    let showsStyleMenu: Bool

    var body: some View {
        ScrollView {
            if model.visibleCasks.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .padding(.top, 60)
            } else if model.viewMode == .grid {
                CaskGrid(casks: model.visibleCasks, sampleText: model.catalog.sampleText)
            } else {
                CaskSampleList(casks: model.visibleCasks, sampleText: model.catalog.sampleText)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText, prompt: Text("Search Fonts"))
        .toolbar {
            if showsStyleMenu {
                ToolbarItem(placement: .topBarLeading) {
                    StyleMenu(model: model)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ViewModePicker(model: model)
            }
        }
        .navigationDestination(for: Cask.self) { cask in
            CaskDetailView(cask: cask, sampleText: model.catalog.sampleText)
        }
    }

    private var title: Text {
        model.collection.style.map { Text($0.name) } ?? Text("All Fonts")
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

/// The compact-width stand-in for the sidebar.
private struct StyleMenu: View {
    @Bindable var model: GalleryModel

    var body: some View {
        Menu {
            Picker("Design Style", selection: $model.collection) {
                Text("All Fonts").tag(FontCollection.allFonts)
                ForEach(model.collections, id: \.style) { collection in
                    Text(collection.style.name).tag(FontCollection.style(collection.style))
                }
            }
        } label: {
            Label("Design Style", systemImage: model.collection == .allFonts
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("designStyle")
    }
}
