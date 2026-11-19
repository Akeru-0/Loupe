import CryptoKit
import Foundation
import LoupeCore
import LoupeIndex

public struct ImportPlan: Sendable {
    public var groups: [PhotoGroup]
    /// Root-relative; `""` is the root (Unsorted). Missing folders are created, e.g. `2026/Card test`.
    public var destinationFolder: String

    public init(groups: [PhotoGroup], destinationFolder: String) {
        self.groups = groups
        self.destinationFolder = destinationFolder
    }
}

public struct ImportProgress: Sendable, Equatable {
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
}

public struct ImportResult: Sendable {
    /// Root-relative paths of the new files.
    public var imported: [String] = []
    /// Source files not imported because the import was cancelled.
    public var skipped: [URL] = []
    /// Source files of groups that failed (every file of a failed group), with the group's error.
    public var failed: [URL: any Error] = [:]
    /// The destination folder as it is spelled on disk.
    public var destinationFolder = ""
}

public enum ImportError: LocalizedError {
    case notEnoughSpace(needed: Int64, available: Int64)
    case invalidDestination(String)
    case verificationFailed(URL)
    case sourceInsideLibrary(URL)
    case sameVolumeAsSource(URL)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough free space: the import needs \(f.string(fromByteCount: needed)), "
                + "\(f.string(fromByteCount: available)) is available."
        case .invalidDestination(let folder):
            return "Can't import into \"\(folder)\": it is not a folder in the library."
        case .verificationFailed(let url):
            return "The copy of \(url.lastPathComponent) did not match the original, so the photo was not imported."
        case .sourceInsideLibrary(let url):
            return "Can't import from \(url.path): it is already inside the library."
        case .sameVolumeAsSource(let url):
            return "Can't import from \(url.path) into a library on the same disk."
        }
    }
}

/// Copies photo groups from a card into the library. Each group is all-or-nothing: every file is copied to a
/// hidden temp name, re-read and compared by SHA-256, and only then renamed into place, with a `(n)` suffix
/// rather than ever replacing a file. Sources are only ever opened for reading.
public final class Importer: Sendable {
    /// Copies `source` to the new file `temp` and returns the SHA-256 of the bytes read from `source`.
    typealias Copier = @Sendable (_ source: URL, _ temp: URL) throws -> String
    /// Available bytes on the volume holding the URL.
    typealias Capacity = @Sendable (URL) throws -> Int64
    /// Identifies the volume (file system) holding an existing path; nil if it cannot be read.
    typealias VolumeIdentity = @Sendable (URL) -> Int64?

    private let root: URL
    private let index: LibraryIndex
    private let settings: LibrarySettings
    private let copier: Copier
    private let hasher: DuplicateFinder.Hasher
    private let capacity: Capacity
    private let volumeIdentity: VolumeIdentity

    public convenience init(
        root: URL, index: LibraryIndex, editMarkers: [String],
        excludedFolderNames: [String] = LibrarySettings(rootPath: "").excludedFolderNames
    ) {
        self.init(
            root: root, index: index, editMarkers: editMarkers, excludedFolderNames: excludedFolderNames,
            copier: Importer.streamCopy, hasher: { try FileHash.sha256(of: $0, uncached: true) },
            capacity: Importer.volumeCapacity,
            volumeIdentity: Importer.fileSystemID)
    }

    init(
        root: URL, index: LibraryIndex, editMarkers: [String],
        excludedFolderNames: [String] = LibrarySettings(rootPath: "").excludedFolderNames,
        copier: @escaping Copier, hasher: @escaping DuplicateFinder.Hasher, capacity: @escaping Capacity,
        volumeIdentity: @escaping VolumeIdentity
    ) {
        self.root = root
        self.index = index
        settings = LibrarySettings(rootPath: root.path, editMarkers: editMarkers, excludedFolderNames: excludedFolderNames)
        self.copier = copier
        self.hasher = hasher
        self.capacity = capacity
        self.volumeIdentity = volumeIdentity
    }

    /// Runs `work` (one group's final renames and bookkeeping) where it cannot race other library changes.
    typealias Committer = @Sendable (_ work: @Sendable () throws -> [String]) async throws -> [String]

    /// Throws only before anything is written: for an invalid destination, a destination on a source's volume,
    /// or too little space. After that, errors are reported per group in the result. Cancellation is honoured
    /// between files; the group in progress is removed and it and the remaining groups are reported as skipped.
    public func run(_ plan: ImportPlan, progress: @Sendable (ImportProgress) -> Void) async throws -> ImportResult {
        try await run(plan, progress: progress, commit: { try $0() })
    }

