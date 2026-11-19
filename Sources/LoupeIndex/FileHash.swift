import CryptoKit
import Foundation
import GRDB

/// Streamed SHA-256: memory stays at one chunk however large the file.
public enum FileHash {
    public static let chunkSize = 4 << 20

    /// Lowercase hex SHA-256 of the file's bytes. Opens the file read-only. `uncached` reads past the page
    /// cache (`F_NOCACHE`), so a just-written copy is verified from the disk.
    public static func sha256(of url: URL, uncached: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if uncached { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: chunkSize) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Size and modification time from `stat` (follows symlinks), or nil if the file is gone or not a regular file.
    public static func stamp(_ url: URL) -> (size: Int64, modified: Double)? {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (Int64(st.st_size), Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }
}

/// A cached SHA-256 (`file_hash`, migration v3), valid while the file's size and mtime equal the stored ones.
/// Keyed by absolute path; shared by the import duplicate check and the library's Duplicates.
public struct FileHashRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "file_hash"

    public var path: String
    public var size: Int64
    /// Seconds since 1970.
    public var modified: Double
    public var sha256: String

    public init(path: String, size: Int64, modified: Double, sha256: String) {
        self.path = path
        self.size = size
        self.modified = modified
        self.sha256 = sha256
    }

    public func save(in index: LibraryIndex) throws {
        try index.dbPool.write { try self.save($0) }
    }
}

extension LibraryIndex {
    /// The file's SHA-256 from `file_hash` if its size and mtime still match, else read with `hasher` now and
    /// stored (only if the file did not change while it was read). Nil if the file is gone or unreadable.
    public func cachedSHA256(of url: URL, hasher: (URL) throws -> String) throws -> String? {
        guard let stamp = FileHash.stamp(url) else { return nil }
        let path = url.path
        let cached = try dbPool.read { db in
            try GRDB.Row.fetchOne(db, sql: "SELECT size, modified, sha256 FROM file_hash WHERE path = ?", arguments: [path])
        }
        if let cached, (cached["size"] as Int64) == stamp.size,
            abs((cached["modified"] as Double) - stamp.modified) < 0.001
        {
            return cached["sha256"] as String
        }
        guard let sha = try? hasher(url) else { return nil }
        if let after = FileHash.stamp(url), after == stamp {
            try FileHashRecord(path: path, size: stamp.size, modified: stamp.modified, sha256: sha).save(in: self)
        }
        return sha
    }
}
