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
    /// Set once `start()`'s initial scan and store sync are done; `waitUntilStarted()` callers wait for it.
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

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
        let root = location.rootURL.path
        try index.dbPool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO library_meta(key, value) VALUES ('root', ?)", arguments: [root])
        }
    }

    // MARK: - Serial section

    private func serialized<T>(_ body: () async -> T) async -> T {
        await serializedReporting { (await body(), true) }
    }

    /// `body` also says whether anything changed; `didChange` is posted only then.
    private func serializedReporting<T>(_ body: () async -> (T, changed: Bool)) async -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        let (result, changed) = await body()
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        if changed { NotificationCenter.default.post(name: Library.didChange, object: self) }
        return result
    }

    private func log(_ message: String) {
        NotificationCenter.default.post(name: Library.didLog, object: nil, userInfo: ["message": message])
    }

    // MARK: - Start

    /// Scans, syncs the metadata stores, then starts watching the root.
    public func start() async -> ScanReport {
        let report = await startWatchingAndSync()
        await purgeRecentlyDeleted()
        hasStarted = true
        resumeStartWaiters()
        return report
    }

    /// Returns once `start()` has finished its initial scan and store sync (at once if it has), or the library
    /// was stopped. Until then the index may not list files that are on disk.
    public func waitUntilStarted() async {
        guard !hasStarted, !isStopped else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func resumeStartWaiters() {
        let waiting = startWaiters
        startWaiters = []
        for c in waiting { c.resume() }
    }

    private func startWatchingAndSync() async -> ScanReport {
        guard watcher == nil else { return await initialSync() }
        // Events during the initial sync are replayed once; they queue behind it in the serial section.
        let since = FSEventsGetCurrentEventId()
        let w = FolderWatcher(root: location.rootURL, sinceWhen: since) { [weak self] changes in
            guard let self else { return }
            Task { await self.handleFolderChanges(changes) }
        }
        if !w.start() {
            log("Could not watch \(location.rootURL.path) for changes; changes made outside Loupe show up after a restart")
        }
        watcher = w
        return await initialSync()
    }

    /// The scan and store sync part of `start()`.
    func initialSync() async -> ScanReport {
        await serialized {
            var report = ScanReport()
            do { report = try await scanner.fullScan() } catch { logScanFailure(error) }
            logFailed(report)
            scheduleDuplicateRefresh()
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
        duplicateRefresh?.cancel()
        watcher?.stop()
        watcher = nil
        resumeStartWaiters()
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
        let oldRotation = try index.photo(id: id)?.rotation
        let metadata = try SidecarIO.write(changes, to: group)  // throws for malformed sidecars, never writes them
        let sidecar = group.sidecarURLForWriting
        let stamp = (try? fm.attributesOfItem(atPath: sidecar.path))?[.modificationDate] as? Date
        // A sidecar value that only repeats the file's own orientation is no override.
        let rotation = SidecarIO.rotation(of: group, override: metadata.orientation)?.exif
        // Rotated: the shown width and height of every version may have swapped.
        var dimensions: [(version: Int64, info: MediaInfo)] = []
        if rotation != oldRotation {
            for v in try index.versions(ofPhoto: id) {
                guard let vid = v.id else { continue }
                dimensions.append((vid, await MediaInfoReader.read(v.url(in: root), kind: v.kind, rotation: rotation)))
            }
        }
        try await index.dbPool.write { [dimensions] db in
            try db.execute(
                sql: """
                    UPDATE photo SET rating = ?, isFavorite = ?, isHidden = ?, hasLightCraftEdits = ?, sidecarModified = ?,
                    orientationOverride = ?, rotation = ? WHERE id = ?
                    """,
                arguments: [metadata.rating, metadata.isFavorite, metadata.isHidden, metadata.hasLightCraftEdits,
                            stamp?.timeIntervalSince1970, rotation == nil ? nil : metadata.orientation, rotation, id])
            for (vid, info) in dimensions where info.pixelWidth != nil {
                try db.execute(sql: "UPDATE version SET pixelWidth = ?, pixelHeight = ? WHERE id = ?",
                               arguments: [info.pixelWidth, info.pixelHeight, vid])
            }
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
    /// Returns true if a value was restored.
    @discardableResult
    private func guardAgainstStaleRevert(photoIDs: [Int64]) async -> Bool {
        var restored = false
        for id in photoIDs where await guardOne(photoID: id) { restored = true }
        return restored
    }

    private func guardIfSidecarChangedSinceStamp(photoID id: Int64) async {
        guard let photo = try? index.photo(id: id),
            let group = try? index.groupFiles(ofPhoto: id, root: location.rootURL), let sidecar = group.sidecar,
            let disk = (try? FileManager.default.attributesOfItem(atPath: sidecar.path))?[.modificationDate] as? Date,
            !LoupeIndex.Scanner.sameStamp(photo.sidecarModified, disk)
        else { return }
        await guardOne(photoID: id)
    }

    @discardableResult
    private func guardOne(photoID id: Int64) async -> Bool {
        var restored = false
        do {
            let pending = try await index.dbPool.read { try Self.pendingEntries($0, photoID: id) }
            guard !pending.isEmpty else { return false }
            let group = try index.groupFiles(ofPhoto: id, root: location.rootURL)
            guard let sidecar = group.sidecar else { return false }
            let doc = try XMPDocument(data: Data(contentsOf: sidecar))
            let resolved: [StaleRevertGuard.Pending]
            if StaleRevertGuard.isLightCraft(doc) {
                let result = StaleRevertGuard.evaluate(pending, current: doc.metadata)
                if !result.corrections.isEmpty {
                    try await applyOne(result.corrections, to: id, track: false)
                    restored = true
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
        return restored
    }

    private static func fieldName(_ change: MetadataChange) -> String {
        switch change {
        case .setRating: "rating"
        case .setFavorite: "favorite"
        case .setHidden: "hidden"
        case .addTag(let t), .removeTag(let t): "tag \(t)"
        case .addToAlbum(let a), .removeFromAlbum(let a): "album \(a)"
        case .rotate: "orientation"
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
    /// Returns true if pulled changes were applied.
    @discardableResult
    private func syncStores(photoID id: Int64, pushIfUnchanged: Bool) async -> Bool {
        guard !registry.metadataStores.isEmpty else { return false }
        do {
            let group = try index.groupFiles(ofPhoto: id, root: location.rootURL)
            let files = group.versions.map(\.file.url).filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { return false }
            var pulled: [MetadataChange] = []
            for store in registry.metadataStores {
                let last = try await mirrorState(photoID: id, store: store.id)
                pulled += try store.pull(files: files, lastState: last)
            }
            if !pulled.isEmpty {
                if let error = await applyLocked(pulled, to: [id])[id] { throw error }
                return true
            } else if pushIfUnchanged {
                try await pushToStores(try index.metadata(ofPhoto: id), photoID: id, files: files)
            }
        } catch {
            log("Metadata sync failed for photo \(id): \(error)")
        }
        return false
    }

    // MARK: - File operations

    /// Moves whole photo groups into an existing folder (root-relative, `""` is the root). A photo is moved with
    /// all its files or not at all. The destination folder is never created here, and excluded, hidden or package
    /// folders are refused (the photos would vanish from the library). The moved photos get new ids on rescan.
    public func move(_ ids: [Int64], toFolder: String) async -> [Int64: any Error] {
        await serialized { await moveLocked(ids, toFolder: toFolder) }
    }

    private func moveLocked(_ ids: [Int64], toFolder: String) async -> [Int64: any Error] {
        await moveReportingLocked(ids, toFolder: toFolder).errors
    }

    /// As `moveLocked`, also saying where each moved photo came from and the stem it has now (a `(n)` suffix may
    /// have been added).
    private func moveReportingLocked(
        _ ids: [Int64], toFolder: String
    ) async -> (errors: [Int64: any Error], moved: [Int64: (from: String, stem: String)]) {
        var errors: [Int64: any Error] = [:]
        var report: [Int64: (from: String, stem: String)] = [:]
        let root = location.rootURL
        let given = toFolder.split(separator: "/").map(String.init)
        guard !given.contains(where: { $0 == "." || $0 == ".." }),
            let (components, destURL) = try? LoupeIndex.Scanner.resolveOnDisk(given, under: root)
        else {
            let error = CocoaError(.fileNoSuchFile)
            return (Dictionary(ids.map { ($0, error as any Error) }, uniquingKeysWith: { a, _ in a }), [:])
        }
        guard !scanner.isIgnored(components, under: root) else {
            let error = CocoaError(.fileWriteNoPermission)
            return (Dictionary(ids.map { ($0, error as any Error) }, uniquingKeysWith: { a, _ in a }), [:])
        }
        let destKey = components.joined(separator: "/").precomposedStringWithCanonicalMapping
        var rescan: Set<String> = []
        var coverMoves: [(old: String, new: String)] = []
        let carried = await carriedState(ofPhotos: ids)
        var carry: [(state: CarriedState, newKey: String)] = []
        for id in ids {
            do {
                let photo = try index.photo(id: id)
                let group = try index.groupFiles(ofPhoto: id, root: root)
                if FileOperations.sameDirectory(group.folder, destURL) { continue }  // nothing to do
                let moved = try FileOperations.moveGroup(group, to: destURL, editMarkers: settings.editMarkers)
                await carryHashes(zip(group.versions, moved.versions).map { ($0.file.url, $1.file.url) })
                guard let photo else { continue }
                report[id] = (photo.folderPath, moved.stem)
                rescan.insert(photo.folderPath)
                rescan.insert(destKey)
                let newKey = destKey.isEmpty ? moved.stem : destKey + "/" + moved.stem
                coverMoves.append((photo.key, newKey))
                if let state = carried[id] { carry.append((state, newKey)) }
            } catch { errors[id] = error }
        }
        await rescanFolders(rescan, carrying: carry)
        updateAlbumCovers(coverMoves)
        return (errors, report)
    }

    /// The hash cache (absolute paths) follows files and folders Loupe moves, so Imports keeps finding them.
    private func carryHashes(_ moves: [(from: URL, to: URL)]) async {
        guard !moves.isEmpty else { return }
        try? await index.dbPool.write { db in
            for move in moves {
                let old = move.from.path, new = move.to.path
                try db.execute(
                    sql: """
                        UPDATE OR REPLACE file_hash SET path = ? || substr(path, ?) \
                        WHERE path = ? OR path LIKE ? ESCAPE '\\'
                        """,
                    arguments: [new, old.unicodeScalars.count + 1, old, LibraryIndex.escapeLike(old) + "/%"])
            }
        }
    }

    /// Copies whole photo groups next to themselves as "<stem> copy" (see `FileOperations.duplicateGroup`); the copies
    /// keep the sidecar's rating, tags and flags and are indexed as new photos.
    public func duplicate(_ ids: [Int64]) async -> [Int64: any Error] {
        await serialized { await duplicateLocked(ids) }
    }

    private func duplicateLocked(_ ids: [Int64]) async -> [Int64: any Error] {
        var errors: [Int64: any Error] = [:]
        var rescan: Set<String> = []
        for id in ids {
            do {
                guard let photo = try index.photo(id: id) else { throw CocoaError(.fileNoSuchFile) }
                try FileOperations.duplicateGroup(
                    try index.groupFiles(ofPhoto: id, root: location.rootURL), editMarkers: settings.editMarkers)
                rescan.insert(photo.folderPath)
            } catch { errors[id] = error }
        }
        await rescanFolders(rescan)
        return errors
    }

    /// Moves whole photo groups to the Trash; a photo is trashed with all its files or not at all.
    public func trash(_ ids: [Int64]) async -> [Int64: any Error] {
        await trashReturningItems(ids).errors
    }

    /// Same as `trash`, also returning where the files ended up (tests clean these up).
    func trashReturningItems(_ ids: [Int64]) async -> (errors: [Int64: any Error], trashed: [URL]) {
        await serialized { await trashLocked(ids) }
    }

    private func trashLocked(_ ids: [Int64]) async -> (errors: [Int64: any Error], trashed: [URL]) {
        var errors: [Int64: any Error] = [:]
        var trashed: [URL] = []
        var rescan: Set<String> = []
        for id in ids {
            do {
                let photo = try index.photo(id: id)
                trashed += try FileOperations.trashGroup(
                    try index.groupFiles(ofPhoto: id, root: location.rootURL), trashItem: trashItem)
                if let photo { rescan.insert(photo.folderPath) }
            } catch { errors[id] = error }
        }
        await rescanFolders(rescan)
        return (errors, trashed)
    }

    // MARK: - Recently Deleted

    /// Deletes photos the way the app does: their files move into the Recently Deleted folder at the root, where
    /// they stay `LibrarySettings.recentlyDeletedDays` days (see `purgeRecentlyDeleted`) and can be recovered.
    /// Photos already in it are left alone.
    public func delete(_ ids: [Int64]) async -> [Int64: any Error] {
        await serialized { await deleteLocked(ids, now: Date()) }
    }

    func deleteLocked(_ ids: [Int64], now: Date) async -> [Int64: any Error] {
        let folder = LibrarySettings.recentlyDeletedFolderName
        let deletedURL = location.rootURL.appendingPathComponent(folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: deletedURL, withIntermediateDirectories: true)
        } catch {
            return Dictionary(ids.map { ($0, error as any Error) }, uniquingKeysWith: { a, _ in a })
        }
        let live = ids.filter { id in (try? index.photo(id: id)).flatMap { $0 }.map { !Self.isDeleted($0) } ?? true }
        let (errors, moved) = await moveReportingLocked(live, toFolder: folder)
        var catalog = DeletedCatalog.load(in: deletedURL)
        for (_, m) in moved { catalog.entries[PhotoGrouper.stemKey(m.stem)] = .init(folder: m.from, deletedAt: now) }
        catalog.save(in: deletedURL)
        return errors
    }

    /// Moves deleted photos back to the album they were deleted from (recreated if it is gone; Unsorted if it can't
    /// be), with all their files.
    public func recover(_ ids: [Int64]) async -> [Int64: any Error] {
        await serialized { await recoverLocked(ids) }
    }

    private func recoverLocked(_ ids: [Int64]) async -> [Int64: any Error] {
        let root = location.rootURL
        let deletedURL = root.appendingPathComponent(LibrarySettings.recentlyDeletedFolderName, isDirectory: true)
        var catalog = DeletedCatalog.load(in: deletedURL)
        var byFolder: [String: [Int64]] = [:]
        var keys: [Int64: String] = [:]
        for id in ids {
            guard let photo = try? index.photo(id: id), Self.isDeleted(photo) else { continue }
            let key = PhotoGrouper.stemKey(photo.stem)
            keys[id] = key
            var folder = catalog.entries[key]?.folder ?? ""
            let parts = folder.split(separator: "/").map(String.init)
            if !folder.isEmpty, (try? LoupeIndex.Scanner.resolveOnDisk(parts, under: root)) == nil {
                let url = parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
                if scanner.isIgnored(parts, under: root)
                    || (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) == nil
                {
                    folder = ""
                }
            }
            byFolder[folder, default: []].append(id)
        }
        var errors: [Int64: any Error] = [:]
        for (folder, group) in byFolder.sorted(by: { $0.key < $1.key }) {
            let result = await moveReportingLocked(group, toFolder: folder)
            errors.merge(result.errors) { a, _ in a }
            for id in result.moved.keys { if let key = keys[id] { catalog.entries[key] = nil } }
        }
        catalog.save(in: deletedURL)
        return errors
    }

    /// Delete Permanently: deleted photos go to the system Trash.
    public func deletePermanently(_ ids: [Int64]) async -> [Int64: any Error] {
        await serialized {
            let deletedURL = location.rootURL.appendingPathComponent(
                LibrarySettings.recentlyDeletedFolderName, isDirectory: true)
            var keys: [Int64: String] = [:]
            for id in ids { if let photo = try? index.photo(id: id) { keys[id] = PhotoGrouper.stemKey(photo.stem) } }
            let (errors, _) = await trashLocked(ids)
            var catalog = DeletedCatalog.load(in: deletedURL)
            for (id, key) in keys where errors[id] == nil { catalog.entries[key] = nil }
            catalog.save(in: deletedURL)
            return errors
        }
    }

    /// Photos deleted more than `LibrarySettings.recentlyDeletedDays` days before `now` go to the system Trash.
    /// Runs after the initial scan.
    func purgeRecentlyDeleted(now: Date = Date()) async {
        let deletedURL = location.rootURL.appendingPathComponent(LibrarySettings.recentlyDeletedFolderName, isDirectory: true)
        let catalog = DeletedCatalog.load(in: deletedURL)
        let limit = now.addingTimeInterval(-Double(LibrarySettings.recentlyDeletedDays) * 86400)
        let expired = Set(catalog.entries.filter { $0.value.deletedAt < limit }.keys)
        guard !expired.isEmpty else { return }
        let folder = LibrarySettings.recentlyDeletedFolderName.precomposedStringWithCanonicalMapping
        let ids = ((try? await photoIDs(inFolder: folder)) ?? []).filter { id in
            (try? index.photo(id: id)).flatMap { $0 }.map { expired.contains(PhotoGrouper.stemKey($0.stem)) } ?? false
        }
        let errors = await deletePermanently(ids)
        if !errors.isEmpty { log("Couldn't empty \(errors.count) photos from Recently Deleted") }
    }

    /// Whether the photo is in Recently Deleted.
    public static func isDeleted(_ photo: PhotoRecord) -> Bool {
        let folder = LibrarySettings.recentlyDeletedFolderName
        return photo.folderPath == folder || photo.folderPath.hasPrefix(folder + "/")
    }

    /// Where `trash` sends each file: the system Trash, a temp dir in tests.
    private var trashItem: FileOperations.TrashItem = FileOperations.moveToTrash

    func setTrashItem(_ trashItem: @escaping FileOperations.TrashItem) { self.trashItem = trashItem }

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
        let oldNFC = oldPath.precomposedStringWithCanonicalMapping
        let newNFC = newPath.precomposedStringWithCanonicalMapping
        let inside = await photoKeys(inFolderTree: oldNFC)
        let carried = await carriedState(ofPhotos: inside.map(\.id))
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
        await carryHashes([(url, newURL)])

        // Rescan is not recursive: a full scan drops the old paths and picks up the new ones.
        var scanned: [Int64] = []
        do {
            let report = try await scanner.fullScan()
            logFailed(report)
            scanned = report.scannedPhotoIDs
            scheduleDuplicateRefresh()
        } catch { logScanFailure(error) }
        let carry = inside.compactMap { photo in
            carried[photo.id].map { (state: $0, newKey: newNFC + photo.key.dropFirst(oldNFC.count)) }
        }
        await restoreState(carry)
        await syncPhotosWithoutMirrorState(scanned)
        let oldPrefix = oldNFC.lowercased()
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

    /// Rescans after Loupe's own file work. `carrying`: state of photos that moved (see `carriedState`).
    private func rescanFolders(
        _ folders: Set<String>, carrying carry: [(state: CarriedState, newKey: String)] = []
    ) async {
        var scanned: [Int64] = []
        var changed = false
        for rel in folders.sorted() {
            do {
                let report = try await scanner.rescan(folder: rel)
                logFailed(report)
                scanned += report.scannedPhotoIDs
                changed = changed || report.added + report.updated + report.removed > 0
            } catch { logScanFailure(error) }
        }
        if changed { scheduleDuplicateRefresh() }
        await restoreState(carry)
        await syncPhotosWithoutMirrorState(scanned)
    }

    // MARK: - State carried across Loupe's own moves

    /// What a photo loses when Loupe moves or renames its files: the scanner indexes it under a new id, and the
    /// old row's store mirror state and stale-revert entries go with the old row.
    private struct CarriedState: Sendable {
        var mirror: [(storeId: String, state: Data)] = []
        var pending: [StaleRevertGuard.Pending] = []
    }

    private func carriedState(ofPhotos ids: [Int64]) async -> [Int64: CarriedState] {
        do {
            return try await index.dbPool.read { db in
                var out: [Int64: CarriedState] = [:]
                for id in ids {
                    var c = CarriedState()
                    for row in try Row.fetchAll(
                        db, sql: "SELECT storeId, state FROM mirror_state WHERE photoId = ?", arguments: [id])
                    {
                        c.mirror.append((row["storeId"], row["state"]))
                    }
                    c.pending = try Self.pendingEntries(db, photoID: id)
                    if !c.mirror.isEmpty || !c.pending.isEmpty { out[id] = c }
                }
                return out
            }
        } catch {
            log("Could not read the sync state of moved photos: \(error)")
            return [:]
        }
    }

    /// Gives the photo now indexed at each `newKey` the state captured for it before the move.
    private func restoreState(_ carry: [(state: CarriedState, newKey: String)]) async {
        for (state, key) in carry {
            guard let id = (try? index.photo(key: key))?.flatMap(\.id) else { continue }
            do {
                try await index.dbPool.write { db in
                    for m in state.mirror {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO mirror_state(photoId, storeId, state) VALUES (?, ?, ?)",
                            arguments: [id, m.storeId, m.state])
                    }
                    for p in state.pending {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO pending_edit(photoId, field, value, previous) VALUES (?, ?, ?, ?)",
                            arguments: [id, p.field, p.value, p.previous])
                    }
                }
            } catch {
                log("Could not keep the sync state of \(key): \(error)")
            }
        }
    }

    /// Ids and keys of the photos in `folder` (an NFC folder key) and its subfolders.
    private func photoKeys(inFolderTree folder: String) async -> [(id: Int64, key: String)] {
        let locationID = location.id
        let escaped = folder.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let photos = (try? await index.dbPool.read { db in
            try PhotoRecord.fetchAll(
                db, sql: "SELECT * FROM photo WHERE locationId = ? AND (folderPath = ? OR folderPath LIKE ? ESCAPE '\\')",
                arguments: [locationID, folder, escaped + "/%"])
        }) ?? []
        // LIKE ignores ASCII case; keep exact matches only.
        return photos.filter { $0.folderPath == folder || $0.folderPath.hasPrefix(folder + "/") }
            .compactMap { p in p.id.map { ($0, p.key) } }
    }

    /// Photos Loupe's own work (re)indexed that no store has seen: synced like the watcher does, so a later
    /// Loupe edit is pushed against a known state instead of reading the files' tags back as user additions.
    /// Returns true if store-side changes were applied.
    @discardableResult
    private func syncPhotosWithoutMirrorState(_ ids: [Int64]) async -> Bool {
        guard !registry.metadataStores.isEmpty else { return false }
        var changed = false
        for id in ids.sorted() {
            let known = (try? await index.dbPool.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mirror_state WHERE photoId = ?)", arguments: [id])
            }) ?? nil
            if known == true { continue }
            if await syncStores(photoID: id, pushIfUnchanged: true) { changed = true }
        }
        return changed
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

    // MARK: - Duplicates

    /// Posted when the duplicate sets changed (not `didChange`: no file, folder or metadata changed).
    public static let duplicatesDidChange = Notification.Name("LoupeLibraryDuplicatesDidChange")
    /// Posted while the duplicate check hashes files; userInfo `done` and `total` (Int). Done when they are equal.
    public static let duplicatesProgress = Notification.Name("LoupeLibraryDuplicatesProgress")

    /// The latest duplicate refresh. A newer request cancels it and runs once it has wound down.
    private var duplicateRefresh: Task<Void, Never>?

    /// Refreshes `duplicate_member` in the background: after the initial scan and after scans that changed files.
    /// Hashing (only new or changed files; the rest come from the cache) runs outside the serial section, like an
    /// import's copying; only storing the result runs inside it. Cancelled by `stop()`.
    private func scheduleDuplicateRefresh() {
        guard !isStopped else { return }
        let previous = duplicateRefresh
        previous?.cancel()
        duplicateRefresh = Task { [weak self] in
            await previous?.value
            await self?.refreshDuplicates()
        }
    }

    private func refreshDuplicates() async {
        guard !isStopped, !Task.isCancelled else { return }
        let duplicates = DuplicateIndex(index: index, root: location.rootURL)
        let rows: [DuplicateIndex.Row]
        do {
            // Not isolated to this actor: the hashing runs on the global executor.
            rows = try await duplicates.compute { [weak self] done, total in
                guard done == total || done % 50 == 0 else { return }
                NotificationCenter.default.post(
                    name: Library.duplicatesProgress, object: self, userInfo: ["done": done, "total": total])
            }
        } catch {
            if !(error is CancellationError) { log("Could not check for duplicates: \(error.localizedDescription)") }
            return
        }
        // `didChange` stays for files, folders and metadata; this posts `duplicatesDidChange` instead.
        let changed: Bool = await serializedReporting {
            guard !isStopped, !Task.isCancelled else { return (false, false) }  // a newer refresh replaces this one
            do {
                return (try duplicates.store(rows), false)
            } catch {
                log("Could not save the duplicates: \(error.localizedDescription)")
                return (false, false)
            }
        }
        if changed { NotificationCenter.default.post(name: Library.duplicatesDidChange, object: self) }
    }

    /// Returns once no duplicate refresh is running (tests).
    func duplicateRefreshDone() async {
        while let task = duplicateRefresh {
            await task.value
            if duplicateRefresh == task { return }
        }
    }

    /// "Move Other Copies to Trash" in Duplicates. Each of `others` whose every media file has a byte-identical copy
    /// in `kept` goes to the Trash through `trash` (whole group, all-or-nothing). This is checked again here against
    /// the files as they are now (hashes cached while size and mtime are unchanged), so a duplicate list that is
    /// out of date can never trash a file without a copy. The rest get `DuplicateError.notRedundant`, and `kept` is
    /// never touched. Nothing is deleted permanently.
    public func trashRedundantCopies(keeping kept: Int64, others: [Int64]) async -> [Int64: any Error] {
        await serialized {
            var errors: [Int64: any Error] = [:]
            let keptHashes = currentHashes(ofPhoto: kept).map(Set.init)
            var redundant: [Int64] = []
            for id in Array(Set(others)).sorted() where id != kept {
                if let keptHashes, let hashes = currentHashes(ofPhoto: id), hashes.allSatisfy(keptHashes.contains) {
                    redundant.append(id)
                } else {
                    errors[id] = DuplicateError.notRedundant((try? index.photo(id: id))??.stem ?? "The photo")
                }
            }
            let trashed = await trashLocked(redundant)
            return errors.merging(trashed.errors) { a, _ in a }
        }
    }

    /// The SHA-256 of each of the photo's media files as they are on disk now; nil if the photo has none or any of
    /// them is missing or unreadable.
    private func currentHashes(ofPhoto id: Int64) -> [String]? {
        guard let versions = try? index.versions(ofPhoto: id), !versions.isEmpty else { return nil }
        var hashes: [String] = []
        for v in versions {
            let url = v.url(in: location.rootURL)
            guard FileHash.stamp(url)?.size == v.size,
                let sha = (try? index.cachedSHA256(of: url, hasher: { try FileHash.sha256(of: $0) })) ?? nil
            else { return nil }
            hashes.append(sha)
        }
        return hashes
    }

    // MARK: - Watcher input

    /// Watcher input no pass has taken yet: root-relative folders, and whether a full scan is due.
    private var pendingFolders = Set<String>()
    private var pendingRescanAll = false
    /// The pass that will take the pending input. At most one waits while another runs.
    private var queuedPass: Task<Void, Never>?
    /// Full scans run for watcher input (tests).
    private(set) var fullScans = 0

    /// `rescanAll`: a full scan whatever `folders` says (as for dropped events).
    public func handleFolderChanges(_ folders: Set<URL>, rescanAll: Bool) async {
        await handleFolderChanges(FolderWatcher.Changes(folders: folders, rescanAll: rescanAll))
    }

    /// Events inside folders the scanner never enters (hidden ones, packages such as a Photos library, excluded
    /// names such as LightCraft Library) are dropped first, as those libraries write all the time; `.loupe` only
    /// tells the sidebar that albums changed. The rest merges into the one pending pass, so a burst costs at most
    /// the pass running now plus one more. Returns once a pass has handled this input.
    public func handleFolderChanges(_ changes: FolderWatcher.Changes) async {
        guard !isStopped else { return }
        let root = Self.realURL(location.rootURL)
        var albumsChanged = false
        var folders = Set<String>()
        var directoryChanged = false
        for (url, isDirectoryChange) in changes.folders.map({ ($0, false) }) + changes.directories.map({ ($0, true) }) {
            guard let rel = Self.relativeFolder(Self.realURL(url), root: root) else { continue }
            if rel == ".loupe" || rel.hasPrefix(".loupe/") {
                albumsChanged = true
                continue
            }
            if scanner.isIgnored(rel.split(separator: "/").map(String.init), under: root) { continue }
            if isDirectoryChange { directoryChanged = true } else { folders.insert(rel) }
        }
        if albumsChanged { NotificationCenter.default.post(name: Library.albumsDidChange, object: nil) }
        let rescanAll = changes.rescanAll || directoryChanged
        guard rescanAll || !folders.isEmpty else { return }

        pendingFolders.formUnion(folders)
        pendingRescanAll = pendingRescanAll || rescanAll
        let pass: Task<Void, Never>
        if let queuedPass {
            pass = queuedPass
        } else {
            pass = Task { await self.runPendingPass() }
            queuedPass = pass
        }
        await pass.value
    }

    /// Scans what the watcher reported, then syncs the stores. Posts `didChange` only if something changed.
    private func runPendingPass() async {
        await serializedReporting {
            queuedPass = nil  // input from now on waits for the next pass
            let folders = pendingFolders, rescanAll = pendingRescanAll
            pendingFolders = []
            pendingRescanAll = false
            guard !isStopped else { return ((), false) }  // stopped while waiting for the serial section

            var reports: [ScanReport] = []
            if rescanAll {
                fullScans += 1
                do { reports.append(try await scanner.fullScan()) } catch { logScanFailure(error) }
            } else {
                for rel in folders.sorted() {
                    do { reports.append(try await scanner.rescan(folder: rel)) } catch { logScanFailure(error) }
                }
            }
            for report in reports { logFailed(report) }
            var changed = reports.contains { $0.added + $0.updated + $0.removed > 0 }
            if changed { scheduleDuplicateRefresh() }
            let scanned = Set(reports.flatMap(\.scannedPhotoIDs))
            let sidecarChanged = Set(reports.flatMap(\.sidecarChangedPhotoIDs))

            // Store-side edits (e.g. Finder tags) do not change the files the scanner compares.
            var unscannedInFolders = Set<Int64>()
            for rel in folders {
                let key = rel.precomposedStringWithCanonicalMapping
                let ids = (try? await index.dbPool.read { db in
                    try Int64.fetchAll(db, sql: "SELECT id FROM photo WHERE locationId = ? AND folderPath = ?",
                                       arguments: [location.id, key])
                }) ?? []
                unscannedInFolders.formUnion(ids)
            }
            if await guardAgainstStaleRevert(photoIDs: sidecarChanged.sorted()) { changed = true }
            for id in scanned.sorted() where await syncStores(photoID: id, pushIfUnchanged: true) { changed = true }
            for id in unscannedInFolders.subtracting(scanned).sorted()
            where await syncStores(photoID: id, pushIfUnchanged: false) {
                changed = true
            }
            return ((), changed)
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
