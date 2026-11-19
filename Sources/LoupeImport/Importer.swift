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

    private let root: URL
    private let index: LibraryIndex
    private let settings: LibrarySettings
    private let copier: Copier
    private let hasher: DuplicateFinder.Hasher
    private let capacity: Capacity

    public convenience init(
        root: URL, index: LibraryIndex, editMarkers: [String],
        excludedFolderNames: [String] = LibrarySettings(rootPath: "").excludedFolderNames
    ) {
        self.init(
            root: root, index: index, editMarkers: editMarkers, excludedFolderNames: excludedFolderNames,
            copier: Importer.streamCopy, hasher: FileHash.sha256(of:), capacity: Importer.volumeCapacity)
    }

    init(
        root: URL, index: LibraryIndex, editMarkers: [String],
        excludedFolderNames: [String] = LibrarySettings(rootPath: "").excludedFolderNames,
        copier: @escaping Copier, hasher: @escaping DuplicateFinder.Hasher, capacity: @escaping Capacity
    ) {
        self.root = root
        self.index = index
        settings = LibrarySettings(rootPath: root.path, editMarkers: editMarkers, excludedFolderNames: excludedFolderNames)
        self.copier = copier
        self.hasher = hasher
        self.capacity = capacity
    }

    /// Throws only before anything is written: for an invalid destination or too little space. After that,
    /// errors are reported per group in the result. Cancellation is honoured between files; the group in
    /// progress is removed and it and the remaining groups are reported as skipped.
    public func run(_ plan: ImportPlan, progress: @Sendable (ImportProgress) -> Void) async throws -> ImportResult {
        let components = try resolveDestination(plan.destinationFolder)
        // Every write goes under the root, so a source inside it could be written next to: refuse.
        let realRoot = root.resolvingSymlinksInPath().path + "/"
        if let inside = plan.groups.first(where: { $0.folder.resolvingSymlinksInPath().path.hasPrefix(realRoot) }) {
            throw ImportError.sourceInsideLibrary(inside.folder)
        }

        var sizes: [URL: Int64] = [:]
        for url in plan.groups.flatMap(\.allFiles) { sizes[url] = FileHash.stamp(url)?.size ?? 0 }
        let total = sizes.values.reduce(0, +)
        let needed = Int64((Double(total) * 1.05).rounded(.up))
        let available = try capacity(root)
        guard available >= needed else { throw ImportError.notEnoughSpace(needed: needed, available: available) }

        let destination = try createDestination(components)
        let relative = components.joined(separator: "/")
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
                do {
                    let names = try importGroup(group, into: destination) { url in
                        copied += 1
                        copiedBytes += sizes[url] ?? 0
                        progress(ImportProgress(filesDone: filesDone + copied, filesTotal: filesTotal,
                                                bytesDone: bytesDone + copiedBytes, bytesTotal: total))
                    }
                    result.imported += names.map { relative.isEmpty ? $0 : relative + "/" + $0 }
                } catch is CancellationError {
                    result.skipped += files
                } catch {
                    for url in files { result.failed[url] = error }
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

    /// Copies, verifies and renames one group into `destination`; returns the final file names. On any error
    /// every file this call created (temp or final) is removed and the error rethrown.
    private func importGroup(_ group: PhotoGroup, into destination: URL, copied: (URL) -> Void) throws -> [String] {
        let fm = FileManager.default
        let files = group.allFiles
        var temps: [URL] = []  // paths this call owns: nothing was there before it started copying
        var placed: [URL] = []
        var digests: [String] = []
        do {
            for source in files {
                if Task.isCancelled { throw CancellationError() }
                let temp = destination.appendingPathComponent(".\(source.lastPathComponent).loupe-import")
                if fm.fileExists(atPath: temp.path) { try fm.removeItem(at: temp) }  // left by an interrupted import
                temps.append(temp)
                let digest = try copier(source, temp)
                guard try hasher(temp) == digest else { throw ImportError.verificationFailed(source) }
                digests.append(digest)
                copied(source)
            }
            if Task.isCancelled { throw CancellationError() }

            let n = try FileOperations.freeStemSuffix(
                for: files.map(\.lastPathComponent), stem: group.stem, in: destination, editMarkers: settings.editMarkers)
            var names: [String] = []
            for (source, temp) in zip(files, temps) {
                let name = try FileOperations.suffixedName(source.lastPathComponent, stem: group.stem, suffix: n)
                let final = destination.appendingPathComponent(name)
                guard !fm.fileExists(atPath: final.path) else { throw CocoaError(.fileWriteFileExists) }
                try fm.moveItem(at: temp, to: final)  // fails if the target exists; never replaces
                placed.append(final)
                names.append(name)
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
        } catch {
            for url in placed { try? fm.removeItem(at: url) }  // our verified copies, just renamed
            for url in temps where fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
            throw error
        }
    }

    // MARK: - Destination

    /// The destination's components in their on-disk spelling where they exist. Refuses `.`/`..`, hidden,
    /// excluded and package folders, and anything that is not a folder. Writes nothing.
    private func resolveDestination(_ folder: String) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.invalidDestination(folder)
        }
        var url = root
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
            if exists, !(fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) {
                throw ImportError.invalidDestination(folder)
            }
            if LoupeIndex.Scanner.ignores(folder: url, settings: settings) { throw ImportError.invalidDestination(folder) }
            out.append(actual)
        }
        return out
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
    /// then gives the copy the source's dates. The source is opened read-only.
    static let streamCopy: Copier = { source, temp in
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try input.read(upToCount: FileHash.chunkSize) }),
            !chunk.isEmpty
        {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let dates = [FileAttributeKey.modificationDate, .creationDate].compactMap { key in
            attributes[key].map { (key, $0) }
        }
        try FileManager.default.setAttributes(Dictionary(uniqueKeysWithValues: dates), ofItemAtPath: temp.path)
        return FileHash.hex(hasher.finalize())
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
    /// Imports `plan` in the serial section, then rescans the destination folder there too.
    public func importFiles(
        _ plan: ImportPlan, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportResult {
        let importer = Importer(
            root: location.rootURL, index: index, editMarkers: settings.editMarkers,
            excludedFolderNames: settings.excludedFolderNames)
        return try await addingFiles {
            let result = try await importer.run(plan, progress: progress)
            return (result, [result.destinationFolder])
        }
    }
}
