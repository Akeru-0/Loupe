import CoreGraphics
import Foundation
import GRDB
import LoupeCore
import LoupeIndex
import LoupeMedia

/// Finds people and pets in the library's photos, on this Mac: each photo's shown file is scanned once (again when
/// it changes or is turned), the faces and animals found are stored with their vectors, and then everything is
/// grouped so each person or pet gets a group (`face_group`) that People lists. Videos and Recently Deleted are
/// skipped.
public actor FaceScanner {
    public struct Report: Sendable, Equatable {
        public var scanned = 0
        public var found = 0
        public var groups = 0
    }

    /// Photos are scanned at this size: enough for faces a few percent of the frame wide.
    static let scanPixelSize = 1600

    private let index: LibraryIndex
    private let root: URL
    private let pets: Bool
    private let sface: SFace

    /// Throws if the model can't be loaded (ONNX Runtime missing, a damaged model).
    public init(index: LibraryIndex, root: URL, model: URL, pets: Bool) throws {
        self.index = index
        self.root = root
        self.pets = pets
        sface = try SFace(model: model)
    }

    /// Whether ONNX Runtime is where Loupe looks for it.
    public static var runtimeInstalled: Bool { SFace.installedRuntime != nil }

    /// Scans what needs scanning, then regroups. `progress`: photos done, photos to do.
    public func run(progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Report {
        let pending = try Self.pendingPhotos(in: index)
        var report = Report()
        for (i, photo) in pending.enumerated() {
            try Task.checkCancellation()
            let found = scan(photo)
            try await index.dbPool.write { db in
                try db.execute(sql: "DELETE FROM face WHERE photoId = ?", arguments: [photo.id])
                for d in found {
                    try db.execute(
                        sql: "INSERT INTO face(photoId, kind, x, y, w, h, embedding) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        arguments: [photo.id, d.kind, d.box.minX, d.box.minY, d.box.width, d.box.height,
                                    Vectors.data(d.vector)])
                }
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO face_scan(photoId, versionPath, modified, rotation, scannedAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [photo.id, photo.path, photo.modified, photo.rotation, Date().timeIntervalSince1970])
            }
            report.scanned += 1
            report.found += found.count
            progress(i + 1, pending.count)
        }
        report.groups = try await Self.regroup(in: index, root: root)
        return report
    }

    /// People ▸ Rename: gives the group's faces `name` (nil removes the name it has), saves it with the library and
    /// regroups, so a group named like another joins it.
    public static func rename(group: Int64, to name: String?, index: LibraryIndex, root: URL) async throws {
        let (kind, current, vectors) = try await index.dbPool.read { db -> (String?, String?, [[Float]]) in
            let row = try Row.fetchOne(db, sql: "SELECT kind, name FROM face_group WHERE id = ?", arguments: [group])
            let vectors = try Data.fetchAll(db, sql: "SELECT embedding FROM face WHERE groupId = ?", arguments: [group])
                .map(Vectors.floats)
            return (row?["kind"], row?["name"], vectors)
        }
        guard let kind else { return }
        var names = PeopleNames.load(root: root)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            if let current { names.forget(current, kind: kind) }
        } else {
            names.name(trimmed, kind: kind, vectors: vectors, previous: current)
        }
        try names.save(root: root)
        try await regroup(in: index, root: root)
    }

    /// Where a corrected face goes.
    public enum Target: Sendable, Equatable {
        /// Out of every group.
        case nobody
        /// The person or pet called this.
        case name(String)
        /// Another group as it is now, named or not.
        case group(Int64)
    }

    /// A correction in a person's photos: their faces in `photos` move to `target`. Returns the id the group has
    /// afterwards (its lowest face may have left), nil if nobody is left.
    public static func move(
        photos: [Int64], from group: Int64, to target: Target, index: LibraryIndex, root: URL
    ) async throws -> Int64? {
        let (kind, vectors, staying) = try await index.dbPool.read { db -> (String?, [[Float]], Int64?) in
            let kind = try String.fetchOne(db, sql: "SELECT kind FROM face_group WHERE id = ?", arguments: [group])
            let placeholders = Array(repeating: "?", count: photos.count).joined(separator: ",")
            var arguments = StatementArguments([group])
            arguments += StatementArguments(photos)
            let vectors = try Data.fetchAll(
                db, sql: "SELECT embedding FROM face WHERE groupId = ? AND photoId IN (\(placeholders))",
                arguments: arguments
            ).map(Vectors.floats)
            let staying = try Int64.fetchOne(
                db, sql: "SELECT id FROM face WHERE groupId = ? AND photoId NOT IN (\(placeholders)) ORDER BY id LIMIT 1",
                arguments: arguments)
            return (kind, vectors, staying)
        }
        guard let kind, !vectors.isEmpty else { return group }
        var names = PeopleNames.load(root: root)
        let name: String?
        switch target {
        case .nobody: name = nil
        case .name(let given): name = given
        case .group(let other):
            // An unnamed group gets a hidden name (shown as "Cat 2" all the same), so the correction can point at
            // it however the faces are grouped later.
            let (current, faces) = try await index.dbPool.read { db in
                (try String.fetchOne(db, sql: "SELECT name FROM face_group WHERE id = ?", arguments: [other]),
                 try Data.fetchAll(db, sql: "SELECT embedding FROM face WHERE groupId = ?", arguments: [other])
                    .map(Vectors.floats))
            }
            if let current {
                name = current
            } else {
                let hidden = PeopleNames.hiddenPrefix + UUID().uuidString
                names.name(hidden, kind: kind, vectors: faces, previous: nil)
                name = hidden
            }
        }
        names.pin(vectors, kind: kind, to: name)
        try names.save(root: root)
        try await regroup(in: index, root: root)
        guard let staying else { return nil }
        return try await index.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT groupId FROM face WHERE id = ?", arguments: [staying])
        }
    }

    /// Forgets what was scanned, so the next run scans every photo again (after Group pets is turned on).
    public func forgetScans() async throws {
        try await index.dbPool.write { try $0.execute(sql: "DELETE FROM face_scan") }
    }

    // MARK: - Steps

    struct Pending: Sendable {
        var id: Int64
        var path: String
        var modified: Double
        var rotation: Int?
    }

    /// Photos whose shown file wasn't scanned, or changed or turned since.
    static func pendingPhotos(in index: LibraryIndex) throws -> [Pending] {
        let deleted = LibrarySettings.recentlyDeletedFolderName
        return try index.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.id, v.path, v.modified, p.rotation FROM photo p
                    JOIN version v ON v.photoId = p.id AND v.isDisplay = 1
                    LEFT JOIN face_scan s ON s.photoId = p.id
                    WHERE v.kind NOT IN ('video') AND NOT (p.folderPath = ? OR p.folderPath LIKE ? ESCAPE '\\')
                    AND (s.photoId IS NULL OR s.versionPath != v.path OR s.modified != v.modified
                         OR IFNULL(s.rotation, 0) != IFNULL(p.rotation, 0))
                    ORDER BY p.captureDate DESC
                    """,
                arguments: [deleted, LibraryIndex.escapeLike(deleted) + "/%"]
            ).map { Pending(id: $0["id"], path: $0["path"], modified: $0["modified"], rotation: $0["rotation"]) }
        }
    }

    /// What one photo shows; nothing if it can't be read (it is recorded as scanned all the same).
    private func scan(_ photo: Pending) -> [Detection] {
        let url = photo.path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        guard let image = ImageLoader.image(at: url, maxPixelSize: Self.scanPixelSize, rotation: photo.rotation),
            var found = try? FaceDetector.detect(image, pets: pets)
        else { return [] }
        let pixels = found.contains { $0.kind == "person" } ? RGBAImage(image) : nil
        for i in found.indices where found[i].kind == "person" {
            guard let pixels, let vector = try? sface.vector(FaceAlignment.input(from: pixels, points: found[i].landmarks))
            else { continue }
            found[i].vector = vector
        }
        return found.filter { !$0.vector.isEmpty }
    }

    /// Groups every stored face again (named people first, `PeopleNames`) and rewrites `face_group`. Returns the
    /// number of groups.
    @discardableResult
    static func regroup(in index: LibraryIndex, root: URL) async throws -> Int {
        let names = PeopleNames.load(root: root)
        return try await index.dbPool.write { db in
            var faces: [FaceGrouping.Face] = []
            var photoOf: [Int64: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, photoId, kind, w * h AS size, embedding FROM face") {
                let id: Int64 = row["id"]
                photoOf[id] = row["photoId"]
                faces.append(FaceGrouping.Face(id: id, kind: row["kind"], vector: Vectors.floats(row["embedding"]), size: row["size"]))
            }
            let (groups, groupNames) = FaceGrouping.group(faces, names: names)
            try db.execute(sql: "DELETE FROM face_group")
            // Faces left out (corrected to nobody) must lose the group they had, or they'd still show in it.
            try db.execute(sql: "UPDATE face SET groupId = NULL")
            var byGroup: [Int64: [FaceGrouping.Face]] = [:]
            for face in faces {
                guard let group = groups[face.id] else { continue }
                try db.execute(sql: "UPDATE face SET groupId = ? WHERE id = ?", arguments: [group, face.id])
                byGroup[group, default: []].append(face)
            }
            for (group, members) in byGroup {
                let cover = members.max { $0.size < $1.size }!
                try db.execute(
                    sql: "INSERT INTO face_group(id, kind, photoCount, coverFaceId, name) VALUES (?, ?, ?, ?, ?)",
                    arguments: [group, cover.kind, Set(members.compactMap { photoOf[$0.id] }).count, cover.id,
                                groupNames[group]])
            }
            return byGroup.count
        }
    }
}
