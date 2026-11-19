import LoupeIndex
import SwiftUI

/// The main window: sidebar, detail and toolbar, with the activity log as an inspector.
public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            detail
                .toolbar { LibraryToolbar(model: model) }
                .navigationTitle(model.selectedTitle)
        }
        // Search lives at the top of the sidebar (like Notes/Mail) so the toolbar stays clear around the
        // Years/Months/Days/All Photos switch, which is centred in the window's title bar.
        .searchable(text: $model.query.searchText, placement: .sidebar, prompt: "Search")
        .background(TitlebarCenterAccessory(content: BrowseModePicker(model: model)))
        .inspector(isPresented: $model.showsActivityLog) {
            ActivityLogView(model: model)
                .inspectorColumnWidth(min: 260, ideal: 340, max: 600)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
            presenting: model.alertMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: Binding(
            get: { model.tagEditorPhotoIDs != nil }, set: { if !$0 { model.tagEditorPhotoIDs = nil } }
        )) {
            if let ids = model.tagEditorPhotoIDs {
                TagEditorView(model: model, photoIDs: ids) { model.tagEditorPhotoIDs = nil }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    /// The selected card's import window replaces the grid.
    @ViewBuilder private var detail: some View {
        if let importModel = model.importModel {
            ImportView(model: model, importModel: importModel)
        } else if let id = model.selectedItemID, model.card(forItemID: id) != nil {
            ProgressView("Opening the library…")  // the import window needs the library
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PhotoGridView(model: model)
                .overlay { if model.photoSections.isEmpty { DetailPlaceholder(model: model) } }
                .overlay { if model.viewerPhotoID != nil { PhotoViewer(model: model) } }
        }
    }
}

/// Shown over the grid while the current query matches nothing.
struct DetailPlaceholder: View {
    var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(model.selectedTitle, systemImage: "photo.on.rectangle")
        } description: {
            Text(model.scanStatus)
        }
    }
}

/// App menu commands.
public struct LoupeCommands: Commands {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Edit Tags…") { model.editTags() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!model.canEditTags)
        }
        CommandMenu("Image") {
            Button("Rotate Left") { model.rotateFromMenu(clockwise: false) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!model.canRotateTargets)
            Button("Rotate Right") { model.rotateFromMenu(clockwise: true) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canRotateTargets)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Activity Log", isOn: $model.showsActivityLog)
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
