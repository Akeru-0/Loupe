import AppKit
import LoupeIndex
import SwiftUI

/// Where the import goes: Photos (the default, a folder at the top of the library), an album from the album tree, or New Album… (a name and an optional group, which defaults to the current year:
/// `2026/<name>`).
struct DestinationPicker: View {
    var model: AppModel
    var importModel: ImportModel

    var body: some View {
        Menu {
            choose("Photos", .photos)
            let albums = model.sidebar.first { $0.id == "albums" }?.items ?? []
            if !albums.isEmpty {
                Divider()
                ForEach(albums) { AlbumDestinationItem(item: $0, importModel: importModel) }
            }
            Divider()
            Button("New Album…") { Task { await askNewAlbum() } }
        } label: {
            Label("Import to \(title)", systemImage: "folder")
        }
        .fixedSize()
        .help("Where the photos go")
    }

    private var title: String {
        switch importModel.destination {
        case .photos: return "Photos"
        case .unsorted: return "Library"  // chosen before Unsorted went: the top of the library
        case .album(let path): return Self.display(path)
        case .newAlbum: return "New Album “\(Self.display(importModel.destination.folder))”"
        }
    }

    private func choose(_ title: String, _ destination: ImportDestination) -> some View {
        Button {
            importModel.destination = destination
        } label: {
            if importModel.destination == destination { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    /// `2026/Iceland` as "2026 › Iceland" (a `:` on disk is a `/` in Finder).
    static func display(_ path: String) -> String {
        path.split(separator: "/").map { $0.replacingOccurrences(of: ":", with: "/") }.joined(separator: " › ")
    }

    /// Asks for the new album's name and group (prefilled with the current year) as a sheet on the main window.
    private func askNewAlbum() async {
        guard let window = NSApp.keyWindow else { return }
        let name = NSTextField(string: "")
        name.placeholderString = "Album name"
        let group = NSTextField(string: ImportDestination.defaultGroup())
        group.placeholderString = "None (top level)"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), name],
            [NSTextField(labelWithString: "In group:"), group],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)

        let alert = NSAlert()
        alert.messageText = "New Album"
        alert.informativeText = "The album is created in the group when the import starts. Leave the group empty "
            + "to put the album at the top level."
        alert.accessoryView = grid
        alert.window.initialFirstResponder = name
        alert.addButton(withTitle: "Use Album")
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }

        let albumName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupPath = group.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupParts = groupPath.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard ImportDestination.isValidName(albumName),
            groupParts.allSatisfy({ ImportDestination.isValidName($0) || $0.isEmpty })
        else {
            model.present(ImportUIError(
                "“\(albumName)” can't be used as an album name. Names can't be empty, start with a dot, "
                    + "or contain “:”; the group can't contain such names either."))
            return
        }
        importModel.destination = .newAlbum(name: albumName, inGroup: groupPath.isEmpty ? nil : groupPath)
    }
}

/// An album in the destination menu; one with subfolders opens a submenu that starts with the album itself.
/// A group only opens a submenu.
private struct AlbumDestinationItem: View {
    let item: SidebarItem
    let importModel: ImportModel

    var body: some View {
        if item.children.isEmpty {
            if item.isAlbum, let folder = item.albumFolder { choose(item.title, folder) }
        } else {
            Menu(item.title) {
                if item.isAlbum, let folder = item.albumFolder {
                    choose(item.title, folder)
                    Divider()
                }
                ForEach(item.children) { AlbumDestinationItem(item: $0, importModel: importModel) }
            }
        }
    }

    private func choose(_ title: String, _ folder: String) -> some View {
        Button {
            importModel.destination = .album(folder)
        } label: {
            if importModel.destination == .album(folder) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
