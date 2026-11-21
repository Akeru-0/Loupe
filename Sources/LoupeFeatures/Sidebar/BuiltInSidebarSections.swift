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

/// Videos, Panoramas and RAW: smart filters, listed only for types the library has.
struct MediaTypesSidebarSection: SidebarSection {
    let id = "mediaTypes"
    let title: String? = "Media Types"
    let order = 50

    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] {
        let all: [(MediaType, String, String, String)] = [
            (.videos, "videos", "Videos", "video"),
            (.panoramas, "panoramas", "Panoramas", "pano"),
            (.raw, "raw", "RAW", "camera.aperture"),
        ]
        return try all.filter { try index.hasMedia($0.0) }.map {
            SidebarItem(id: "media:\($0.1)", title: $0.2, systemImage: $0.3, scope: .mediaType($0.0))
        }
    }
}

/// People (the people and pets face recognition found, with how many; it opens their grid), Recently Edited (same
/// window as Recently Added), Duplicates (with the number of sets once there are any), Imports, Hidden and Recently
/// Deleted (both locked in the app), and Unable to Upload, only while some photos'
/// cloud upload failed (with their number).
struct UtilitiesSidebarSection: SidebarSection {
    let id = "utilities"
    let title: String? = "Utilities"
    let order = 60

    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] {
        let people = try index.faceGroups().count
        let duplicates = try index.duplicateSetCount()
        let failed = try index.uploadFailurePhotoCount()
        return [
            SidebarItem(
                id: "people", title: "People", systemImage: "person.crop.square", scope: .people,
                badge: people > 0 ? people : nil),
            SidebarItem(
                id: "edited", title: "Recently Edited", systemImage: "slider.horizontal.3",
                scope: .recentlyEdited(days: settings.recentlyAddedDays)),
            SidebarItem(
                id: "duplicates", title: "Duplicates", systemImage: "square.on.square", scope: .duplicates,
                badge: duplicates > 0 ? duplicates : nil),
            SidebarItem(id: "imports", title: "Imports", systemImage: "square.and.arrow.down", scope: .imports),
            SidebarItem(id: "hidden", title: "Hidden", systemImage: "eye.slash", scope: .hidden),
            SidebarItem(id: "deleted", title: "Recently Deleted", systemImage: "trash", scope: .recentlyDeleted),
        ] + (failed > 0 ? [
            SidebarItem(
                id: "upload-failed", title: "Unable to Upload", systemImage: "exclamationmark.icloud",
                scope: .unableToUpload, badge: failed),
        ] : [])
    }
}

/// Smart albums (`SmartAlbumStore`) first, then the folder albums. Albums are folders: the real folder tree under
/// the root. Albums take dropped photos; groups (folders with only
/// subfolders) show everything below them and take no drops. Keyword albums are not shown, nor are the Photos folder
/// imports go to and Recently Deleted (`LibrarySettings.photosFolderName`, `.recentlyDeletedFolderName`).
struct AlbumsSidebarSection: SidebarSection {
    let id = "albums"
    let title: String? = "Albums"
    let order = 100

    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem] {
        let smart = try SmartAlbumStore.load(root: root).map(Self.item)
        return smart + (try index.albumTree(root: root, settings: settings)
            .filter { $0.path != LibrarySettings.photosFolderName && $0.path != LibrarySettings.recentlyDeletedFolderName }
            .map(Self.item))
    }

    /// A smart album: its photos are found by its rules, so it takes no drops.
    static func item(_ album: SmartAlbum) -> SidebarItem {
        SidebarItem(id: "smart:\(album.id)", title: album.name, systemImage: "gearshape", scope: .smartAlbum(album))
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
