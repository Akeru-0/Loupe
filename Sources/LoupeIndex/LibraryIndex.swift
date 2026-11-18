import Foundation
import GRDB
import LoupeCore

extension PhotoRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "photo"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension VersionRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "version"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The disposable SQLite index. Disk (files + sidecars) is the source of truth.
public final class LibraryIndex: Sendable {
    public let dbPool: DatabasePool

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        dbPool = try DatabasePool(path: databaseURL.path)
        try Schema.migrator().migrate(dbPool)
    }

    public func photo(id: Int64) throws -> PhotoRecord? {
        try dbPool.read { try PhotoRecord.fetchOne($0, key: id) }
    }

    /// `key` is `stem` at the root, else `folderPath/stem`. Matching is by normalized stem key.
    public func photo(key: String) throws -> PhotoRecord? {
        var folder: String
        let stem: String
        if let slash = key.lastIndex(of: "/") {
            folder = String(key[key.startIndex..<slash])
            stem = String(key[key.index(after: slash)...])
        } else {
            folder = ""
            stem = key
        }
        let stemKey = PhotoGrouper.stemKey(stem)
        folder = folder.precomposedStringWithCanonicalMapping
        return try dbPool.read { db in
            try PhotoRecord.fetchAll(db, sql: "SELECT * FROM photo WHERE folderPath = ? AND stemKey = ?",
                                     arguments: [folder, stemKey]).first
        }
    }

    public func allPhotos() throws -> [PhotoRecord] {
        try dbPool.read { try PhotoRecord.order(sql: "folderPath, stemKey").fetchAll($0) }
    }

    public func versions(ofPhoto id: Int64) throws -> [VersionRecord] {
        try dbPool.read { db in
            try VersionRecord.fetchAll(db, sql: "SELECT * FROM version WHERE photoId = ? ORDER BY id", arguments: [id])
        }
    }

    public func metadata(ofPhoto id: Int64) throws -> PhotoMetadata {
        try dbPool.read { db in
            guard let p = try PhotoRecord.fetchOne(db, key: id) else { return PhotoMetadata() }
            let tags = try String.fetchAll(db, sql: "SELECT name FROM photo_tag WHERE photoId = ? ORDER BY name", arguments: [id])
            let albums = try String.fetchAll(db, sql: "SELECT name FROM photo_album WHERE photoId = ? ORDER BY name", arguments: [id])
            return PhotoMetadata(rating: p.rating, tags: tags, albums: albums,
                                 isFavorite: p.isFavorite, hasLightCraftEdits: p.hasLightCraftEdits)
        }
    }

    /// Rebuilds the on-disk group of a photo from its stored versions (no disk scan of the folder).
    public func groupFiles(ofPhoto id: Int64, root: URL) throws -> PhotoGroup {
        guard let photo = try photo(id: id) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let versions = try versions(ofPhoto: id)
        let folder = VersionRecord(photoId: id, path: photo.folderPath, kind: .image, size: 0, modified: .distantPast)
            .url(in: root)
        let fm = FileManager.default
        let grouped = versions.map {
            GroupedVersion(file: MediaFile(url: $0.url(in: root), size: $0.size, modified: $0.modified, created: $0.modified),
                           kind: $0.kind)
        }
        let sidecarURL = folder.appendingPathComponent(photo.stem + ".xmp")
        let legacy = grouped.map { $0.file.url.appendingPathExtension("xmp") }
            .filter { fm.fileExists(atPath: $0.path) }
        return PhotoGroup(
            folder: folder, stem: photo.stem, stemKey: photo.stemKey, versions: grouped,
            sidecar: fm.fileExists(atPath: sidecarURL.path) ? sidecarURL : nil, legacySidecars: legacy)
    }
}
