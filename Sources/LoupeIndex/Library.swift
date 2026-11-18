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

    public nonisolated let index: LibraryIndex
    public nonisolated let thumbnails: ThumbnailCache
    public nonisolated let location: any StorageLocation

    private let scanner: LoupeIndex.Scanner
    private let registry: FeatureRegistry
    private var watcher: FolderWatcher?

    // Actor reentrancy: every await inside scan/apply work could let another call in, so they queue here.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        location: any StorageLocation, settings: LibrarySettings, registry: FeatureRegistry,
        supportDirectory: URL, cacheDirectory: URL
    ) throws {
        self.location = location
        self.registry = registry
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
        return result
    }

    private func log(_ message: String) {
        NotificationCenter.default.post(name: Library.didLog, object: nil, userInfo: ["message": message])
    }

    // MARK: - Start

    /// Scans, syncs the metadata stores, then starts watching the root.
    public func start() async -> ScanReport {
        let report = await initialSync()
        guard watcher == nil else { return report }
        let w = FolderWatcher(root: location.rootURL) { [weak self] folders, all in
            guard let self else { return }
            Task { await self.handleFolderChanges(folders, rescanAll: all) }
        }
        w.start()
        watcher = w
        return report
    }

    /// The scan and store sync part of `start()`.
    func initialSync() async -> ScanReport {
        await serialized {
            var report = ScanReport()
            do { report = try await scanner.fullScan() } catch { logScanFailure(error) }
            logFailed(report)
            for id in ((try? index.allPhotos()) ?? []).compactMap(\.id) {
                await syncStores(photoID: id, pushIfUnchanged: true)
            }
            return report
        }
    }

    public func stop() {
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

    private func applyOne(_ changes: [MetadataChange], to id: Int64) async throws {
        let root = location.rootURL
        let group = try index.groupFiles(ofPhoto: id, root: root)
        let fm = FileManager.default
        let mediaURLs = group.versions.map(\.file.url).filter { fm.fileExists(atPath: $0.path) }
        // A photo whose files are all gone must not get a fresh sidecar; the next scan removes it.
        guard !mediaURLs.isEmpty else { throw CocoaError(.fileNoSuchFile) }

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
        }
        try await pushToStores(metadata, photoID: id, files: mediaURLs)
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

    // MARK: - Watcher input

    public func handleFolderChanges(_ folders: Set<URL>, rescanAll: Bool) async {
        await serialized {
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
            var unscannedInFolders = Set<Int64>()
            if rescanAll {
                do {
                    let report = try await scanner.fullScan()
                    logFailed(report)
                    scanned.formUnion(report.scannedPhotoIDs)
                } catch { logScanFailure(error) }
            } else {
                for rel in relFolders.sorted() {
                    do {
                        let report = try await scanner.rescan(folder: rel)
                        logFailed(report)
                        scanned.formUnion(report.scannedPhotoIDs)
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
            for id in scanned.sorted() { await syncStores(photoID: id, pushIfUnchanged: true) }
            for id in unscannedInFolders.subtracting(scanned).sorted() {
                await syncStores(photoID: id, pushIfUnchanged: false)
            }
        }
    }

    // MARK: - Helpers

    private func logScanFailure(_ error: any Error) {
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
