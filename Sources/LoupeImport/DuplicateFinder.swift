import CryptoKit
import Foundation
import GRDB
import LoupeCore
import LoupeIndex

/// Streamed SHA-256: memory stays at one chunk however large the file.
public enum FileHash {
    public static let chunkSize = 4 << 20

    /// Lowercase hex SHA-256 of the file's bytes. Opens the file read-only. `uncached` reads past the page
    /// cache (`F_NOCACHE`), so a just-written copy is verified from the disk.
    public static func sha256(of url: URL, uncached: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if uncached { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: chunkSize) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Size and modification time from `stat` (follows symlinks), or nil if the file is gone or not a regular file.
    static func stamp(_ url: URL) -> (size: Int64, modified: Double)? {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (Int64(st.st_size), Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }
}

public struct DuplicateReport: Sendable {
    /// Card files with a byte-identical copy in the library tree or the Photos library.
    public var presentFiles: Set<URL>
    /// False when a Photos library was given but could not be read (fully), e.g. without Full Disk Access.
    /// Then files only in Photos are reported as new. True when no Photos library was given.
    public var photosLibraryChecked: Bool

    public init(presentFiles: Set<URL>, photosLibraryChecked: Bool) {
        self.presentFiles = presentFiles
        self.photosLibraryChecked = photosLibraryChecked
    }

    /// "On Mac": every media file of the group is present (sidecars do not count).
    public func isOnMac(_ group: PhotoGroup) -> Bool {
        group.versions.allSatisfy { presentFiles.contains($0.file.url) }
    }
}

/// Finds which card files are already on the Mac: same size, then same SHA-256, as any indexed library file or
/// any original in the Photos library. Card files with no size match are never read. Library-side hashes are
/// cached in `file_hash` and reused while a file's size and modification time are unchanged.
public struct DuplicateFinder: Sendable {
    public typealias Hasher = @Sendable (URL) throws -> String

    private let index: LibraryIndex
    private let root: URL
    private let photosLibrary: URL?
    private let hasher: Hasher

    public init(index: LibraryIndex, root: URL, photosLibrary: URL?) {
        self.init(index: index, root: root, photosLibrary: photosLibrary, hasher: { try FileHash.sha256(of: $0) })
    }

    init(index: LibraryIndex, root: URL, photosLibrary: URL?, hasher: @escaping Hasher) {
        self.index = index
        self.root = root
        self.photosLibrary = photosLibrary
        self.hasher = hasher
    }

    /// `progress(done, total)` counts the groups' media files.
    public func present(
        _ groups: [PhotoGroup], progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> DuplicateReport {
        var candidates = try librarySizes()
        let photos = photosLibrary.map(Self.photosOriginalsBySize)
        for (size, urls) in photos?.bySize ?? [:] { candidates[size, default: []] += urls }

        let files = groups.flatMap { $0.versions.map(\.file.url) }
        var present = Set<URL>()
        var candidateHashes: [URL: String?] = [:]  // per call; nil = unreadable
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            progress(i, files.count)
            guard let stamp = FileHash.stamp(file), let matches = candidates[stamp.size], !matches.isEmpty
            else { continue }
            let mine: String
            do { mine = try hasher(file) } catch { continue }  // unreadable card file: not present
            for candidate in matches {
                let theirs: String?
                if let known = candidateHashes[candidate] {
                    theirs = known
                } else {
                    theirs = try cachedHash(candidate)
                    candidateHashes[candidate] = .some(theirs)  // remember unreadable ones too
                }
                if theirs == mine {
                    present.insert(file)
                    break
                }
            }
        }
        progress(files.count, files.count)
        return DuplicateReport(presentFiles: present, photosLibraryChecked: photos?.complete ?? true)
    }

    // MARK: - Candidates

    /// Size → files, from the index's version rows.
    private func librarySizes() throws -> [Int64: [URL]] {
        let rows = try index.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT path, size FROM version")
        }
        var out: [Int64: [URL]] = [:]
        for row in rows {
            let path: String = row["path"]
            let size: Int64 = row["size"]
            out[size, default: []].append(VersionRecord(photoId: 0, path: path, kind: .image, size: size,
                                                        modified: .distantPast).url(in: root))
        }
        return out
    }

    /// Size → original, from a stat-only walk of `<library>/originals`. `complete` is false if any part of it
    /// (or the package itself) could not be read.
    private static func photosOriginalsBySize(_ library: URL) -> (bySize: [Int64: [URL]], complete: Bool) {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: library.path)) != nil else { return ([:], false) }
        let originals = library.appendingPathComponent("originals", isDirectory: true)
        guard fm.fileExists(atPath: originals.path) else { return ([:], true) }  // nothing stored locally
        guard (try? fm.contentsOfDirectory(atPath: originals.path)) != nil else { return ([:], false) }

        var complete = true
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: originals, includingPropertiesForKeys: keys, options: [],
                                             errorHandler: { _, _ in complete = false; return true })
        else { return ([:], false) }
        var out: [Int64: [URL]] = [:]
        for case let url as URL in enumerator {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, let size = v.fileSize
            else { continue }
            out[Int64(size), default: []].append(url)
        }
        return (out, complete)
    }

    // MARK: - Hash cache

    /// The candidate's SHA-256 from `file_hash` if its size and mtime still match, else hashed now and stored.
    /// Nil if the file is gone or unreadable.
    private func cachedHash(_ url: URL) throws -> String? {
        guard let stamp = FileHash.stamp(url) else { return nil }
        let path = url.path
        let cached = try index.dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT size, modified, sha256 FROM file_hash WHERE path = ?", arguments: [path])
        }
        if let cached, (cached["size"] as Int64) == stamp.size,
            abs((cached["modified"] as Double) - stamp.modified) < 0.001
        {
            return cached["sha256"] as String
        }
        guard let sha = try? hasher(url) else { return nil }
        // Only cache if the file did not change while it was read.
        if let after = FileHash.stamp(url), after == stamp {
            try FileHashRecord(path: path, size: stamp.size, modified: stamp.modified, sha256: sha).save(in: index)
        }
        return sha
    }
}
