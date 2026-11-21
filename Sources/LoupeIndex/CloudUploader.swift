import Foundation
import GRDB
import LoupeCore

public struct CloudUploadReport: Sendable, Equatable {
    /// Files copied this pass (new or changed since their last upload).
    public var uploaded = 0
    /// Files whose upload failed this pass; they are listed in Unable to Upload.
    public var failed = 0
    /// Files in the library (versions and sidecars, Recently Deleted left out).
    public var total = 0
    /// The first failure's reason, for the settings.
    public var firstFailure: String?

    public init() {}
}

public enum CloudUploadError: LocalizedError {
    case folderUnavailable(URL)
    case folderOverlapsLibrary(URL)
    case copyMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable(let url):
            return "The upload folder \(url.path) isn't available. Is the drive connected and the sync app installed?"
        case .folderOverlapsLibrary(let url):
            return "The upload folder \(url.path) can't be inside the library, or contain it."
        case .copyMismatch(let name):
            return "The uploaded copy of \(name) didn't match the original."
        }
    }
}

/// Uploads the library to the cloud through a folder a sync app uploads (iCloud Drive, Dropbox, Google Drive,
/// OneDrive, a mounted NAS share): every file, sidecars too, is copied there under the same root-relative path,
/// via a temp name and verified by SHA-256 before it replaces what is there. What was copied is remembered by size
/// and modification time (`upload_state`), so a pass copies only new and changed files; failures are recorded per
/// file (`upload_failure`, which Unable to Upload lists) and retried by the next pass. Nothing is ever deleted from
/// the folder: removing a photo here leaves its upload in place.
public final class CloudUploader: Sendable {
    private let index: LibraryIndex
    private let root: URL
    private let destination: URL

    public init(index: LibraryIndex, root: URL, destination: URL) {
        self.index = index
        self.root = root
        self.destination = destination
    }

    /// Throws only for an unusable folder (nothing is recorded per file then) or cancellation. Runs off the caller's
    /// actor.
    @concurrent public func run(progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> CloudUploadReport {
        try checkDestination()
        let files = try listFiles()
        let uploaded = try await index.dbPool.read { db in
            var out: [String: (size: Int64, modified: Double)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT path, size, modified FROM upload_state") {
                out[row["path"]] = (row["size"], row["modified"])
            }
            return out
        }
        var report = CloudUploadReport()
        report.total = files.count
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            defer { progress(i + 1, files.count) }
            let source = Self.url(file.path, under: root)
            guard let stamp = FileHash.stamp(source) else { continue }  // gone since it was indexed: no failure
            if let last = uploaded[file.path], last.size == stamp.size, last.modified == stamp.modified { continue }
            do {
                try copyVerified(source, to: Self.url(file.path, under: destination))
                try await index.dbPool.write { db in
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO upload_state(path, size, modified, uploadedAt) VALUES (?, ?, ?, ?)",
                        arguments: [file.path, stamp.size, stamp.modified, Date().timeIntervalSince1970])
                    try db.execute(sql: "DELETE FROM upload_failure WHERE path = ?", arguments: [file.path])
                }
                report.uploaded += 1
            } catch {
                if error is CancellationError { throw error }
                let message = error.localizedDescription
                try? await index.dbPool.write { db in
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO upload_failure(path, photoId, message, failedAt) VALUES (?, ?, ?, ?)",
                        arguments: [file.path, file.photoID, message, Date().timeIntervalSince1970])
                }
                report.failed += 1
                if report.firstFailure == nil { report.firstFailure = "\(source.lastPathComponent): \(message)" }
            }
        }
        // Failures of files that are no longer in the library (moved, deleted) are moot.
        let current = Set(files.map(\.path))
        try await index.dbPool.write { db in
            for path in try String.fetchAll(db, sql: "SELECT path FROM upload_failure") where !current.contains(path) {
                try db.execute(sql: "DELETE FROM upload_failure WHERE path = ?", arguments: [path])
            }
        }
        return report
    }

    // MARK: - Steps

    private func checkDestination() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue,
            let dest = Self.realPath(destination), let lib = Self.realPath(root)
        else { throw CloudUploadError.folderUnavailable(destination) }
        // Copies inside the library would be indexed (and uploaded again); a library inside it would upload itself.
        if dest == lib || dest.hasPrefix(lib + "/") || lib.hasPrefix(dest + "/") {
            throw CloudUploadError.folderOverlapsLibrary(destination)
        }
    }

    /// Every version and each photo's sidecar, root-relative, outside Recently Deleted.
    private func listFiles() throws -> [(photoID: Int64, path: String)] {
        let deleted = LibrarySettings.recentlyDeletedFolderName
        let rows = try index.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.id, p.stem, v.path, v.isDisplay FROM version v JOIN photo p ON p.id = v.photoId \
                    WHERE NOT (p.folderPath = ? OR p.folderPath LIKE ? ESCAPE '\\') ORDER BY p.id, v.id
                    """,
                arguments: [deleted, LibraryIndex.escapeLike(deleted) + "/%"])
        }
        var files: [(photoID: Int64, path: String)] = []
        var sidecarsDone = Set<Int64>()
        for row in rows {
            let id: Int64 = row["id"], path: String = row["path"], stem: String = row["stem"]
            files.append((id, path))
            guard sidecarsDone.insert(id).inserted else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            let sidecar = folder.isEmpty ? stem + ".xmp" : folder + "/" + stem + ".xmp"
            if FileManager.default.fileExists(atPath: Self.url(sidecar, under: root).path) { files.append((id, sidecar)) }
        }
        return files
    }

    /// Copies to a hidden temp name next to `target`, checks the bytes, then puts it in place (replacing an older
    /// upload of the file).
    private func copyVerified(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".loupe-upload-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: source, to: temp)
        guard try FileHash.sha256(of: source, uncached: true) == FileHash.sha256(of: temp, uncached: true) else {
            throw CloudUploadError.copyMismatch(source.lastPathComponent)
        }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
    }

    private static func url(_ relative: String, under base: URL) -> URL {
        relative.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    private static func realPath(_ url: URL) -> String? {
        guard let p = realpath(url.path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
