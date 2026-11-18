import AppKit
import LoupeCore
import LoupeIndex
import SwiftUI

extension SidebarItem {
    /// The folder this item stands for: `""` for Unsorted, the path for an album or a group, nil otherwise.
    var albumFolder: String? {
        switch scope {
        case .unsorted: ""
        case .folder(let path), .folderTree(let path): path
        default: nil
        }
    }

    var isAlbum: Bool { if case .folder(let path)? = dropTarget { !path.isEmpty } else { false } }
}

/// Albums are folders: New Album, Rename, Delete Album and moving photos into an album. Prompts run as sheets on
/// the main window; the work runs in `Library` and errors are presented through the model.
extension AppModel {
    /// Asks for a name and creates the album inside `parent` (`""` is the root). Returns its path.
    @discardableResult
    func newAlbum(in parent: String, select: Bool) async -> String? {
        guard let library,
            let name = await Self.askName(
                title: "New Album", message: "The album is a new folder in \(Self.folderTitle(parent)).",
                button: "Create", initial: "")
        else { return nil }
        do {
            let path = try await library.createFolder(named: name, inFolder: parent)
            if select { selectedItemID = "folder:" + path.precomposedStringWithCanonicalMapping }
            return path
        } catch {
            present(OrganizeError("Couldn't create the album “\(name)”: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Renames an album or a group (its folder).
    func renameAlbum(_ item: SidebarItem) async {
        guard let library, let path = item.albumFolder, !path.isEmpty,
            let name = await Self.askName(
                title: "Rename “\(item.title)”", message: "This renames the folder in Finder.", button: "Rename",
                initial: Self.lastComponent(path))
        else { return }
        let wasSelected = selectedItemID == item.id
        do {
            let new = try await library.renameFolder(path, to: name)
            if wasSelected { selectedItemID = "folder:" + new.precomposedStringWithCanonicalMapping }
        } catch {
            present(OrganizeError("Couldn't rename “\(item.title)”: \(error.localizedDescription)"))
        }
    }

    /// Asks, then moves the album's photos to Unsorted and removes its folder if nothing else is in it.
    func deleteAlbum(_ item: SidebarItem) async {
        guard let library, item.isAlbum, let path = item.albumFolder, let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the album “\(item.title)”?"
        alert.informativeText = "Photos in \(item.title) move to Unsorted. Subfolders stay."
        alert.addButton(withTitle: "Delete Album")
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
        let names = await stems(ofPhotosIn: path)
        let errors = await library.deleteAlbum(path)
        PhotoGridController.presentErrors(errors, "Couldn't move to Unsorted", names: names, model: self)
    }

    /// Moves photos (all their files) into an album folder, `""` being Unsorted, and presents per-photo errors.
    func move(_ ids: [Int64], toFolder folder: String) {
        guard let library, !ids.isEmpty else { return }
        let index = library.index
        Task {
            let names = await Task.detached(priority: .userInitiated) { Self.stems(ids, index: index) }.value
            let errors = await library.move(ids, toFolder: folder)
            PhotoGridController.presentErrors(
                errors, "Couldn't move to \(Self.folderTitle(folder))", names: names, model: self)
        }
    }

    /// Opens the tag editor for the viewer's photo, or else the selection.
    func editTags() {
        let ids = viewerPhotoID.map { [$0] } ?? Array(selection)
        if !ids.isEmpty { tagEditorPhotoIDs = ids }
    }

    var canEditTags: Bool { library != nil && (viewerPhotoID != nil || !selection.isEmpty) }

    // MARK: - Helpers

    private func stems(ofPhotosIn folder: String) async -> [Int64: String] {
        guard let index = library?.index else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            let ids = (try? index.sections(for: PhotoQuery(scope: .folder(folder))).flatMap(\.photoIDs)) ?? []
            return Self.stems(ids, index: index)
        }.value
    }

    nonisolated private static func stems(_ ids: [Int64], index: LibraryIndex) -> [Int64: String] {
        var names: [Int64: String] = [:]
        for id in ids { if let photo = try? index.photo(id: id) { names[id] = photo.stem } }
        return names
    }

    static func folderTitle(_ path: String) -> String {
        path.isEmpty ? "Unsorted" : "“\(lastComponent(path).replacingOccurrences(of: ":", with: "/"))”"
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// A name prompt as a sheet on the main window; nil if cancelled or empty.
    private static func askName(title: String, message: String, button: String, initial: String) async -> String? {
        guard let window = NSApp.keyWindow else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

struct OrganizeError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The sidebar's context menu for one item: New Album… on Unsorted, groups and albums (inside it), Rename… on
/// albums and groups, Delete Album… on albums.
struct SidebarItemMenu: View {
    let item: SidebarItem
    let model: AppModel

    var body: some View {
        if let folder = item.albumFolder {
            Button("New Album…") { Task { await model.newAlbum(in: folder, select: true) } }
            if !folder.isEmpty {
                Button("Rename…") { Task { await model.renameAlbum(item) } }
            }
            if item.isAlbum {
                Divider()
                Button("Delete Album…") { Task { await model.deleteAlbum(item) } }
            }
        }
    }
}

/// Photos dragged from the grid onto an album or Unsorted are moved there. The ids are read from the drag
/// pasteboard, one per item; anything else (Finder files) is refused.
struct SidebarDropDelegate: DropDelegate {
    let folder: String
    let model: AppModel

    private func photoIDs() -> [Int64] {
        PhotoGridController.photoIDs(in: NSPasteboard(name: .drag).pasteboardItems ?? [])
    }

    func validateDrop(info: DropInfo) -> Bool { !photoIDs().isEmpty }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        let ids = photoIDs()
        guard !ids.isEmpty else { return false }
        model.move(ids, toFolder: folder)
        return true
    }
}

extension View {
    /// The context menu and the drop target of a sidebar row (none for Library, Favorites, Recently Added, tags;
    /// no drop on groups).
    @ViewBuilder func sidebarOrganizing(_ item: SidebarItem, model: AppModel) -> some View {
        let withMenu = Group {
            if item.albumFolder != nil {
                self.contextMenu { SidebarItemMenu(item: item, model: model) }
            } else {
                self
            }
        }
        if case .folder(let folder)? = item.dropTarget {
            withMenu.onDrop(of: [.fileURL], delegate: SidebarDropDelegate(folder: folder, model: model))
        } else {
            withMenu
        }
    }
}
