import CoreServices
import CryptoKit
import Foundation
import GRDB
import LoupeCore
import LoupeMedia
import LoupeXMP

/// Ties index, scanner, sidecar writes, metadata stores and the folder watcher together.
/// Scans and metadata applies never interleave: all of them run through `serialized`.
public actor Library {
    public static let albumsDidChange = Notification.Name("LoupeLibraryAlbumsDidChange")
    public static let didLog = Notification.Name("LoupeLibraryDidLog")
    /// Posted after every scan, edit or file operation: folders, tags or albums may have changed.
    public static let didChange = Notification.Name("LoupeLibraryDidChange")

    public nonisolated let index: LibraryIndex
    public nonisolated let thumbnails: ThumbnailCache
    public nonisolated let location: any StorageLocation

    private let scanner: LoupeIndex.Scanner
    public nonisolated let settings: LibrarySettings
    private let registry: FeatureRegistry
    private var watcher: FolderWatcher?
    /// Set by `stop()`: watcher callbacks still queued afterwards are ignored.
    private var isStopped = false
    /// Held by the one import running on this library (`beginImport`/`endImport`).
    private var isImporting = false

    // Actor reentrancy: every await inside scan/apply work could let another call in, so they queue here.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        location: any StorageLocation, settings: LibrarySettings, registry: FeatureRegistry,
        supportDirectory: URL, cacheDirectory: URL
    ) throws {
        self.location = location
        self.registry = registry
        self.settings = settings
        let digest = SHA256.hash(data: Data(settings.rootPath.utf8)).map { String(format: "%02x", $0) }.joined()
        index = try LibraryIndex(
            databaseURL: supportDirectory.appendingPathComponent("index-\(digest.prefix(12)).sqlite"))
        thumbnails = ThumbnailCache(directory: cacheDirectory.appendingPathComponent("thumbs", isDirectory: true))
        scanner = LoupeIndex.Scanner(index: index, location: location, settings: settings)
    }

    // MARK: - Serial section

    private func serialized<T>(_ body: () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        let result = await body()
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        NotificationCenter.default.post(name: Library.didChange, object: nil)
        return result
    }

    private func log(_ message: String) {
        NotificationCenter.default.post(name: Library.didLog, object: nil, userInfo: ["message": message])
    }

    // MARK: - Start

    /// Scans, syncs the metadata stores, then starts watching the root.
    public func start() async -> ScanReport {
        guard watcher == nil else { return await initialSync() }
        // Events during the initial sync are replayed once; they queue behind it in the serial section.
        let since = FSEventsGetCurrentEventId()
        let w = FolderWatcher(root: location.rootURL, sinceWhen: since) { [weak self] folders, all in
            guard let self else { return }
            Task { await self.handleFolderChanges(folders, rescanAll: all) }
        }
        w.start()
        watcher = w
        return await initialSync()
    }

    /// The scan and store sync part of `start()`.
    func initialSync() async -> ScanReport {
        await serialized {
            var report = ScanReport()
            do { report = try await scanner.fullScan() } catch { logScanFailure(error) }
            logFailed(report)
            await guardAgainstStaleRevert(photoIDs: report.sidecarChangedPhotoIDs)
            for id in ((try? index.allPhotos()) ?? []).compactMap(\.id) {
                if Task.isCancelled { break }  // the app is replacing this library
                await syncStores(photoID: id, pushIfUnchanged: true)
            }
            return report
        }
    }

    public func stop() {
        isStopped = true
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Metadata edits

    public func apply(_ changes: [MetadataChange], to photoIDs: [Int64]) async -> [Int64: any Error] {
        await serialized { await applyLocked(changes, to: photoIDs) }
    }

    private func applyLocked(_ changes: [MetadataChange], to photoIDs: [Int64]) async -> [Int64: any Error] {
        var errors: [Int64: any Error] = [:]
        for id in photoIDs {
            do { try await applyOne(changes, to: id) } catch { errors[id] = error }
        }
        return errors
    }

    /// `track: false` is for the stale-revert guard's own corrections, which must not create new pending entries.
    private func applyOne(_ changes: [MetadataChange], to id: Int64, track: Bool = true) async throws {
        let root = location.rootURL
        let group = try index.groupFiles(ofPhoto: id, root: root)
        let fm = FileManager.default
        let mediaURLs = group.versions.map(\.file.url).filter { fm.fileExists(atPath: $0.path) }
        // A photo whose files are all gone must not get a fresh sidecar; the next scan removes it.
        guard !mediaURLs.isEmpty else { throw CocoaError(.fileNoSuchFile) }

        // A write by LightCraft or anyone else may not have reached the index yet (watcher latency); settle it first,
        // or this write would carry the stale values forward and re-stamp them as ours.
        if track { await guardIfSidecarChangedSinceStamp(photoID: id) }
        let sidecarNow = group.sidecarURLForWriting
        let before = try (try? XMPDocument(data: Data(contentsOf: sidecarNow)).metadata) ?? index.metadata(ofPhoto: id)
        let metadata = try SidecarIO.write(changes, to: group)  // throws for malformed sidecars, never writes them
        let sidecar = group.sidecarURLForWriting
        let stamp = (try? fm.attributesOfItem(atPath: sidecar.path))?[.modificationDate] as? Date
        try await index.dbPool.write { db in
            try db.execute(
                sql: "UPDATE photo SET rating = ?, isFavorite = ?, hasLightCraftEdits = ?, sidecarModified = ? WHERE id = ?",
                arguments: [metadata.rating, metadata.isFavorite, metadata.hasLightCraftEdits,
                            stamp?.timeIntervalSince1970, id])
            try db.execute(sql: "DELETE FROM photo_tag WHERE photoId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM photo_album WHERE photoId = ?", arguments: [id])
            for t in metadata.tags {
                try db.execute(sql: "INSERT OR IGNORE INTO photo_tag(photoId, name) VALUES (?, ?)", arguments: [id, t])
            }
            for a in metadata.albums {
                try db.execute(sql: "INSERT OR IGNORE INTO photo_album(photoId, name) VALUES (?, ?)", arguments: [id, a])
            }
            if track {
                let new = StaleRevertGuard.pending(for: changes, before: before)
                if !new.isEmpty {
                    let existing = try Self.pendingEntries(db, photoID: id)
                    let merged = StaleRevertGuard.merge(existing, with: new)
                    try db.execute(sql: "DELETE FROM pending_edit WHERE photoId = ?", arguments: [id])
                    for p in merged {
                        try db.execute(
                            sql: "INSERT INTO pending_edit(photoId, field, value, previous) VALUES (?, ?, ?, ?)",
                            arguments: [id, p.field, p.value, p.previous])
                    }
                }
            }
        }
        try await pushToStores(metadata, photoID: id, files: mediaURLs)
    }

    // MARK: - LightCraft stale-revert guard

    private static func pendingEntries(_ db: Database, photoID: Int64) throws -> [StaleRevertGuard.Pending] {
        try Row.fetchAll(
            db, sql: "SELECT field, value, previous FROM pending_edit WHERE photoId = ? ORDER BY field", arguments: [photoID]
        ).map { StaleRevertGuard.Pending(field: $0["field"], value: $0["value"], previous: $0["previous"]) }
    }

    /// For photos whose sidecar changed on disk behind Loupe's back. LightCraft (also when merging into a sidecar
    /// Loupe created) gets its stale reverts restored; for any other writer disk wins and entries that no longer
    /// match are dropped.
    private func guardAgainstStaleRevert(photoIDs: [Int64]) async {
        for id in photoIDs { await guardOne(photoID: id) }
    }

    private func guardIfSidecarChangedSinceStamp(photoID id: Int64) async {
        guard let photo = try? index.photo(id: id),
            let group = try? index.groupFiles(ofPhoto: id, root: location.rootURL), let sidecar = group.sidecar,
            let disk = (try? FileManager.default.attributesOfItem(atPath: sidecar.path))?[.modificationDate] as? Date,
            !LoupeIndex.Scanner.sameStamp(photo.sidecarModified, disk)
        else { return }
        await guardOne(photoID: id)
    }

    private func guardOne(photoID id: Int64) async {
        do {
            let pending = try await index.dbPool.read { try Self.pendingEntries($0, photoID: id) }
            guard !pending.isEmpty else { return }
            let group = try index.groupFiles(ofPhoto: id, root: location.rootURL)
            guard let sidecar = group.sidecar else { return }
            let doc = try XMPDocument(data: Data(contentsOf: sidecar))
            let resolved: [StaleRevertGuard.Pending]
            if StaleRevertGuard.isLightCraft(doc) {
                let result = StaleRevertGuard.evaluate(pending, current: doc.metadata)
                if !result.corrections.isEmpty {
                    try await applyOne(result.corrections, to: id, track: false)
                    for change in result.corrections { log("Restored \(Self.fieldName(change)) after LightCraft overwrote it") }
                }
                resolved = result.resolved
            } else {
                resolved = StaleRevertGuard.resolvedByOtherWriter(pending, current: doc.metadata)
            }
            if !resolved.isEmpty {
                try await index.dbPool.write { db in
                    for p in resolved {
                        try db.execute(sql: "DELETE FROM pending_edit WHERE photoId = ? AND field = ?", arguments: [id, p.field])
                    }
                }
            }
        } catch {
            log("Stale-revert check failed for photo \(id): \(error)")
        }
    }

    private static func fieldName(_ change: MetadataChange) -> String {
        switch change {
        case .setRating: "rating"
        case .setFavorite: "favorite"
        case .addTag(let t), .removeTag(let t): "tag \(t)"
        case .addToAlbum(let a), .removeFromAlbum(let a): "album \(a)"
        }
    }

    // MARK: - Metadata stores

    private func mirrorState(photoID: Int64, store: String) async throws -> Data? {
        try await index.dbPool.read { db in
            try Data.fetchOne(
                db, sql: "SELECT state FROM mirror_state WHERE photoId = ? AND storeId = ?", arguments: [photoID, store])
        }
    }

    /// Every store is tried; the first failure is rethrown afterwards.
    private func pushToStores(_ metadata: PhotoMetadata, photoID: Int64, files: [URL]) async throws {
        var firstError: (any Error)?
        for store in registry.metadataStores {
            do {
                let last = try await mirrorState(photoID: photoID, store: store.id)
                let state = try store.push(metadata, files: files, lastState: last)
                try await index.dbPool.write { db in
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO mirror_state(photoId, storeId, state) VALUES (?, ?, ?)",
                        arguments: [photoID, store.id, state])
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Pulls store-side changes into XMP; with `pushIfUnchanged`, otherwise mirrors the index to the stores.
    private func syncStores(photoID id: Int64, pushIfUnchanged: Bool) async {
        guard !registry.metadataStores.isEmpty else { return }
        do {
            let group = try index.groupFiles(ofPhoto: id, root: location.rootURL)
            let files = group.versions.map(\.file.url).filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { return }
            var pulled: [MetadataChange] = []
            for store in registry.metadataStores {
                let last = try await mirrorState(photoID: id, store: store.id)
                pulled += try store.pull(files: files, lastState: last)
            }
            if !pulled.isEmpty {
                if let error = await applyLocked(pulled, to: [id])[id] { throw error }
            } else if pushIfUnchanged {
                try await pushToStores(try index.metadata(ofPhoto: id), photoID: id, files: files)
            }
        } catch {
            log("Metadata sync failed for photo \(id): \(error)")
        }
    }

    // MARK: - File operations

    /// Moves whole photo groups into an existing folder (root-relative, `""` is the root). A photo is moved with
    /// all its files or not at all. The destination folder is never created here, and excluded, hidden or package
    /// folders are refused (the photos would vanish from the library). The moved photos get new ids on rescan.
    public func move(_ ids: [Int64], toFolder: String) async -> [Int64: any Error] {
        await serialized { await moveLocked(ids, toFolder: toFolder) }
    }

    private func moveLocked(_ ids: [Int64], toFolder: String) async -> [Int64: any Error] {
        var errors: [Int64: any Error] = [:]
        let root = location.rootURL
        let given = toFolder.split(separator: "/").map(String.init)
        guard !given.contains(where: { $0 == "." || $0 == ".." }),
            let (components, destURL) = try? LoupeIndex.Scanner.resolveOnDisk(given, under: root)
        else {
            let error = CocoaError(.fileNoSuchFile)
            return Dictionary(ids.map { ($0, error as any Error) }, uniquingKeysWith: { a, _ in a })
        }
        guard !scanner.isIgnored(components, under: root) else {
            let error = CocoaError(.fileWriteNoPermission)
            return Dictionary(ids.map { ($0, error as any Error) }, uniquingKeysWith: { a, _ in a })
        }
        let destKey = components.joined(separator: "/").precomposedStringWithCanonicalMapping
        var rescan: Set<String> = []
        var coverMoves: [(old: String, new: String)] = []
        for id in ids {
            do {
                let photo = try index.photo(id: id)
                let group = try index.groupFiles(ofPhoto: id, root: root)
                if FileOperations.sameDirectory(group.folder, destURL) { continue }  // nothing to do
                let moved = try FileOperations.moveGroup(group, to: destURL, editMarkers: settings.editMarkers)
                guard let photo else { continue }
                rescan.insert(photo.folderPath)
                rescan.insert(destKey)
                let newKey = destKey.isEmpty ? moved.stem : destKey + "/" + moved.stem
                coverMoves.append((photo.key, newKey))
            } catch { errors[id] = error }
        }
        await rescanFolders(rescan)
        updateAlbumCovers(coverMoves)
        return errors
    }

    /// Moves whole photo groups to the Trash; a photo is trashed with all its files or not at all.
    public func trash(_ ids: [Int64]) async -> [Int64: any Error] {
        await trashReturningItems(ids).errors
    }

    /// Same as `trash`, also returning where the files ended up (tests clean these up).
    func trashReturningItems(_ ids: [Int64]) async -> (errors: [Int64: any Error], trashed: [URL]) {
        await serialized {
            var errors: [Int64: any Error] = [:]
            var trashed: [URL] = []
            var rescan: Set<String> = []
            for id in ids {
                do {
                    let photo = try index.photo(id: id)
                    trashed += try FileOperations.trashGroup(try index.groupFiles(ofPhoto: id, root: location.rootURL))
                    if let photo { rescan.insert(photo.folderPath) }
                } catch { errors[id] = error }
            }
            await rescanFolders(rescan)
            return (errors, trashed)
        }
    }

    /// Delete Album: the album's own photos move to the root (Unsorted) with all their files, then the folder is
    /// removed if nothing is left in it but `.DS_Store`. Subfolders (or other files) keep the folder in place.
    /// Nothing is ever trashed, and the root, missing or ignored folders are left alone.
    public func deleteAlbum(_ path: String) async -> [Int64: any Error] {
        await serialized { await deleteAlbumLocked(path) }
    }

    private func deleteAlbumLocked(_ path: String) async -> [Int64: any Error] {
        let root = location.rootURL
        let given = path.split(separator: "/").map(String.init)
        guard !given.isEmpty, !given.contains(where: { $0 == "." || $0 == ".." }),
            let (components, folderURL) = try? LoupeIndex.Scanner.resolveOnDisk(given, under: root),
            !scanner.isIgnored(components, under: root)
        else { return [:] }
        let key = components.joined(separator: "/").precomposedStringWithCanonicalMapping
        await rescanFolders([key])  // photos added since the last watcher event go too
        let ids: [Int64]
        do {
            ids = try await photoIDs(inFolder: key)
        } catch {
            log("Could not delete the album \(key): \(error.localizedDescription)")
            return [:]
        }
        let errors = await moveLocked(ids, toFolder: "")
        removeFolderIfEmpty(folderURL, path: key)
        return errors
    }

    /// Photos directly in `folder` (an NFC folder key).
    private func photoIDs(inFolder folder: String) async throws -> [Int64] {
        let locationID = location.id
        return try await index.dbPool.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT id FROM photo WHERE locationId = ? AND folderPath = ? ORDER BY id",
                arguments: [locationID, folder])
        }
    }

    private func removeFolderIfEmpty(_ url: URL, path: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
        guard names.allSatisfy({ $0 == ".DS_Store" }) else {
            log("Kept the folder \(path): it still holds subfolders or other files")
            return
        }
        for name in names { try? fm.removeItem(at: url.appendingPathComponent(name)) }
        // rmdir only removes an empty folder, so a file that arrived meanwhile keeps it.
        if rmdir(url.path) != 0 { log("Could not remove the folder \(path): \(String(cString: strerror(errno)))") }
    }

    /// Creates `name` inside `inFolder` and returns its root-relative path. Refuses existing names (case-insensitive).
    public func createFolder(named name: String, inFolder: String) async throws -> String {
        let result: Result<String, any Error> = await serialized {
            do { return .success(try createFolderLocked(name, inFolder: inFolder)) } catch { return .failure(error) }
        }
        return try result.get()
    }

    private func createFolderLocked(_ name: String, inFolder: String) throws -> String {
        let root = location.rootURL
        try validateFolderName(name)
        let given = inFolder.split(separator: "/").map(String.init)
        guard !given.contains(where: { $0 == "." || $0 == ".." }),
            let (components, parent) = try LoupeIndex.Scanner.resolveOnDisk(given, under: root)
        else { throw CocoaError(.fileNoSuchFile) }
        guard !scanner.isIgnored(components + [name], under: root) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
        return (components + [name]).joined(separator: "/")
    }

    /// Renames a folder (same parent) and returns its new root-relative path. Never replaces a sibling.
    public func renameFolder(_ relative: String, to newName: String) async throws -> String {
        let result: Result<String, any Error> = await serialized {
            do { return .success(try await renameFolderLocked(relative, to: newName)) } catch { return .failure(error) }
        }
        return try result.get()
    }

    private func renameFolderLocked(_ relative: String, to newName: String) async throws -> String {
        let root = location.rootURL
        try validateFolderName(newName)
        let given = relative.split(separator: "/").map(String.init)
        guard !given.isEmpty, !given.contains(where: { $0 == "." || $0 == ".." }),
            let (components, url) = try LoupeIndex.Scanner.resolveOnDisk(given, under: root)
        else { throw CocoaError(.fileNoSuchFile) }
        let parentComponents = Array(components.dropLast())
        guard !scanner.isIgnored(parentComponents + [newName], under: root), !scanner.isIgnored(components, under: root)
        else { throw CocoaError(.fileWriteInvalidFileName) }
        let current = components[components.count - 1]
        let oldPath = components.joined(separator: "/")
        let newPath = (parentComponents + [newName]).joined(separator: "/")
        if current == newName { return oldPath }

        let parent = url.deletingLastPathComponent()
        let newURL = parent.appendingPathComponent(newName, isDirectory: true)
        let fm = FileManager.default
        let newKey = PhotoGrouper.stemKey(newName)
        if PhotoGrouper.stemKey(current) == newKey {
            // Case or Unicode spelling only: the same entry, so a plain rename is safe (and the only way on APFS).
            guard rename(url.path, newURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else {
            let siblings = try fm.contentsOfDirectory(atPath: parent.path)
            if siblings.contains(where: { PhotoGrouper.stemKey($0) == newKey }) {
                throw CocoaError(.fileWriteFileExists)
            }
            try fm.moveItem(at: url, to: newURL)  // fails if the destination exists
        }

        // Rescan is not recursive: a full scan drops the old paths and picks up the new ones.
        do {
            let report = try await scanner.fullScan()
            logFailed(report)
        } catch { logScanFailure(error) }
        let oldPrefix = oldPath.precomposedStringWithCanonicalMapping.lowercased()
        let newNFC = newPath.precomposedStringWithCanonicalMapping
        rewriteAlbumCovers { cover in
            let key = cover.precomposedStringWithCanonicalMapping
            guard key.lowercased().hasPrefix(oldPrefix + "/") else { return nil }
            return newNFC + key.dropFirst(oldPrefix.count)
        }
        return newPath
    }

    /// Runs `work` in the serial section, then rescans the root-relative folders it returns. For modules above
    /// the index that add files to the library (the importer), so a scan never sees half-done work.
    public func addingFiles<T: Sendable>(
        _ work: @Sendable () async throws -> (result: T, folders: Set<String>)
    ) async throws -> T {
        guard !isStopped else { throw CancellationError() }
        let outcome: Result<T, any Error> = await serialized {
            guard !isStopped else { return .failure(CancellationError()) }  // stopped while waiting
            do {
                let (result, folders) = try await work()
                await rescanFolders(folders)
                return .success(result)
            } catch { return .failure(error) }
        }
        return try outcome.get()
    }

    /// Claims the library's single import slot: imports stage files under fixed temp names, so two at once could
    /// clobber each other's copies. Returns false if an import is already running. Pair with `endImport()`.
    public func beginImport() -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        return true
    }

    public func endImport() { isImporting = false }

    private func validateFolderName(_ name: String) throws {
        let invalid = name.isEmpty || name == "." || name == ".." || name.hasPrefix(".")
            || name.contains("/") || name.contains(":") || name.contains("\0")
            || name != name.trimmingCharacters(in: .whitespacesAndNewlines)
        if invalid { throw CocoaError(.fileWriteInvalidFileName) }
    }

    private func rescanFolders(_ folders: Set<String>) async {
        for rel in folders.sorted() {
            do { logFailed(try await scanner.rescan(folder: rel)) } catch { logScanFailure(error) }
        }
    }

    private func updateAlbumCovers(_ moves: [(old: String, new: String)]) {
        guard !moves.isEmpty else { return }
        let table = Dictionary(
            moves.map { (PhotoGrouper.stemKey($0.old), $0.new) }, uniquingKeysWith: { _, last in last })
        rewriteAlbumCovers { table[PhotoGrouper.stemKey($0)] }
    }

    /// Rewrites album covers for which `transform` returns a new key. A corrupt catalog is left untouched.
    private func rewriteAlbumCovers(_ transform: (String) -> String?) {
        let root = location.rootURL
        do {
            var catalog = try AlbumCatalogIO.load(root: root)
            var changed = false
            for i in catalog.albums.indices {
                if let cover = catalog.albums[i].cover, let new = transform(cover), new != cover {
                    catalog.albums[i].cover = new
                    changed = true
                }
            }
            if changed { try AlbumCatalogIO.save(catalog, root: root) }
        } catch {
            log("Could not update album covers: \(error)")
        }
    }

    // MARK: - Watcher input

    public func handleFolderChanges(_ folders: Set<URL>, rescanAll: Bool) async {
        guard !isStopped else { return }
        await serialized {
            guard !isStopped else { return }  // stopped while waiting for the serial section
            let root = Self.realURL(location.rootURL)
            var relFolders = Set<String>()
            for url in folders {
                guard let rel = Self.relativeFolder(Self.realURL(url), root: root) else { continue }
                if rel == ".loupe" || rel.hasPrefix(".loupe/") {
                    NotificationCenter.default.post(name: Library.albumsDidChange, object: nil)
                } else {
                    relFolders.insert(rel)
                }
            }

            var scanned = Set<Int64>()
            var sidecarChanged = Set<Int64>()
            var unscannedInFolders = Set<Int64>()
            if rescanAll {
                do {
                    let report = try await scanner.fullScan()
                    logFailed(report)
                    scanned.formUnion(report.scannedPhotoIDs)
                    sidecarChanged.formUnion(report.sidecarChangedPhotoIDs)
                } catch { logScanFailure(error) }
            } else {
                for rel in relFolders.sorted() {
                    do {
                        let report = try await scanner.rescan(folder: rel)
                        logFailed(report)
                        scanned.formUnion(report.scannedPhotoIDs)
                        sidecarChanged.formUnion(report.sidecarChangedPhotoIDs)
                    } catch { logScanFailure(error) }
                    // Store-side edits (e.g. Finder tags) do not change the files the scanner compares.
                    let key = rel.precomposedStringWithCanonicalMapping
                    let ids = (try? await index.dbPool.read { db in
                        try Int64.fetchAll(db, sql: "SELECT id FROM photo WHERE locationId = ? AND folderPath = ?",
                                           arguments: [location.id, key])
                    }) ?? []
                    unscannedInFolders.formUnion(ids)
                }
            }
            await guardAgainstStaleRevert(photoIDs: sidecarChanged.sorted())
            for id in scanned.sorted() { await syncStores(photoID: id, pushIfUnchanged: true) }
            for id in unscannedInFolders.subtracting(scanned).sorted() {
                await syncStores(photoID: id, pushIfUnchanged: false)
            }
        }
    }

    // MARK: - Helpers

    private func logScanFailure(_ error: any Error) {
        if error is CancellationError { return }  // the app replaced this library
        log("Scan failed, index kept: \(error)")
    }

    private func logFailed(_ report: ScanReport) {
        for path in report.failed { log("Could not read \(path)") }
    }

    private static func realURL(_ url: URL) -> URL {
        func real(_ path: String) -> String? {
            guard let p = realpath(path, nil) else { return nil }
            defer { free(p) }
            return String(cString: p)
        }
        if let p = real(url.path) { return URL(fileURLWithPath: p, isDirectory: true) }
        // Deleted folder: resolve the closest existing ancestor.
        var tail: [String] = []
        var current = url
        while current.path != "/" {
            tail.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
            if let p = real(current.path) {
                return tail.reduce(URL(fileURLWithPath: p, isDirectory: true)) { $0.appendingPathComponent($1) }
            }
        }
        return url
    }

    private static func relativeFolder(_ url: URL, root: URL) -> String? {
        let r = root.pathComponents, c = url.pathComponents
        guard c.count >= r.count, Array(c.prefix(r.count)) == r else { return nil }
        return c.dropFirst(r.count).joined(separator: "/")
    }
}
