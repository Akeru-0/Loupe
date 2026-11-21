import Darwin
import Foundation
import GRDB
import LoupeCore

/// The Favorites folder at the top of the library (`LibrarySettings.favoritesFolderName`): a copy of every favorite
/// photo, all its files (RAW, JPEG, edited versions, sidecar), side by side, so an editor can open them all at once.
/// The copies are APFS clones: they take no space until one side changes.
///
/// It is kept in step both ways. A favorite added gets its copy, one taken away (or hidden, or deleted) loses it. A
/// file changed in the library is copied over its copy; a copy changed in the folder (an editor wrote its sidecar, or
/// saved over the file) is copied back over the original, and a new file next to a copy (`<name>-edited.jpg`) is
/// copied next to the original, so edits made there are never lost when the photo stops being a favorite. When both
/// changed, the newer wins. Loupe only ever removes files it put there.
///
/// The scanner never indexes the folder, so its copies aren't photos twice. What was copied is recorded in
/// `<root>/.loupe/favorites-folder.json`.
public struct FavoritesFolder: Sendable {
    public struct Report: Equatable, Sendable {
        /// Files copied into the folder, and copied back from it to the library.
        public var copied = 0
        public var copiedBack = 0
        public var removed = 0
        /// "IMG_1.jpg: why", for files that couldn't be copied.
        public var failures: [String] = []

        public init() {}
    }

    let index: LibraryIndex
    let root: URL

    public init(index: LibraryIndex, root: URL) {
        self.index = index
        self.root = root
    }

    public var folder: URL { root.appendingPathComponent(LibrarySettings.favoritesFolderName, isDirectory: true) }

    // MARK: - Record

    struct Stamp: Codable, Equatable {
        var size: Int64
        var modified: Double
    }

    struct FilePair: Codable, Equatable {
        /// Root-relative path of the library's file.
        var original: String
        /// The copy's name in the folder.
        var copy: String
        var originalStamp: Stamp?
        var copyStamp: Stamp?
    }

    struct Entry: Codable, Equatable {
        /// The photo's key in the library, `<folder>/<stem>` (`<stem>` at the top).
        var photo: String
        /// The copies' stem: the photo's, or `<stem> (2)` when another favorite has that name.
        var stem: String
        var files: [FilePair]
    }

    struct Record: Codable {
        var version = 1
        var entries: [Entry] = []
    }

    static func recordURL(root: URL) -> URL {
        root.appendingPathComponent(".loupe", isDirectory: true).appendingPathComponent("favorites-folder.json")
    }

    // MARK: - Sync

