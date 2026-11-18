import Foundation

public struct AlbumEntry: Codable, Equatable, Sendable {
    public var name: String
    /// A photo key (`folder/stem`).
    public var cover: String?

    public init(name: String, cover: String? = nil) {
        self.name = name
        self.cover = cover
    }
}

/// `<root>/.loupe/albums.json`: album order and covers. Membership lives in the XMP sidecars.
public struct AlbumCatalog: Codable, Equatable, Sendable {
    public var version = 1
    public var albums: [AlbumEntry]

    public init(albums: [AlbumEntry] = []) { self.albums = albums }

    /// Catalog order first (only albums that still exist), then unlisted known albums alphabetically.
    public func orderedNames(including known: Set<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in albums where known.contains(entry.name) && seen.insert(entry.name).inserted {
            result.append(entry.name)
        }
        result += known.subtracting(seen).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return result
    }
}

public enum AlbumCatalogError: Error { case corrupt }

public enum AlbumCatalogIO {
    public static func url(root: URL) -> URL {
        root.appendingPathComponent(".loupe", isDirectory: true).appendingPathComponent("albums.json")
    }

    /// A missing file is an empty catalog; unreadable JSON throws `.corrupt` (and is never overwritten here).
    public static func load(root: URL) throws -> AlbumCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: url(root: root))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return AlbumCatalog()
        }
        do {
            return try JSONDecoder().decode(AlbumCatalog.self, from: data)
        } catch {
            throw AlbumCatalogError.corrupt
        }
    }

    public static func save(_ catalog: AlbumCatalog, root: URL) throws {
        let target = url(root: root)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(to: target, options: .atomic)
    }
}
