import Foundation
import GRDB
import LoupeIndex

/// One file imported from a card (`import_record`, migration v3), keyed by content.
struct ImportRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "import_record"
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    var sha256: String
    var sourceName: String
    var importedAt: Date

    static func all(in index: LibraryIndex) throws -> [ImportRecord] {
        try index.dbPool.read { try ImportRecord.order(Column("sourceName")).fetchAll($0) }
    }
}

/// A cached SHA-256 (`file_hash`, migration v3), valid while the file's size and mtime equal the stored ones.
struct FileHashRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "file_hash"

    var path: String
    var size: Int64
    /// Seconds since 1970.
    var modified: Double
    var sha256: String

    func save(in index: LibraryIndex) throws {
        try index.dbPool.write { try self.save($0) }
    }
}

extension ImportRecord {
    /// Records the imported files and caches the hashes of their library copies (so the next duplicate check
    /// need not read them again). One transaction.
    static func record(
        _ imported: [(record: ImportRecord, copy: FileHashRecord?)], in index: LibraryIndex
    ) throws {
        try index.dbPool.write { db in
            for item in imported {
                try item.record.save(db)
                try item.copy?.save(db)
            }
        }
    }
}
