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
            DetailPlaceholder(model: model)
                .toolbar { LibraryToolbar(model: model) }
                .navigationTitle(model.selectedTitle)
        }
        .searchable(text: $model.query.searchText, placement: .toolbar, prompt: "Search")
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
        .frame(minWidth: 900, minHeight: 600)
    }
}

/// Stands in for the photo grid (Task 18): shows what the current query matches.
struct DetailPlaceholder: View {
    var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(model.selectedTitle, systemImage: "photo.on.rectangle")
        } description: {
            Text(model.photoSections.count > 1
                ? "\(model.scanStatus) in \(model.photoSections.count) sections"
                : model.scanStatus)
        }
    }
}

/// App menu commands.
public struct LoupeCommands: Commands {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Activity Log", isOn: $model.showsActivityLog)
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