    /// As `run`, with each group's copy and verification outside `commit` and only its renames inside.
    func run(
        _ plan: ImportPlan, progress: @Sendable (ImportProgress) -> Void, commit: Committer
    ) async throws -> ImportResult {
        let target = try resolveDestination(plan.destinationFolder)
        // Every write goes under the root, so a source inside it could be written next to: refuse.
        let realRoot = target.realRoot + "/"
        if let inside = plan.groups.first(where: { (Self.realPath($0.folder) ?? $0.folder.path).hasPrefix(realRoot) }) {
            throw ImportError.sourceInsideLibrary(inside.folder)
        }
        try checkVolume(of: target.existing, against: plan.groups, folder: plan.destinationFolder)

        var sizes: [URL: Int64] = [:]
        for url in plan.groups.flatMap(\.allFiles) { sizes[url] = FileHash.stamp(url)?.size ?? 0 }
        let total = sizes.values.reduce(0, +)
        let needed = Int64((Double(total) * 1.05).rounded(.up))
        let available = try capacity(target.existing)
        guard available >= needed else { throw ImportError.notEnoughSpace(needed: needed, available: available) }

        let destination = try createDestination(target.components)
        // Re-check what was just created: still inside the root, still not on a source's volume.
        guard let real = Self.realPath(destination), real == target.realRoot || real.hasPrefix(realRoot) else {
            throw ImportError.invalidDestination(plan.destinationFolder)
        }
        try checkVolume(of: destination, against: plan.groups, folder: plan.destinationFolder)

        let relative = target.components.joined(separator: "/")
        var result = ImportResult(destinationFolder: relative)
        let filesTotal = plan.groups.reduce(0) { $0 + $1.allFiles.count }
        var filesDone = 0
        var bytesDone: Int64 = 0
        for group in plan.groups {
            let files = group.allFiles
            if Task.isCancelled {
                result.skipped += files
            } else {
                var copied = 0
                var copiedBytes: Int64 = 0
                var staged: [URL] = []
                do {
                    let digests = try stage(group, into: destination, temps: &staged) { url in
                        copied += 1
                        copiedBytes += sizes[url] ?? 0
                        progress(ImportProgress(filesDone: filesDone + copied, filesTotal: filesTotal,
                                                bytesDone: bytesDone + copiedBytes, bytesTotal: total))
                    }
                    if Task.isCancelled { throw CancellationError() }
                    let temps = staged
                    let names = try await commit { try self.place(group, temps: temps, digests: digests, in: destination) }
                    result.imported += names.map { relative.isEmpty ? $0 : relative + "/" + $0 }
                } catch {
                    let fm = FileManager.default
                    for url in staged where fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
                    if error is CancellationError {
                        result.skipped += files
                    } else {
                        for url in files { result.failed[url] = error }
                    }
                }
            }
            filesDone += files.count
            bytesDone += files.reduce(0) { $0 + (sizes[$1] ?? 0) }
            progress(ImportProgress(filesDone: filesDone, filesTotal: filesTotal, bytesDone: bytesDone,
                                    bytesTotal: total))
        }
        return result
    }

    // MARK: - One group

    /// Copies every file of the group to a hidden temp name in `destination` and verifies it; returns the
    /// sources' SHA-256s. `temps` collects the temp paths this call owns (nothing was there before it started
    /// copying); the caller removes them on error. Hidden names are never indexed, so this needs no lock.
    private func stage(
        _ group: PhotoGroup, into destination: URL, temps: inout [URL], copied: (URL) -> Void
    ) throws -> [String] {
        let fm = FileManager.default
        var digests: [String] = []
        for source in group.allFiles {
            if Task.isCancelled { throw CancellationError() }
            let temp = destination.appendingPathComponent(".\(source.lastPathComponent).loupe-import")
            if fm.fileExists(atPath: temp.path) { try fm.removeItem(at: temp) }  // left by an interrupted import
            temps.append(temp)
            let digest = try copier(source, temp)
            guard try hasher(temp) == digest else { throw ImportError.verificationFailed(source) }
            digests.append(digest)
            copied(source)
        }
        return digests
    }

    /// Renames the verified temp files into place under the first free `(n)` suffix, chosen against the folder
    /// as it is now, and records them. All or nothing: on error the files already renamed are removed again.
    private func place(_ group: PhotoGroup, temps: [URL], digests: [String], in destination: URL) throws -> [String] {
        let fm = FileManager.default
        let files = group.allFiles
        var placed: [URL] = []
        var names: [String] = []
        do {
            let n = try FileOperations.freeStemSuffix(
                for: files.map(\.lastPathComponent), stem: group.stem, in: destination, editMarkers: settings.editMarkers)
            for (source, temp) in zip(files, temps) {
                let name = try FileOperations.suffixedName(source.lastPathComponent, stem: group.stem, suffix: n)
                let final = destination.appendingPathComponent(name)
                guard !fm.fileExists(atPath: final.path) else { throw CocoaError(.fileWriteFileExists) }
                try fm.moveItem(at: temp, to: final)  // fails if the target exists; never replaces
                placed.append(final)
                names.append(name)
            }
        } catch {
            for url in placed { try? fm.removeItem(at: url) }  // our verified copies, just renamed
            throw error
        }

        let now = Date()
        let records = zip(zip(files, placed), digests).map { pair, sha in
            let stamp = FileHash.stamp(pair.1)
            return (
                record: ImportRecord(sha256: sha, sourceName: pair.0.lastPathComponent, importedAt: now),
                copy: stamp.map { FileHashRecord(path: pair.1.path, size: $0.size, modified: $0.modified, sha256: sha) })
        }
        // The files are verified and in place; a failed bookkeeping write must not undo the import.
        try? ImportRecord.record(records, in: index)
        return names
    }

