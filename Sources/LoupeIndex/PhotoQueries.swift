import Foundation
import GRDB
import LoupeCore

extension LibraryIndex {
    public func sections(
        for query: PhotoQuery, calendar: Calendar = .current, locale: Locale = .current, now: Date = .now
    ) throws -> [PhotoSection] {
        let rows = try dbPool.read { try Self.fetchRows(db: $0, query: query, now: now) }
        return Self.group(rows, by: query.grouping, calendar: calendar, locale: locale)
    }

    /// Emits the current sections, then again after every change to the underlying tables.
    public func observeSections(for query: PhotoQuery) -> AsyncThrowingStream<[PhotoSection], Error> {
        let pool = dbPool
        let calendar = Calendar.current
        let locale = Locale.current
        return AsyncThrowingStream { continuation in
            let observation = ValueObservation.tracking { db in
                try Self.fetchRows(db: db, query: query, now: .now)
            }.removeDuplicates()
            let task = Task {
                do {
                    for try await rows in observation.values(in: pool) {
                        continuation.yield(Self.group(rows, by: query.grouping, calendar: calendar, locale: locale))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func allTags() throws -> [String] { try distinct("SELECT DISTINCT name FROM photo_tag ORDER BY name") }
    public func albumNames() throws -> Set<String> {
        Set(try distinct("SELECT DISTINCT name FROM photo_album"))
    }
    public func folderPaths() throws -> [String] { try distinct("SELECT DISTINCT folderPath FROM photo ORDER BY folderPath") }
    /// Photos per folder path (NFC), counting only each folder's own photos.
    public func directMediaCounts() throws -> [String: Int] {
        try dbPool.read { db in
            var counts: [String: Int] = [:]
            for row in try GRDB.Row.fetchAll(db, sql: "SELECT folderPath, COUNT(*) AS n FROM photo GROUP BY folderPath") {
                counts[row["folderPath"]] = row["n"]
            }
            return counts
        }
    }

    /// The album tree: the real folders under `root` (empty ones too; hidden, package and excluded folders
    /// skipped, as the scanner skips them) with this index's photo counts. Reads the disk: call off the main thread.
    public func albumTree(root: URL, settings: LibrarySettings) throws -> [AlbumNode] {
        let counts = try directMediaCounts()
        var folders: [FolderInfo] = []
        func walk(_ folder: URL, path: [String]) -> Bool {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
            let subfolders = urls
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .filter { !LoupeIndex.Scanner.ignores(folder: $0, settings: settings) }
            for url in subfolders {
                let components = path + [url.lastPathComponent]
                let key = components.joined(separator: "/").precomposedStringWithCanonicalMapping
                let hasSubfolders = walk(url, path: components)
                folders.append(FolderInfo(path: key, directMediaCount: counts[key] ?? 0, hasSubfolders: hasSubfolders))
            }
            return !subfolders.isEmpty
        }
        _ = walk(root, path: [])
        return AlbumTree.build(folders)
    }

    public func cameras() throws -> [String] {
        try distinct("SELECT DISTINCT cameraModel FROM photo WHERE cameraModel IS NOT NULL ORDER BY cameraModel")
    }
    public func lenses() throws -> [String] {
        try distinct("SELECT DISTINCT lensModel FROM photo WHERE lensModel IS NOT NULL ORDER BY lensModel")
    }

    private func distinct(_ sql: String) throws -> [String] {
        try dbPool.read { try String.fetchAll($0, sql: sql) }
    }

    // MARK: SQL

    struct Row: Sendable, Equatable { var id: Int64; var captureDate: Date? }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// WHERE condition on `p` for a media type. Videos and panoramas read the display version (Live Photos have a
    /// video version but their display version is an image); version pixel sizes are orientation-corrected.
    static func mediaTypeSQL(_ type: MediaType) -> String {
        switch type {
        case .raw: return "p.hasRaw = 1"
        case .videos:
            return "EXISTS (SELECT 1 FROM version v WHERE v.photoId = p.id AND v.isDisplay = 1 AND v.kind = 'video')"
        case .panoramas:
            return """
                EXISTS (SELECT 1 FROM version v WHERE v.photoId = p.id AND v.isDisplay = 1 AND v.kind != 'video' \
                AND v.pixelWidth > 0 AND v.pixelHeight > 0 \
                AND (v.pixelWidth >= 2 * v.pixelHeight OR v.pixelHeight >= 2 * v.pixelWidth))
                """
        }
    }

    /// Whether any photo matches the media type (cheap: stops at the first).
    public func hasMedia(_ type: MediaType) throws -> Bool {
        try dbPool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM photo p WHERE \(Self.mediaTypeSQL(type)))") ?? false
        }
    }

    static func fetchRows(db: Database, query q: PhotoQuery, now: Date) throws -> [Row] {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        switch q.scope {
        case .all: break
        case .favorites: clauses.append("p.isFavorite = 1")
        case .recentlyAdded(let days):
            clauses.append("p.addedDate >= ?")
            args.append(now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)
        case .album(let name):
            clauses.append("EXISTS (SELECT 1 FROM photo_album a WHERE a.photoId = p.id AND a.name = ?)")
            args.append(name)
        case .tag(let name):
            clauses.append("EXISTS (SELECT 1 FROM photo_tag t WHERE t.photoId = p.id AND t.name = ?)")
            args.append(name)
        case .folder(let path):
            clauses.append("p.folderPath = ?")
            args.append(path.precomposedStringWithCanonicalMapping)
        case .unsorted:
            clauses.append("p.folderPath = ''")
        case .mediaType(let type):
            clauses.append(mediaTypeSQL(type))
        case .recentlyEdited(let days):
            clauses.append("p.lastEditedAt >= ?")
            args.append(now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)
        case .duplicates:
            clauses.append("EXISTS (SELECT 1 FROM duplicate_member d WHERE d.photoId = p.id)")
        case .folderTree(let path):
            let key = path.precomposedStringWithCanonicalMapping
            clauses.append("(p.folderPath = ? OR p.folderPath LIKE ? ESCAPE '\\')")
            args.append(contentsOf: [key, escapeLike(key) + "/%"])
        }

        let text = q.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let pattern = "%" + escapeLike(text.precomposedStringWithCanonicalMapping) + "%"
            clauses.append("""
                (p.stem LIKE ? ESCAPE '\\' OR p.folderPath LIKE ? ESCAPE '\\' \
                OR p.cameraModel LIKE ? ESCAPE '\\' OR p.lensModel LIKE ? ESCAPE '\\' \
                OR EXISTS (SELECT 1 FROM photo_tag t WHERE t.photoId = p.id AND t.name LIKE ? ESCAPE '\\') \
                OR EXISTS (SELECT 1 FROM photo_album a WHERE a.photoId = p.id AND a.name LIKE ? ESCAPE '\\'))
                """)
            args.append(contentsOf: Array(repeating: pattern, count: 6))
        }
        if q.minRating > 0 {
            clauses.append("p.rating >= ?")
            args.append(q.minRating)
        }
        switch q.kind {
        case .any: break
        case .hasRaw: clauses.append("p.hasRaw = 1")
        case .withoutRaw: clauses.append("p.hasRaw = 0")
        case .videos: clauses.append("p.hasVideo = 1")
        case .lightCraftEdited: clauses.append("p.hasLightCraftEdits = 1")
        }
        if let camera = q.camera { clauses.append("p.cameraModel = ?"); args.append(camera) }
        if let lens = q.lens { clauses.append("p.lensModel = ?"); args.append(lens) }

        let dir = q.ascending ? "ASC" : "DESC"
        let order: String
        switch q.sort {
        case .captureDate: order = "p.captureDate IS NULL, p.captureDate \(dir)"
        case .added: order = "p.addedDate \(dir)"
        case .name: order = "p.stem COLLATE NOCASE \(dir), p.folderPath \(dir)"
        case .rating: order = "p.rating \(dir)"
        case .edited: order = "p.lastEditedAt IS NULL, p.lastEditedAt \(dir)"
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = "SELECT p.id, p.captureDate FROM photo p \(whereSQL) ORDER BY \(order), p.id ASC"
        return try GRDB.Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
            let t: Double? = $0["captureDate"]
            return Row(id: $0["id"], captureDate: t.map(Date.init(timeIntervalSince1970:)))
        }
    }

    // MARK: Sections

    static func group(_ rows: [Row], by grouping: PhotoQuery.Grouping, calendar: Calendar, locale: Locale) -> [PhotoSection] {
        let ids = rows.map(\.id)
        if grouping == .none { return ids.isEmpty ? [] : [PhotoSection(id: "all", title: "", photoIDs: ids)] }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch grouping {
        case .day: formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        case .month: formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        default: formatter.setLocalizedDateFormatFromTemplate("yyyy")
        }

        var sections: [PhotoSection] = []
        var indexByID: [String: Int] = [:]
        var undated: [Int64] = []
        for row in rows {
            guard let date = row.captureDate else { undated.append(row.id); continue }
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
            let id: String
            switch grouping {
            case .day: id = String(format: "%04d-%02d-%02d", y, m, d)
            case .month: id = String(format: "%04d-%02d", y, m)
            default: id = String(format: "%04d", y)
            }
            if let i = indexByID[id] {
                sections[i].photoIDs.append(row.id)
            } else {
                indexByID[id] = sections.count
                sections.append(PhotoSection(id: id, title: formatter.string(from: date), photoIDs: [row.id]))
            }
        }
        if !undated.isEmpty { sections.append(PhotoSection(id: "undated", title: "Undated", photoIDs: undated)) }
        return sections
    }
}
