import Foundation
import GRDB
import ImageIO
import LoupeCore
import LoupeMedia
import LoupeXMP

public enum ScanError: Error, Equatable {
    /// The root is missing (e.g. unmounted) or cannot be read; the index is left untouched.
    case rootUnavailable(String)
}

public struct ScanReport: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    /// Root-relative paths of files that could not be read (e.g. a malformed sidecar).
    public var failed: [String] = []
    /// Ids of photos that were added or re-read during this scan (unchanged photos are not listed).
    public var scannedPhotoIDs: [Int64] = []

    public init(added: Int = 0, updated: Int = 0, removed: Int = 0, failed: [String] = [], scannedPhotoIDs: [Int64] = []) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.failed = failed
        self.scannedPhotoIDs = scannedPhotoIDs
    }
}

/// Walks a location, groups files per folder and keeps the index in step with disk.
/// Never writes to the scanned tree.
public final class Scanner: Sendable {
    private let index: LibraryIndex
    private let location: any StorageLocation
    private let settings: LibrarySettings

    public init(index: LibraryIndex, location: any StorageLocation, settings: LibrarySettings) {
        self.index = index
        self.location = location
        self.settings = settings
    }

    // MARK: - Public

    public func fullScan() async throws -> ScanReport {
        let root = try Self.canonicalRoot(location.rootURL)
        let (listings, unreadable) = Self.walk(root: root, excluded: excludedNames)
        var report = ScanReport()
        for rel in listings.keys.sorted() {
            try Task.checkCancellation()
            try await process(folder: rel, listing: listings[rel]!, root: root, report: &report)
        }
        let stale = try await index.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT folderPath FROM photo WHERE locationId = ?",
                                arguments: [location.id])
        }.filter { folder in
            listings[folder] == nil
                && !unreadable.contains { $0 == folder || (!$0.isEmpty && folder.hasPrefix($0 + "/")) }
        }
        for folder in stale { report.removed += try deletePhotos(inFolder: folder, recursive: false) }
        return report
    }

    /// Rescans one folder (not its subfolders). Folders that are excluded, hidden or inside a package are
    /// never indexed. Throws, leaving the index untouched, if the root or the folder cannot be read.
    public func rescan(folder relativePath: String) async throws -> ScanReport {
        let root = try Self.canonicalRoot(location.rootURL)
        let given = relativePath.split(separator: "/").map(String.init)
        var report = ScanReport()

        guard let (components, folderURL) = try Self.resolveOnDisk(given, under: root) else {
            report.removed += try deletePhotos(inFolder: Self.folderKey(given), recursive: true)
            return report
        }
        let key = Self.folderKey(components)
        if isIgnored(components, under: root) {
            report.removed += try deletePhotos(inFolder: key, recursive: true)
            return report
        }
        let listing = try Self.list(folder: folderURL)
        try await process(folder: key, listing: listing, root: root, report: &report)
        return report
    }

    /// Stored folder paths are NFC so SQL comparisons do not depend on how a caller spelled them.
    private static func folderKey(_ components: [String]) -> String {
        components.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    private func isIgnored(_ components: [String], under root: URL) -> Bool {
        var url = root
        for name in components {
            url.appendPathComponent(name)
            if name.hasPrefix(".") || excludedNames.contains(PhotoGrouper.stemKey(name))
                || Self.packageExtensions.contains(url.pathExtension.lowercased())
                || (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            { return true }
        }
        return false
    }

    /// The on-disk spelling of each component (matching NFC/NFD and case), or nil if the folder is missing.
    /// Throws if a parent exists but cannot be listed.
    private static func resolveOnDisk(_ given: [String], under root: URL) throws -> ([String], URL)? {
        var url = root
        var out: [String] = []
        let fm = FileManager.default
        for name in given {
            let names: [String]
            do { names = try fm.contentsOfDirectory(atPath: url.path) } catch {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue { return nil }
                throw error
            }
            let key = PhotoGrouper.stemKey(name)
            guard let actual = names.first(where: { $0 == name }) ?? names.first(where: { PhotoGrouper.stemKey($0) == key })
            else { return nil }
            out.append(actual)
            url.appendPathComponent(actual)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return (out, url)
    }

    // MARK: - Disk listing

    /// `URL.resolvingSymlinksInPath` rewrites /private/var to /var, which would not match what the
    /// enumerator reports; `realpath` is consistent with the file system.
    private static func canonicalRoot(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw ScanError.rootUnavailable(url.path) }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        do { _ = try FileManager.default.contentsOfDirectory(atPath: root.path) } catch {
            throw ScanError.rootUnavailable(url.path)
        }
        return root
    }

    private var excludedNames: Set<String> {
        Set(settings.excludedFolderNames.map(PhotoGrouper.stemKey))
    }

    private struct Listing {
        var folderURL: URL?
        var files: [MediaFile] = []
        var sidecars: [(url: URL, modified: Date)] = []
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ]
    private static let packageExtensions: Set<String> = ["photoslibrary", "aplibrary", "lrlibrary", "app", "bundle"]

    private static func add(_ url: URL, to listing: inout Listing) {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return }
        let modified = v.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        listing.folderURL = url.deletingLastPathComponent()
        if url.pathExtension.lowercased() == "xmp" {
            listing.sidecars.append((url, modified))
        } else {
            listing.files.append(MediaFile(
                url: url, size: Int64(v.fileSize ?? 0), modified: modified, created: v.creationDate ?? modified))
        }
    }

    private static func list(folder: URL) throws -> Listing {
        var listing = Listing()
        listing.folderURL = folder
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        for url in urls { add(url, to: &listing) }
        return listing
    }

    /// Synchronous because `FileManager.DirectoryEnumerator` cannot be iterated from async code.
    private final class ErrorBox: @unchecked Sendable { var folders: Set<String> = [] }

    /// Returns the folders that have files, plus folders the enumerator could not read (their stored
    /// photos must be kept, not treated as deleted).
    private static func walk(root: URL, excluded: Set<String>) -> ([String: Listing], Set<String>) {
        var out: [String: Listing] = [:]
        let errors = ErrorBox()
        let handler: (URL, Error) -> Bool = { url, _ in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true
            errors.folders.insert(folderKey(of: isDir ? url : url.deletingLastPathComponent(), root: root))
            return true
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: handler)
        else { return (out, [""]) }
        for case let url as URL in enumerator {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if excluded.contains(PhotoGrouper.stemKey(url.lastPathComponent))
                    || v.isPackage == true || packageExtensions.contains(url.pathExtension.lowercased())
                {
                    enumerator.skipDescendants()
                }
                continue
            }
            add(url, to: &out[folderKey(of: url.deletingLastPathComponent(), root: root), default: Listing()])
        }
        return (out, errors.folders)
    }

    private static func folderKey(of folder: URL, root: URL) -> String {
        relative(folder, root: root).precomposedStringWithCanonicalMapping
    }

    private static func relative(_ url: URL, root: URL) -> String {
        let r = root.pathComponents, c = url.pathComponents
        guard c.count >= r.count, Array(c.prefix(r.count)) == r else { return url.path }
        return c.dropFirst(r.count).joined(separator: "/")
    }

    // MARK: - Per folder

    private func deletePhotos(inFolder folder: String, recursive: Bool) throws -> Int {
        try index.dbPool.write { db in
            try db.execute(sql: "DELETE FROM photo WHERE locationId = ? AND folderPath = ?",
                           arguments: [location.id, folder])
            var n = db.changesCount
            if recursive && !folder.isEmpty {
                // Escape LIKE wildcards in the folder name.
                let escaped = folder.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                try db.execute(sql: "DELETE FROM photo WHERE locationId = ? AND folderPath LIKE ? ESCAPE '\\'",
                               arguments: [location.id, escaped + "/%"])
                n += db.changesCount
            }
            return n
        }
    }

    private func process(folder: String, listing: Listing, root: URL, report: inout ScanReport) async throws {
        let folderURL = listing.folderURL ?? root
        let groups = PhotoGrouper(editMarkers: settings.editMarkers)
            .group(listing.files, sidecars: listing.sidecars.map(\.url), in: folderURL)
        let sidecarDates = Dictionary(listing.sidecars.map { ($0.url.path, $0.modified) }, uniquingKeysWith: { a, _ in a })
        let locationId = location.id

        let existing: [String: (photo: PhotoRecord, versions: [VersionRecord])] = try await index.dbPool.read { db in
            var map: [String: (PhotoRecord, [VersionRecord])] = [:]
            for p in try PhotoRecord.fetchAll(
                db, sql: "SELECT * FROM photo WHERE locationId = ? AND folderPath = ?", arguments: [locationId, folder])
            {
                let vs = try VersionRecord.fetchAll(db, sql: "SELECT * FROM version WHERE photoId = ?", arguments: [p.id!])
                map[p.stemKey] = (p, vs)
            }
            return map
        }

        let present = Set(groups.map(\.stemKey))
        let gone = existing.filter { !present.contains($0.key) }.map { $0.value.photo.id! }
        if !gone.isEmpty {
            try await index.dbPool.write { db in
                for id in gone { try db.execute(sql: "DELETE FROM photo WHERE id = ?", arguments: [id]) }
            }
            report.removed += gone.count
        }

        for group in groups {
            try Task.checkCancellation()
            let sidecarModified = group.sidecar.flatMap { sidecarDates[$0.path] }
            let old = existing[group.stemKey]
            let legacy = Self.fingerprint(group.legacySidecars, dates: sidecarDates)
            if let old, Self.isUnchanged(old.photo, old.versions, group, sidecarModified, legacy, root: root) { continue }
            do {
                let id = try await save(group, sidecarModified: sidecarModified, existingId: old?.photo.id, legacy: legacy,
                                        folder: folder, root: root, report: &report)
                report.scannedPhotoIDs.append(id)
                if old == nil { report.added += 1 } else { report.updated += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failed.append(Self.relative(group.displayVersion.file.url, root: root))
            }
        }
    }

    private static func fingerprint(_ legacy: [URL], dates: [String: Date]) -> String? {
        guard !legacy.isEmpty else { return nil }
        return legacy.map { "\($0.lastPathComponent)@\(dates[$0.path]?.timeIntervalSince1970 ?? 0)" }
            .sorted().joined(separator: "|")
    }

    private static func close(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }

    private static func isUnchanged(
        _ photo: PhotoRecord, _ versions: [VersionRecord], _ group: PhotoGroup, _ sidecarModified: Date?, _ legacy: String?, root: URL
    ) -> Bool {
        guard photo.stem == group.stem, photo.legacySidecarFingerprint == legacy, versions.count == group.versions.count else { return false }
        switch (photo.sidecarModified, sidecarModified) {
        case (nil, nil): break
        case let (a?, b?): if !close(a, b) { return false }
        default: return false
        }
        let stored = Dictionary(versions.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for v in group.versions {
            guard let s = stored[relative(v.file.url, root: root)], s.size == v.file.size,
                close(s.modified, v.file.modified)
            else { return false }
        }
        return true
    }

    private func save(
        _ original: PhotoGroup, sidecarModified: Date?, existingId: Int64?, legacy: String?, folder: String, root: URL,
        report: inout ScanReport
    ) async throws -> Int64 {
        let group = Self.reclassifyLightCraftExports(original)
        let display = group.displayVersion

        var metadata = PhotoMetadata()
        do {
            metadata = try SidecarIO.read(group)
        } catch {
            // Malformed or unreadable sidecar: index without it, report it, never write it.
            report.failed.append(Self.relative(group.sidecar ?? group.sidecarURLForWriting, root: root))
        }

        var infos: [MediaInfo] = []
        for v in group.versions { infos.append(await MediaInfoReader.read(v.file.url, kind: v.kind)) }
        let displayIndex = group.versions.firstIndex(of: display) ?? 0
        let displayInfo = infos[displayIndex]
        let captureDate = displayInfo.captureDate ?? infos.compactMap(\.captureDate).first ?? display.file.created
        let camera = displayInfo.cameraModel ?? infos.compactMap(\.cameraModel).first
        let lens = displayInfo.lensModel ?? infos.compactMap(\.lensModel).first

        let photo = PhotoRecord(
            id: existingId, locationId: location.id, folderPath: folder, stem: group.stem, stemKey: group.stemKey,
            captureDate: captureDate, addedDate: display.file.created, rating: metadata.rating,
            isFavorite: metadata.isFavorite, hasLightCraftEdits: metadata.hasLightCraftEdits,
            cameraModel: camera, lensModel: lens,
            hasRaw: group.versions.contains { $0.kind == .raw },
            hasVideo: group.versions.contains { $0.kind == .video || $0.kind == .live },
            sidecarModified: sidecarModified, legacySidecarFingerprint: legacy)

        return try await index.dbPool.write { [photo, group, infos, metadata, display] db in
            var photo = photo
            if photo.id != nil { try photo.update(db) } else { try photo.insert(db) }
            let pid = photo.id!
            try db.execute(sql: "DELETE FROM version WHERE photoId = ?", arguments: [pid])
            for (i, v) in group.versions.enumerated() {
                let path = Self.relative(v.file.url, root: root)
                // A file that moved between groups may still be listed under another photo.
                try db.execute(sql: "DELETE FROM version WHERE path = ?", arguments: [path])
                var row = VersionRecord(
                    photoId: pid, path: path, kind: v.kind, size: v.file.size, modified: v.file.modified,
                    pixelWidth: infos[i].pixelWidth, pixelHeight: infos[i].pixelHeight, duration: infos[i].duration,
                    isDisplay: v == display)
                try row.insert(db)
            }
            try db.execute(sql: "DELETE FROM photo_tag WHERE photoId = ?", arguments: [pid])
            try db.execute(sql: "DELETE FROM photo_album WHERE photoId = ?", arguments: [pid])
            for t in metadata.tags {
                try db.execute(sql: "INSERT OR IGNORE INTO photo_tag(photoId, name) VALUES (?, ?)", arguments: [pid, t])
            }
            for a in metadata.albums {
                try db.execute(sql: "INSERT OR IGNORE INTO photo_album(photoId, name) VALUES (?, ?)", arguments: [pid, a])
            }
            return pid
        }
    }

    // MARK: - LightCraft exports

    /// LightCraft exports `{name}.jpg` next to `{name}.CR2`, so the export groups as the camera JPEG.
    /// Its embedded `xmp:CreatorTool` starts with "LightCraft"; such a version is an edit.
    private static func reclassifyLightCraftExports(_ group: PhotoGroup) -> PhotoGroup {
        guard group.versions.contains(where: { $0.kind == .raw }) else { return group }
        var g = group
        var changed = false
        for i in g.versions.indices where [.jpeg, .heic, .image].contains(g.versions[i].kind) {
            if creatorTool(of: g.versions[i].file.url)?.hasPrefix("LightCraft") == true {
                g.versions[i].kind = .edit
                changed = true
            }
        }
        guard changed else { return group }
        // Keep the display rule ("newest edit wins") valid: edits oldest to newest at the end.
        let rest = g.versions.filter { $0.kind != .edit }
        let edits = g.versions.filter { $0.kind == .edit }
            .sorted { ($0.file.modified, $0.file.url.lastPathComponent) < ($1.file.modified, $1.file.url.lastPathComponent) }
        g.versions = rest + edits
        return g
    }

    private static func creatorTool(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        else { return nil }
        return CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:CreatorTool" as CFString) as String?
    }
}
