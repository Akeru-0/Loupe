import LoupeIndex
import SwiftUI

/// The main window: sidebar, detail and toolbar, with the activity log as an inspector.
public struct RootView: View {
    @Bindable var model: AppModel
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let toolbarWidth: State<LibraryToolbar.Width>
    private let toolbarRoom: State<ToolbarRoom>
    private let headingOffset: State<CGFloat>

    public init(model: AppModel) {
        self.model = model
        toolbarWidth = State(initialValue: .wide)
        toolbarRoom = State(initialValue: ToolbarRoom())
        headingOffset = State(initialValue: 0)
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            detail
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    toolbarRoom.wrappedValue.detailFrame = $0
                    updateToolbarLayout()
                }
                .toolbar { LibraryToolbar(model: model, width: toolbarWidth.wrappedValue) }
                // The viewer's date heading is centred instead; the album's name would crowd it.
                .navigationTitle(model.viewerPhotoID == nil ? model.selectedTitle : "")
                .navigationSubtitle(subtitle)
        }
        // Search lives at the top of the sidebar (like Notes/Mail) so the toolbar stays clear.
        .searchable(text: $model.query.searchText, placement: .sidebar, prompt: "Search")
        .background(TitlebarCenterAccessory(offset: headingOffset.wrappedValue, content: TitlebarCenter(model: model)))
        .onChange(of: model.viewerPhotoID != nil) { _, open in
            toolbarRoom.wrappedValue.showsViewer = open
            updateToolbarLayout()
        }
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
        .sheet(item: Binding(get: { model.smartAlbumEditing }, set: { model.smartAlbumEditing = $0 })) {
            SmartAlbumEditor(model: model, editing: $0)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            toolbarRoom.wrappedValue.windowWidth = $0
            updateToolbarLayout()
        }
    }

    /// "251 Photos · September 2026" under the title; nothing while the viewer, a card's import or Duplicates shows.
    private var subtitle: String {
        guard model.viewerPhotoID == nil, model.importModel == nil, model.query.scope != .duplicates, !model.isLocked,
            !(model.selectedItemID?.hasPrefix("drive:") ?? false)
        else { return "" }
        return photosSubtitle(count: model.photoCount, months: model.visibleMonths)
    }

    private func updateToolbarLayout() {
        let room = toolbarRoom.wrappedValue
        let width = LibraryToolbar.Width(room: room.room)
        if toolbarWidth.wrappedValue != width { toolbarWidth.wrappedValue = width }
        // Too little room even collapsed (the activity log is open): the viewer's heading moves left off centre
        // instead, though never over the traffic lights and the sidebar button.
        var offset: CGFloat = 0
        if room.showsViewer {
            let leftmost = TitlebarCenter.minLeading + TitlebarCenter.maxHalfWidth - room.windowWidth / 2
            offset = min(0, max(leftmost, room.room - LibraryToolbar.Width.minimumRoom))
        }
        if headingOffset.wrappedValue != offset { headingOffset.wrappedValue = offset }
    }

    /// The selected card's import window replaces the grid.
    @ViewBuilder private var detail: some View {
        if let id = model.selectedItemID, let drive = model.drive(forItemID: id) {
            DriveView(model: model, drive: drive)
        } else if let importModel = model.importModel {
            ImportView(model: model, importModel: importModel)
        } else if let id = model.selectedItemID, model.card(forItemID: id) != nil {
            ProgressView("Opening the library…")  // the import window needs the library
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.query.scope == .duplicates {
            DuplicatesView(model: model)
        } else if model.query.scope == .people {
            PeopleView(model: model)  // a person opened from it shows their photos below
        } else if model.isLocked {
            LockedView(model: model)
        } else {
            PhotoGridView(model: model)
                .overlay { if model.photoSections.isEmpty { DetailPlaceholder(model: model) } }
                .overlay { if model.viewerPhotoID != nil { PhotoViewer(model: model) } }
                .overlay { if let flight = model.viewerClosing { ViewerLanding(model: model, flight: flight).id(flight.id) } }
        }
    }
}

/// The detail column's trailing toolbar items sit between the title (or, in the viewer, the centred date heading)
/// and the column's right edge (left of the activity log when it is open); how much room that leaves decides how
/// far the toolbar collapses. A plain box, so the window's and the column's geometry can arrive in any order.
private final class ToolbarRoom {
    var windowWidth: CGFloat = 0
    var detailFrame: CGRect = .zero
    var showsViewer = false

    /// What the back button and the title with its subtitle keep at the column's leading edge.
    static let titleWidth: CGFloat = 230

    /// Points left for the trailing items.
    var room: CGFloat {
        if showsViewer { return detailFrame.maxX - windowWidth / 2 - TitlebarCenter.maxHalfWidth }
        // With the sidebar hidden the traffic lights and the sidebar button share the column's toolbar.
        let leading = max(detailFrame.minX, TitlebarCenter.minLeading)
        return detailFrame.maxX - leading - Self.titleWidth
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
        CommandGroup(after: .newItem) {
            Button("New Smart Album…") { model.newSmartAlbum() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!model.canMakeSmartAlbum)
        }
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
