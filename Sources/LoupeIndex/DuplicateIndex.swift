import Foundation
import GRDB
import LoupeCore

public enum DuplicateError: LocalizedError, Equatable {
    /// The photo (its name) has a media file with no identical copy in the photo being kept.
    case notRedundant(String)

    public var errorDescription: String? {
        switch self {
        case .notRedundant(let name):
            "\(name) wasn't moved to the Trash: it has files that aren't identical copies of the photo you kept."
        }
    }
}

/// Photo groups that share byte-identical media files (same size, same SHA-256). Groups linked through any shared
/// file form one set, so a copied RAW+JPEG pair is one set, not two.
public struct DuplicateSet: Identifiable, Hashable, Sendable {
    /// One media file with an identical copy in another group of the set.
    public struct Member: Hashable, Sendable {
        public var photoId: Int64
        public var versionPath: String
        public var kind: VersionKind
        /// The photo's folder (root-relative, `""` is the root).
        public var folder: String
        public var size: Int64
        public var sha256: String

        public init(photoId: Int64, versionPath: String, kind: VersionKind, folder: String, size: Int64, sha256: String) {
            self.photoId = photoId
            self.versionPath = versionPath
            self.kind = kind
            self.folder = folder
            self.size = size
            self.sha256 = sha256
        }
    }

    /// One photo group of the set.
    public struct Copy: Hashable, Sendable {
        public var photoId: Int64
        public var folder: String
        public var stem: String
        public var captureDate: Date?
        /// All the group's media files (sidecars do not count).
        public var bytes: Int64
        public var mediaFileCount: Int
        /// Every media file of this group has an identical copy in one other group of the set.
        public var redundant: Bool

        public init(
            photoId: Int64, folder: String, stem: String, captureDate: Date?, bytes: Int64, mediaFileCount: Int,
            redundant: Bool
        ) {
            self.photoId = photoId
            self.folder = folder
            self.stem = stem
            self.captureDate = captureDate
            self.bytes = bytes
            self.mediaFileCount = mediaFileCount
            self.redundant = redundant
        }
    }

    /// The smallest photo id of the set (stable while its photos keep their ids).
    public var id: Int64
    public var members: [Member]
    public var copies: [Copy]

    public init(id: Int64, members: [Member], copies: [Copy]) {
        self.id = id
        self.members = members
        self.copies = copies
    }

    /// The copies that may go to the Trash when `kept` stays: those, other than `kept`, whose every media file has a
    /// byte-identical copy in `kept`. A group with a file of its own (an edit, a RAW) is never listed.
    public func removable(keeping kept: Int64) -> [Int64] {
        let keptHashes = hashes(of: kept)
        return copies.filter { $0.photoId != kept && covers(keptHashes, $0) }.map(\.photoId)
    }

    /// The most the set frees: the size of the copies removable when keeping the best one.
    public var reclaimableBytes: Int64 {
        let bytes = Dictionary(uniqueKeysWithValues: copies.map { ($0.photoId, $0.bytes) })
        return copies.map { removable(keeping: $0.photoId).reduce(0) { $0 + (bytes[$1] ?? 0) } }.max() ?? 0
    }

    fileprivate func hashes(of photo: Int64) -> Set<String> {
        Set(members.filter { $0.photoId == photo }.map(\.sha256))
    }

    /// True if each of `copy`'s media files is a member with a hash in `hashes`.
    fileprivate func covers(_ hashes: Set<String>, _ copy: Copy) -> Bool {
        let mine = members.filter { $0.photoId == copy.photoId }
        return mine.count == copy.mediaFileCount && mine.allSatisfy { hashes.contains($0.sha256) }
    }
}

/// Finds byte-identical media files in the library: `version` rows grouped by size; only sizes shared by two or
/// more photo groups are hashed (streamed SHA-256, cached in `file_hash` while size and mtime match, so a refresh
/// reads only new or changed files); equal hashes across two or more groups become `duplicate_member` rows.
/// A file is never read without a size match, and empty files are never duplicates.
public struct DuplicateIndex: Sendable {
    public typealias Hasher = @Sendable (URL) throws -> String

