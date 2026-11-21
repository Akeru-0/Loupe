import Foundation
import GRDB
import LoupeCore

/// `<root>/.loupe/smart-albums.json`: the library's smart albums, in the order they were made.
public enum SmartAlbumStore {
    struct File: Codable {
        var version = 1
        var albums: [SmartAlbum]
    }

    public static func url(root: URL) -> URL {
        root.appendingPathComponent(".loupe", isDirectory: true).appendingPathComponent("smart-albums.json")
    }

    /// None when there's no file yet. Unreadable JSON throws, and is never overwritten here.
    public static func load(root: URL) throws -> [SmartAlbum] {
        guard let data = try? Data(contentsOf: url(root: root)) else { return [] }
        return try JSONDecoder().decode(File.self, from: data).albums
    }

    public static func save(_ albums: [SmartAlbum], root: URL) throws {
        let target = url(root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(albums: albums)).write(to: target, options: .atomic)
    }

    /// Adds the album, or replaces the one with its id.
    public static func upsert(_ album: SmartAlbum, root: URL) throws {
        var albums = try load(root: root)
        if let i = albums.firstIndex(where: { $0.id == album.id }) { albums[i] = album } else { albums.append(album) }
        try save(albums, root: root)
    }

    public static func delete(id: String, root: URL) throws {
        try save(try load(root: root).filter { $0.id != id }, root: root)
    }
}

extension LibraryIndex {
    /// WHERE condition on `p` for a smart album; matches nothing while it has no complete rule.
    static func smartAlbumSQL(
        _ album: SmartAlbum, now: Date, calendar: Calendar = .current
    ) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var parts: [String] = []
        var args: [any DatabaseValueConvertible] = []
        for rule in album.rules where rule.isComplete {
            let (sql, ruleArgs) = ruleSQL(rule, now: now, calendar: calendar)
            parts.append("(\(sql))")
            args += ruleArgs
        }
        guard !parts.isEmpty else { return ("0", []) }
        return ("(" + parts.joined(separator: album.matchAll ? " AND " : " OR ") + ")", args)
    }

    private static func ruleSQL(
        _ rule: SmartRule, now: Date, calendar: Calendar
    ) -> (String, [any DatabaseValueConvertible]) {
        let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let negate = rule.op == .isNot || rule.op == .doesNotContain
        func not(_ sql: String) -> String { negate ? "NOT (\(sql))" : sql }
        let like = "%" + escapeLike(value) + "%"
        switch rule.field {
        case .album:
            return (not("""
                p.folderPath = ? OR p.folderPath LIKE ? ESCAPE '\\' \
                OR EXISTS (SELECT 1 FROM photo_album a WHERE a.photoId = p.id AND a.name = ?)
                """), [value, escapeLike(value) + "/%", value])
        case .keyword:
            return (not("EXISTS (SELECT 1 FROM photo_tag t WHERE t.photoId = p.id AND t.name = ?)"), [value])
        case .person:
            return (not("""
                EXISTS (SELECT 1 FROM face f JOIN face_group g ON g.id = f.groupId WHERE f.photoId = p.id AND g.name = ?)
                """), [value])
        case .photo:
            let sql = switch SmartRule.Kind(rawValue: value) ?? .favorite {
            case .favorite: "p.isFavorite = 1"
            case .edited: "p.lastEditedAt IS NOT NULL"
            case .raw: mediaTypeSQL(.raw)
            case .video: mediaTypeSQL(.videos)
            case .panorama: mediaTypeSQL(.panoramas)
            }
            return (not(sql), [])
        case .rating:
            let op = switch rule.op { case .isAtLeast: ">="; case .isAtMost: "<="; default: "=" }
            return ("p.rating \(op) ?", [Int(value) ?? 0])
        case .date:
            switch rule.op {
            case .isInTheLast:
                return ("p.captureDate >= ?", [now.addingTimeInterval(-Double(Int(value) ?? 0) * 86400).timeIntervalSince1970])
            case .isBefore:
                return ("p.captureDate < ?", [(SmartRule.day(value, calendar: calendar) ?? now).timeIntervalSince1970])
            default:  // after the day: from the next one on
                let day = SmartRule.day(value, calendar: calendar) ?? now
                let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                return ("p.captureDate >= ?", [next.timeIntervalSince1970])
            }
        case .camera, .lens, .filename:
            let column = switch rule.field { case .camera: "p.cameraModel"; case .lens: "p.lensModel"; default: "p.stem" }
            if rule.op == .contains || rule.op == .doesNotContain {
                return (not("IFNULL(\(column), '') LIKE ? ESCAPE '\\'"), [like])
            }
            return (not("IFNULL(\(column), '') = ? COLLATE NOCASE"), [value])
        }
    }

    /// The names a person rule can take: the people and pets named in People.
    public func personNames() throws -> [String] {
        try dbPool.read {
            try String.fetchAll($0, sql: "SELECT DISTINCT name FROM face_group WHERE name IS NOT NULL AND name NOT LIKE '#%'")
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// What an album rule can be: every folder holding photos (by path) and the albums named in sidecars.
    public func albumRuleChoices() throws -> [String] {
        let deleted = LibrarySettings.recentlyDeletedFolderName
        let folders = try folderPaths().filter { !$0.isEmpty && $0 != deleted && !$0.hasPrefix(deleted + "/") }
        // The folders above them too ("Trips" for "Trips/Iceland").
        var all = Set<String>()
        for path in folders {
            let parts = path.split(separator: "/")
            for n in 1...parts.count { all.insert(parts.prefix(n).joined(separator: "/")) }
        }
        return all.union(try albumNames()).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
