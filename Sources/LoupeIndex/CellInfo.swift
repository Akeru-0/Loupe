import Foundation
import GRDB
import LoupeCore

/// What a grid cell shows for one photo.
public struct CellInfo: Hashable, Sendable {
    public var id: Int64
    public var displayFile: MediaFile
    public var displayKind: VersionKind
    public var rating: Int
    public var isFavorite: Bool
    public var hasLightCraftEdits: Bool
    /// The photo's extra turn on top of the display file's own orientation (`PhotoRecord.rotation`).
    public var rotation: Int?
    /// Bottom-left labels: the photo's kinds ("RAW", "JPG", "EDIT", "LIVE") or a video's duration.
    public var badges: [String]

    public init(
        id: Int64, displayFile: MediaFile, displayKind: VersionKind, rating: Int, isFavorite: Bool,
        hasLightCraftEdits: Bool, rotation: Int? = nil, badges: [String]
    ) {
        self.id = id
        self.displayFile = displayFile
        self.displayKind = displayKind
        self.rating = rating
        self.isFavorite = isFavorite
        self.hasLightCraftEdits = hasLightCraftEdits
        self.rotation = rotation
        self.badges = badges
    }

    /// A video shows its duration. Otherwise the kinds, except that a lone still format (just a JPEG) shows nothing
    /// and a Live Photo shows LIVE instead of its still's format.
    static func badges(versions: [VersionRecord], display: VersionRecord) -> [String] {
        if display.kind == .video { return display.duration.map { [formatDuration($0)] } ?? [] }
        let kinds = Set(versions.map(\.kind))
        var labels: [String] = []
        var stills = 0
        if kinds.contains(.raw) { labels.append("RAW") }
        if kinds.contains(.live) {
            labels.append("LIVE")
        } else {
            for kind in [VersionKind.jpeg, .heic, .image] {
                guard let v = versions.first(where: { $0.kind == kind }) else { continue }
                stills += 1
                switch kind {
                case .jpeg: labels.append("JPG")
                case .heic: labels.append("HEIC")
                default: labels.append((v.path as NSString).pathExtension.uppercased())
                }
            }
        }
        if kinds.contains(.edit) { labels.append("EDIT") }
        return labels.count == 1 && stills == 1 ? [] : labels
    }

    /// "0:12", "12:05", "1:02:03".
    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension LibraryIndex {
    /// Cell contents for `ids` in one query. Ids without a photo (or without versions) are left out.
    public func cellInfo(ids: [Int64], root: URL) throws -> [Int64: CellInfo] {
        guard !ids.isEmpty else { return [:] }
        let (photos, versions) = try dbPool.read { db in
            let list = Self.jsonList(ids)
            let photos = try GRDB.Row.fetchAll(db, sql: """
                SELECT id, rating, isFavorite, hasLightCraftEdits, rotation FROM photo
                WHERE id IN (SELECT value FROM json_each(?))
                """, arguments: [list])
            let versions = try VersionRecord.fetchAll(db, sql: """
                SELECT * FROM version WHERE photoId IN (SELECT value FROM json_each(?)) ORDER BY photoId, id
                """, arguments: [list])
            return (photos, versions)
        }
        let byPhoto = Dictionary(grouping: versions, by: \.photoId)
        var result: [Int64: CellInfo] = [:]
        result.reserveCapacity(photos.count)
        for row in photos {
            let id: Int64 = row["id"]
            guard let vs = byPhoto[id], let display = vs.first(where: \.isDisplay) ?? vs.first else { continue }
            result[id] = CellInfo(
                id: id,
                displayFile: MediaFile(url: display.url(in: root), size: display.size, modified: display.modified,
                                       created: display.modified),
                displayKind: display.kind, rating: row["rating"], isFavorite: row["isFavorite"],
                hasLightCraftEdits: row["hasLightCraftEdits"], rotation: row["rotation"], badges: CellInfo.badges(versions: vs, display: display))
        }
        return result
    }

    /// The photos (in `ids` order) and their versions, for running actions on a selection.
    public func actionSelection(ids: [Int64], root: URL) throws -> ActionSelection {
        guard !ids.isEmpty else { return ActionSelection(photos: [], versions: [:], root: root) }
        let (photos, versions) = try dbPool.read { db in
            let list = Self.jsonList(ids)
            let photos = try PhotoRecord.fetchAll(
                db, sql: "SELECT * FROM photo WHERE id IN (SELECT value FROM json_each(?))", arguments: [list])
            let versions = try VersionRecord.fetchAll(db, sql: """
                SELECT * FROM version WHERE photoId IN (SELECT value FROM json_each(?)) ORDER BY photoId, id
                """, arguments: [list])
            return (photos, versions)
        }
        let byID = Dictionary(photos.compactMap { p in p.id.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        var seen: Set<Int64> = []
        let ordered = ids.compactMap { id in seen.insert(id).inserted ? byID[id] : nil }
        return ActionSelection(photos: ordered, versions: Dictionary(grouping: versions, by: \.photoId), root: root)
    }

    /// One bound JSON array instead of one parameter per id (no SQLite variable limit, one statement).
    private static func jsonList(_ ids: [Int64]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }
}

/// What the toolbar's action buttons need to know about a photo: whether it is a favorite and what it shows.
public struct ActionFlags: Hashable, Sendable {
    public var isFavorite: Bool
    /// The display version's kind (the first version's without one); nil when the photo has no versions.
    public var displayKind: VersionKind?

    public init(isFavorite: Bool, displayKind: VersionKind?) {
        self.isFavorite = isFavorite
        self.displayKind = displayKind
    }
}

extension LibraryIndex {
    /// `ActionFlags` for `ids` in one query; unknown ids are left out.
    public func actionFlags(ids: [Int64]) throws -> [Int64: ActionFlags] {
        guard !ids.isEmpty else { return [:] }
        let rows = try dbPool.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT p.id, p.isFavorite,
                    (SELECT v.kind FROM version v WHERE v.photoId = p.id ORDER BY v.isDisplay DESC, v.id LIMIT 1) AS kind
                FROM photo p WHERE p.id IN (SELECT value FROM json_each(?))
                """, arguments: [Self.jsonList(ids)])
        }
        var result: [Int64: ActionFlags] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let kind: String? = row["kind"]
            result[row["id"]] = ActionFlags(isFavorite: row["isFavorite"], displayKind: kind.flatMap(VersionKind.init))
        }
        return result
    }
}