    /// One `duplicate_member` row.
    struct Row: Hashable, Sendable {
        var setId: Int64
        var versionPath: String
        var photoId: Int64
        var sha256: String
    }

    private let index: LibraryIndex
    private let root: URL
    private let hasher: Hasher

    public init(index: LibraryIndex, root: URL) {
        self.init(index: index, root: root, hasher: { try FileHash.sha256(of: $0) })
    }

    init(index: LibraryIndex, root: URL, hasher: @escaping Hasher) {
        self.index = index
        self.root = root
        self.hasher = hasher
    }

    /// Hashes and stores in one go. `Library` splits it: `compute` outside its serial section, `store` inside.
    /// `progress(done, total)` counts the files with a size match. Throws `CancellationError` (storing nothing).
    public func refresh(progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws {
        let rows = try await compute(progress: progress)
        try Task.checkCancellation()
        _ = try store(rows)
    }

    /// Reads the index and hashes candidates; writes only the hash cache.
    func compute(progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> [Row] {
        let versions = try await index.dbPool.read { db in
            try GRDB.Row.fetchAll(db, sql: "SELECT path, photoId, size FROM version WHERE size > 0 ORDER BY path")
                .map { (path: $0["path"] as String, photoId: $0["photoId"] as Int64, size: $0["size"] as Int64) }
        }
        let candidates = Dictionary(grouping: versions, by: \.size).values
            .filter { Set($0.map(\.photoId)).count >= 2 }  // same-size files inside one group can't be copies
            .flatMap { $0 }
            .sorted { $0.path < $1.path }

        var byHash: [String: [(path: String, photoId: Int64)]] = [:]
        for (i, c) in candidates.enumerated() {
            try Task.checkCancellation()
            progress(i, candidates.count)
            let url = VersionRecord(photoId: c.photoId, path: c.path, kind: .image, size: c.size, modified: .distantPast)
                .url(in: root)
            // The index may lag behind the disk: a file whose size changed waits for its rescan.
            guard FileHash.stamp(url)?.size == c.size,
                let sha = try index.cachedSHA256(of: url, hasher: hasher)
            else { continue }
            byHash[sha, default: []].append((c.path, c.photoId))
        }
        progress(candidates.count, candidates.count)
        return Self.rows(byHash)
    }

    /// Hashes held by two or more photo groups, with each file's set: the smallest photo id of the groups linked
    /// through shared hashes.
    static func rows(_ byHash: [String: [(path: String, photoId: Int64)]]) -> [Row] {
        let shared = byHash.filter { Set($0.value.map(\.photoId)).count >= 2 }
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var x = x
            while let p = parent[x], p != x { x = p }
            return x
        }
        for files in shared.values {
            let photos = files.map(\.photoId)
            for p in photos where parent[p] == nil { parent[p] = p }
            for p in photos.dropFirst() {
                let a = find(photos[0]), b = find(p)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        return shared.flatMap { sha, files in
            files.map { Row(setId: find($0.photoId), versionPath: $0.path, photoId: $0.photoId, sha256: sha) }
        }.sorted { $0.versionPath < $1.versionPath }
    }

    /// Replaces the stored members with `rows`, skipping files no longer indexed under the same photo. Returns
    /// whether the stored members changed.
    func store(_ rows: [Row]) throws -> Bool {
        try index.dbPool.write { db in
            let before = try Self.stored(db)
            try db.execute(sql: "DELETE FROM duplicate_member")
            for r in rows {
                try db.execute(
                    sql: """
                        INSERT INTO duplicate_member(setId, versionPath, photoId, sha256) SELECT ?, ?, ?, ?
                        WHERE EXISTS (SELECT 1 FROM version WHERE path = ? AND photoId = ?)
                        """,
                    arguments: [r.setId, r.versionPath, r.photoId, r.sha256, r.versionPath, r.photoId])
            }
            return try Self.stored(db) != before
        }
    }

    private static func stored(_ db: Database) throws -> Set<Row> {
        Set(try GRDB.Row.fetchAll(db, sql: "SELECT setId, versionPath, photoId, sha256 FROM duplicate_member").map {
            Row(setId: $0["setId"], versionPath: $0["versionPath"], photoId: $0["photoId"], sha256: $0["sha256"])
        })
    }
}

extension LibraryIndex {
    /// The duplicate sets from the last refresh, limited to what is still indexed: a member whose file or photo
    /// is gone drops out, and a hash left in one group is no duplicate. Sorted by folder and name.
    public func duplicateSets() throws -> [DuplicateSet] {
        let (rows, totals) = try dbPool.read { db in
            let rows = try GRDB.Row.fetchAll(db, sql: """
                SELECT d.versionPath, d.photoId, d.sha256, v.kind, v.size, p.folderPath, p.stem, p.captureDate
                FROM duplicate_member d
                JOIN version v ON v.path = d.versionPath AND v.photoId = d.photoId
                JOIN photo p ON p.id = d.photoId
                ORDER BY d.versionPath
                """)
            let totals = try GRDB.Row.fetchAll(db, sql: """
                SELECT photoId, COUNT(*) AS n, SUM(size) AS bytes FROM version
                WHERE photoId IN (SELECT photoId FROM duplicate_member) GROUP BY photoId
                """)
            return (rows, totals)
        }
        struct Photo { var folder: String; var stem: String; var captureDate: Date? }
        var photos: [Int64: Photo] = [:]
        var byHash: [String: [(path: String, photoId: Int64)]] = [:]
        var members: [String: DuplicateSet.Member] = [:]
        for row in rows {
            let path: String = row["versionPath"], id: Int64 = row["photoId"], sha: String = row["sha256"]
            let folder: String = row["folderPath"]
            let capture: Double? = row["captureDate"]
            photos[id] = Photo(folder: folder, stem: row["stem"], captureDate: capture.map(Date.init(timeIntervalSince1970:)))
            byHash[sha, default: []].append((path, id))
            members[path] = DuplicateSet.Member(
                photoId: id, versionPath: path, kind: VersionKind(rawValue: row["kind"]) ?? .image, folder: folder,
                size: row["size"], sha256: sha)
        }
        var counts: [Int64: (n: Int, bytes: Int64)] = [:]
        for row in totals { counts[row["photoId"]] = (row["n"], row["bytes"]) }

        let grouped = Dictionary(grouping: DuplicateIndex.rows(byHash), by: \.setId)
        var sets: [DuplicateSet] = grouped.map { setId, rows in
            var set = DuplicateSet(id: setId, members: rows.compactMap { members[$0.versionPath] }, copies: [])
            let ids = Set(rows.map(\.photoId)).sorted()
            set.copies = ids.compactMap { id in
                guard let p = photos[id], let c = counts[id] else { return nil }
                return DuplicateSet.Copy(
                    photoId: id, folder: p.folder, stem: p.stem, captureDate: p.captureDate, bytes: c.bytes,
                    mediaFileCount: c.n, redundant: false)
            }
            for i in set.copies.indices {
                let copy = set.copies[i]
                set.copies[i].redundant = set.copies.contains {
                    $0.photoId != copy.photoId && set.covers(set.hashes(of: $0.photoId), copy)
                }
            }
            set.copies.sort { ($0.folder, $0.stem, $0.photoId) < ($1.folder, $1.stem, $1.photoId) }
            return set
        }
        sets.sort { a, b in
            let x = a.copies.first, y = b.copies.first
            return (x?.folder ?? "", x?.stem ?? "", a.id) < (y?.folder ?? "", y?.stem ?? "", b.id)
        }
        return sets
    }

    /// For the sidebar's count.
    public func duplicateSetCount() throws -> Int { try duplicateSets().count }
}