    // MARK: - Destination

    /// The destination's components in their on-disk spelling where they exist, the deepest folder of it that
    /// exists, and the root's real path. Refuses `.`/`..`, hidden, excluded and package folders, symlinks,
    /// anything that is not a folder, and anything that resolves outside the root. Writes nothing.
    private func resolveDestination(
        _ folder: String
    ) throws -> (components: [String], existing: URL, realRoot: String) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue, let realRoot = Self.realPath(root)
        else { throw ImportError.invalidDestination(folder) }
        var url = root
        var existing = root
        var out: [String] = []
        var exists = true
        for name in folder.split(separator: "/").map(String.init) {
            guard name != ".", name != "..", !name.hasPrefix(".") else { throw ImportError.invalidDestination(folder) }
            var actual = name
            if exists {
                let names = try fm.contentsOfDirectory(atPath: url.path)
                let key = PhotoGrouper.stemKey(name)
                if let match = names.first(where: { $0 == name }) ?? names.first(where: { PhotoGrouper.stemKey($0) == key }) {
                    actual = match
                } else {
                    exists = false
                }
            }
            url.appendPathComponent(actual)
            if exists {
                var st = stat()
                guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {  // no symlinks, no files
                    throw ImportError.invalidDestination(folder)
                }
                existing = url
            }
            if LoupeIndex.Scanner.ignores(folder: url, settings: settings) { throw ImportError.invalidDestination(folder) }
            out.append(actual)
        }
        guard let real = Self.realPath(existing), real == realRoot || real.hasPrefix(realRoot + "/") else {
            throw ImportError.invalidDestination(folder)
        }
        return (out, existing, realRoot)
    }

    /// Refuses a destination on the same volume as any source: the library must never be on the card.
    private func checkVolume(of destination: URL, against groups: [PhotoGroup], folder: String) throws {
        guard let mine = volumeIdentity(destination) else { throw ImportError.invalidDestination(folder) }
        for sourceFolder in Set(groups.map(\.folder)) where volumeIdentity(sourceFolder) == mine {
            throw ImportError.sameVolumeAsSource(sourceFolder)
        }
    }

    private static func realPath(_ url: URL) -> String? {
        guard let p = realpath(url.path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Creates the missing folders one level at a time (never the root itself).
    private func createDestination(_ components: [String]) throws -> URL {
        var url = root
        for name in components {
            url.appendPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
        }
        return url
    }

    // MARK: - Defaults

    /// Streams `source` into a new file `temp` (never an existing one) in 4 MB chunks, hashing what it reads,
    /// bypassing the page cache and flushed with `F_FULLFSYNC`, then gives the copy the source's dates.
    /// The source is opened read-only.
    static let streamCopy: Copier = { source, temp in
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_NOCACHE, 1)  // so the verification re-read cannot be served from cached pages
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try input.read(upToCount: FileHash.chunkSize) }),
            !chunk.isEmpty
        {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        if fcntl(fd, F_FULLFSYNC) != 0 { try output.synchronize() }  // onto the medium, not just the drive cache
        try output.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let dates = [FileAttributeKey.modificationDate, .creationDate].compactMap { key in
            attributes[key].map { (key, $0) }
        }
        try FileManager.default.setAttributes(Dictionary(uniqueKeysWithValues: dates), ofItemAtPath: temp.path)
        return FileHash.hex(hasher.finalize())
    }

    /// `st_dev`: the mounted file system holding the path.
    static let fileSystemID: VolumeIdentity = { url in
        var st = stat()
        return stat(url.path, &st) == 0 ? Int64(st.st_dev) : nil
    }

    static let volumeCapacity: Capacity = { url in
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let c = values.volumeAvailableCapacityForImportantUsage { return c }
        if let c = values.volumeAvailableCapacity { return Int64(c) }
        throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
    }
}

extension Library {
    /// Imports `plan`. Copying and verifying run outside the serial section, so edits, moves and scans go on
    /// meanwhile; each group's renames and the final rescan of the destination run inside it.
    public nonisolated func importFiles(
        _ plan: ImportPlan, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportResult {
        let importer = Importer(
            root: location.rootURL, index: index, editMarkers: settings.editMarkers,
            excludedFolderNames: settings.excludedFolderNames)
        return try await importFiles(plan, progress: progress, using: importer)
    }

    nonisolated func importFiles(
        _ plan: ImportPlan, progress: @escaping @Sendable (ImportProgress) -> Void, using importer: Importer
    ) async throws -> ImportResult {
        let result = try await importer.run(plan, progress: progress) { work in
            try await self.addingFiles { (try work(), []) }
        }
        // A stopped library throws here; the files are in place and the next scan picks them up.
        try? await addingFiles { ((), [result.destinationFolder]) }
        return result
    }
}