    /// One pass: changes in the folder go back to the library, then the folder follows the library's favorites.
    /// Blocking file work: call off the main thread.
    public func sync() throws -> Report {
        var report = Report()
        var record = loadRecord()
        let fm = FileManager.default

        // 1. What changed on either side since the last pass.
        let copies = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        for i in record.entries.indices {
            for j in record.entries[i].files.indices {
                syncPair(&record.entries[i].files[j], report: &report)
            }
            adoptNewFiles(of: &record.entries[i], among: copies, record: record, report: &report)
        }

        // 2. The favorites now, and their files.
        let wanted = try favorites()
        let wantedKeys = Set(wanted.map(\.key))

        // 3. Copies of photos that are no longer favorites go (their changes went back in step 1).
        for entry in record.entries where !wantedKeys.contains(entry.photo) {
            for pair in entry.files { removeCopy(pair, report: &report) }
        }
        record.entries.removeAll { !wantedKeys.contains($0.photo) }

        // 4. New favorites get their copies; files a favorite gained or lost follow.
        if !wanted.isEmpty { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let remaining = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        for photo in wanted {
            if let i = record.entries.firstIndex(where: { $0.photo == photo.key }) {
                var entry = record.entries[i]
                for pair in entry.files where !photo.files.contains(pair.original) && !exists(original: pair.original) {
                    removeCopy(pair, report: &report)
                }
                entry.files.removeAll { !photo.files.contains($0.original) && !exists(original: $0.original) }
                for file in photo.files where !entry.files.contains(where: { $0.original == file }) {
                    addPair(file, stem: photo.stem, to: &entry, report: &report)
                }
                record.entries[i] = entry
            } else {
                var entry = Entry(photo: photo.key, stem: uniqueStem(photo.stem, record: record, copies: remaining), files: [])
                for file in photo.files { addPair(file, stem: photo.stem, to: &entry, report: &report) }
                record.entries.append(entry)
            }
        }
        try saveRecord(record)
        return report
    }

    /// Copies whichever side changed over the other; when both did, the newer.
    private func syncPair(_ pair: inout FilePair, report: inout Report) {
        let originalURL = url(original: pair.original), copyURL = folder.appendingPathComponent(pair.copy)
        let original = stamp(originalURL), copy = stamp(copyURL)
        let copyChanged = copy != nil && copy != pair.copyStamp
        let originalChanged = original != nil && original != pair.originalStamp
        if copyChanged, original == nil || !originalChanged || copy!.modified > original!.modified {
            // Back into the library; not when the original went (the photo was moved or deleted: the copy is left).
            guard original != nil || pair.originalStamp == nil,
                FileManager.default.fileExists(atPath: originalURL.deletingLastPathComponent().path)
            else { return }
            do {
                try Self.clone(copyURL, to: originalURL)
                report.copiedBack += 1
            } catch {
                return report.failures.append("\(pair.original): \(error.localizedDescription)")
            }
        } else if originalChanged || (original != nil && copy == nil) {
            do {
                try Self.clone(originalURL, to: copyURL)
                report.copied += 1
            } catch {
                return report.failures.append("\(pair.copy): \(error.localizedDescription)")
            }
        }
        pair.originalStamp = stamp(originalURL)
        pair.copyStamp = stamp(copyURL)
    }

    /// Files an editor added next to the photo's copies (`<stem>-edited.jpg`, a first sidecar) are copied next to
    /// the original, named after it, and kept in step from then on. Never over a file that is there.
    private func adoptNewFiles(of entry: inout Entry, among copies: Set<String>, record: Record, report: inout Report) {
        let known = Set(record.entries.flatMap { $0.files.map(\.copy) })
        let otherStems = record.entries.map(\.stem).filter { $0 != entry.stem }
        let parts = entry.photo.split(separator: "/").map(String.init)
        let originalStem = parts.last ?? entry.photo
        let folderPath = parts.dropLast().joined(separator: "/")
        for name in copies.sorted() where !known.contains(name) && !name.hasPrefix(".") {
            // The longest stem it starts with is its photo's ("IMG_1 (2)-edited.jpg" is IMG_1 (2)'s, not IMG_1's).
            guard Self.belongs(name, to: entry.stem),
                !otherStems.contains(where: { $0.count > entry.stem.count && Self.belongs(name, to: $0) })
            else { continue }
            let rest = String(name.dropFirst(entry.stem.count))
            let original = (folderPath.isEmpty ? "" : folderPath + "/") + originalStem + rest
            guard !exists(original: original) else { continue }
            var pair = FilePair(original: original, copy: name)
            syncPair(&pair, report: &report)
            if pair.originalStamp != nil { entry.files.append(pair) }
        }
    }

    private func addPair(_ original: String, stem: String, to entry: inout Entry, report: inout Report) {
        let name = String(original.split(separator: "/").last ?? "")
        let copy = name.lowercased().hasPrefix(stem.lowercased())
            ? entry.stem + name.dropFirst(stem.count) : entry.stem + " " + name
        if entry.files.contains(where: { $0.copy.lowercased() == copy.lowercased() }) { return }
        var pair = FilePair(original: original, copy: copy)
        // An old file of that name (left by an earlier library state) is replaced by this photo's.
        syncPair(&pair, report: &report)
        if pair.copyStamp != nil { entry.files.append(pair) }
    }

    /// Removes a copy Loupe made; one changed since (its change couldn't go back) is left for the user.
    private func removeCopy(_ pair: FilePair, report: inout Report) {
        let url = folder.appendingPathComponent(pair.copy)
        guard let now = stamp(url), now == pair.copyStamp else { return }
        do {
            try FileManager.default.removeItem(at: url)
            report.removed += 1
        } catch {
            report.failures.append("\(pair.copy): \(error.localizedDescription)")
        }
    }

    private func uniqueStem(_ stem: String, record: Record, copies: Set<String>) -> String {
        let used = Set(record.entries.map { $0.stem.lowercased() })
        func free(_ candidate: String) -> Bool {
            !used.contains(candidate.lowercased()) && !copies.contains { Self.belongs($0, to: candidate) }
        }
        if free(stem) { return stem }
        var n = 2
        while !free("\(stem) (\(n))") { n += 1 }
        return "\(stem) (\(n))"
    }

    /// Whether a file name is one of `stem`'s: the stem, then an extension or a version suffix.
    static func belongs(_ name: String, to stem: String) -> Bool {
        guard name.count > stem.count, name.lowercased().hasPrefix(stem.lowercased()) else { return false }
        // "IMG_1.jpg", "IMG_1-edited.jpg", "IMG_1_edited.jpg", "IMG_1 (edited).jpg"; not "IMG_10.jpg" or "IMG_1 (2).jpg".
        let rest = name.dropFirst(stem.count)
        if rest.hasPrefix(".") || rest.hasPrefix("-") || rest.hasPrefix("_") || rest.hasPrefix(" (edited") { return true }
        return rest.hasPrefix(" ") && !rest.hasPrefix(" (")
    }

    // MARK: - Library side

    struct Favorite {
        var key: String
        var stem: String
        /// Root-relative paths: every version, and the sidecar when there is one.
        var files: [String]
    }

    /// Favorites that aren't hidden or in Recently Deleted, with their files.
    func favorites() throws -> [Favorite] {
        let deleted = LibrarySettings.recentlyDeletedFolderName
        let rows = try index.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.id, p.folderPath, p.stem, v.path FROM photo p JOIN version v ON v.photoId = p.id
                    WHERE p.isFavorite = 1 AND p.isHidden = 0
                    AND NOT (p.folderPath = ? OR p.folderPath LIKE ? ESCAPE '\\')
                    ORDER BY p.captureDate, p.id, v.id
                    """,
                arguments: [deleted, LibraryIndex.escapeLike(deleted) + "/%"])
        }
        var order: [Int64] = []
        var byID: [Int64: Favorite] = [:]
        for row in rows {
            let id: Int64 = row["id"]
            let folder: String = row["folderPath"], stem: String = row["stem"]
            if byID[id] == nil {
                order.append(id)
                let key = folder.isEmpty ? stem : folder + "/" + stem
                byID[id] = Favorite(key: key, stem: stem, files: [])
            }
            byID[id]!.files.append(row["path"])
        }
        return order.compactMap { id in
            guard var photo = byID[id] else { return nil }
            let sidecar = photo.key + ".xmp"
            if exists(original: sidecar) { photo.files.append(sidecar) }
            return photo
        }
    }

    // MARK: - Files

    private func url(original path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private func exists(original path: String) -> Bool { FileManager.default.fileExists(atPath: url(original: path).path) }

    private func stamp(_ url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? Int64, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Stamp(size: size, modified: modified.timeIntervalSince1970)
    }

    /// Copies `source` over `destination` as an APFS clone where it can (a plain copy elsewhere), with its dates,
    /// through a temporary file so the destination is never half written.
    static func clone(_ source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".loupe-copy-\(UUID().uuidString)-\(destination.lastPathComponent)")
        let flags = copyfile_flags_t(COPYFILE_ALL) | copyfile_flags_t(COPYFILE_CLONE)
        guard copyfile(source.path, temporary.path, nil, flags) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }

    private func loadRecord() -> Record {
        guard let data = try? Data(contentsOf: Self.recordURL(root: root)),
            let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return Record() }
        return record
    }

    private func saveRecord(_ record: Record) throws {
        let url = Self.recordURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }
}
