import Foundation
import LoupeCore
import LoupeIndex

/// Library, Favorites, Recently Added.
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
        ]
    }
}

/// Albums known to the index, in catalog order. A corrupt catalog only loses the order.
struct AlbumsSidebarSection: SidebarSection {
    let id = "albums"
    let title: String? = "Albums"
    let order = 100

    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] {
        let catalog = (try? AlbumCatalogIO.load(root: root)) ?? AlbumCatalog()
        return catalog.orderedNames(including: try index.albumNames()).map { name in
            SidebarItem(
                id: "album:\(name)", title: name, systemImage: "rectangle.stack", scope: .album(name),
                dropTarget: .album(name))
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

/// The root (for photos directly in it), then the real folder tree from disk, empty folders included.
/// Hidden, package and excluded folders are skipped, as the scanner skips them.
struct FoldersSidebarSection: SidebarSection {
    let id = "folders"
    let title: String? = "Folders"
    let order = 300

    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] {
        let rootItem = SidebarItem(
            id: "folder:", title: FileManager.default.displayName(atPath: root.path), systemImage: "folder",
            scope: .folder(""), dropTarget: .folder(""))
        return [rootItem] + Self.children(of: root, path: [], settings: settings)
    }

    private static func children(of folder: URL, path: [String], settings: LibrarySettings) -> [SidebarItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { !LoupeIndex.Scanner.ignores(folder: $0, settings: settings) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let components = path + [url.lastPathComponent]
                let relative = components.joined(separator: "/")
                return SidebarItem(
                    id: "folder:\(relative)", title: FileManager.default.displayName(atPath: url.path),
                    systemImage: "folder", scope: .folder(relative),
                    children: children(of: url, path: components, settings: settings), dropTarget: .folder(relative))
            }
    }
}
