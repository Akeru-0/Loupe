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
