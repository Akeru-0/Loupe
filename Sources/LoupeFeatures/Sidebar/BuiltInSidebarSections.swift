import Foundation
import LoupeCore
import LoupeIndex

/// Library, Favorites, Recently Added, Unsorted (the photos loose in the root).
struct LibrarySidebarSection: SidebarSection {
    let id = "library"
    let title: String? = nil
    let order = 0

    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] {
        [
            SidebarItem(id: "library", title: "Library", systemImage: "photo.on.rectangle", scope: .all),
            SidebarItem(id: "favorites", title: "Favorites", systemImage: "heart", scope: .favorites),
            SidebarItem(
                id: "recent", title: "Recently Added", systemImage: "clock",
                scope: .recentlyAdded(days: settings.recentlyAddedDays)),
            SidebarItem(id: "unsorted", title: "Unsorted", systemImage: "tray", scope: .unsorted, dropTarget: .folder("")),
        ]
    }
}

/// Albums are folders: the real folder tree under the root. Albums take dropped photos; groups (folders with only
/// subfolders) show everything below them and take no drops. Keyword albums are not shown.
struct AlbumsSidebarSection: SidebarSection {
    let id = "albums"
    let title: String? = "Albums"
    let order = 100

    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] {
        try index.albumTree(root: root, settings: settings).map(Self.item)
    }

    static func item(_ node: AlbumNode) -> SidebarItem {
        // ":" in a name on disk is "/" in Finder.
        let title = node.name.replacingOccurrences(of: ":", with: "/")
        switch node.kind {
        case .album:
            return SidebarItem(
                id: "folder:\(node.path)", title: title, systemImage: "rectangle.stack", scope: .folder(node.path),
                children: node.children.map(item), dropTarget: .folder(node.path))
        case .group:
            return SidebarItem(
                id: "folder:\(node.path)", title: title, systemImage: "folder", scope: .folderTree(node.path),
                children: node.children.map(item))
        }
    }
}

struct TagsSidebarSection: SidebarSection {
    let id = "tags"
    let title: String? = "Tags"
    let order = 200

    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] {
        try index.allTags().map { SidebarItem(id: "tag:\($0)", title: $0, systemImage: "tag", scope: .tag($0)) }
    }
}
