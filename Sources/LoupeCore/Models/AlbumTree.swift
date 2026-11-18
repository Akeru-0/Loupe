import Foundation

/// One folder under the library root, as the album tree needs it.
public struct FolderInfo: Hashable, Sendable {
    /// Root-relative (`""` is the root).
    public var path: String
    /// Photos indexed directly in this folder (not in subfolders).
    public var directMediaCount: Int
    /// Has at least one subfolder the library shows (not hidden, a package or excluded).
    public var hasSubfolders: Bool

    public init(path: String, directMediaCount: Int, hasSubfolders: Bool) {
        self.path = path
        self.directMediaCount = directMediaCount
        self.hasSubfolders = hasSubfolders
    }
}

/// A folder in the sidebar: an album (photos go in it) or a group (only holds other folders).
public struct AlbumNode: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case album, group }

    /// Root-relative, NFC.
    public var path: String
    /// The folder's own name, NFC.
    public var name: String
    public var kind: Kind
    public var children: [AlbumNode]

    public init(path: String, name: String, kind: Kind, children: [AlbumNode]) {
        self.path = path
        self.name = name
        self.kind = kind
        self.children = children
    }
}

/// Albums are folders. A folder with photos, or an empty one, is an album; a folder with only subfolders is a
/// group. An album may have subfolders too. The library root is never an album (its photos are Unsorted).
public enum AlbumTree {
    public static func build(_ folders: [FolderInfo]) -> [AlbumNode] {
        var byParent: [String: [FolderInfo]] = [:]
        for var folder in folders {
            folder.path = folder.path.precomposedStringWithCanonicalMapping
            guard !folder.path.isEmpty else { continue }
            byParent[parent(of: folder.path), default: []].append(folder)
        }
        func nodes(under parent: String) -> [AlbumNode] {
            (byParent[parent] ?? [])
                .map { folder in
                    let isAlbum = folder.directMediaCount > 0 || !folder.hasSubfolders
                    return AlbumNode(
                        path: folder.path, name: name(of: folder.path), kind: isAlbum ? .album : .group,
                        children: nodes(under: folder.path))
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return nodes(under: "")
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}
