import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeIndex

/// Counts (and lists) the files a hasher was asked to read.
private final class HashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return _paths.count }
    var names: [String] { lock.lock(); defer { lock.unlock() }; return _paths.map { ($0 as NSString).lastPathComponent }.sorted() }
    func reset() { lock.lock(); _paths = []; lock.unlock() }
    func hash(_ url: URL) throws -> String {
        lock.lock(); _paths.append(url.path); lock.unlock()
        return try FileHash.sha256(of: url)
    }
}

private struct Env {
    let lib: TestLibrary
    let index: LibraryIndex
    let scanner: LoupeIndex.Scanner
    let counter = HashCounter()
    let duplicates: DuplicateIndex

    init() throws {
        lib = try TestLibrary()
        index = try LibraryIndex(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-dup-\(UUID().uuidString).sqlite"))
        scanner = LoupeIndex.Scanner(
            index: index, location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path))
        let counter = counter
        duplicates = DuplicateIndex(index: index, root: lib.root, hasher: { try counter.hash($0) })
    }

    func scanAndRefresh() async throws -> [DuplicateSet] {
        _ = try await scanner.fullScan()
        try await duplicates.refresh()
        return try index.duplicateSets()
    }

    func id(_ key: String) throws -> Int64 { try #require(try index.photo(key: key)).id! }
}

/// `n` bytes of `byte`: same length, different content for different bytes.
private func bytes(_ byte: UInt8, _ n: Int = 64) -> Data { Data(repeating: byte, count: n) }

@Suite struct DuplicateIndexTests {
    @Test func sameSizeWithDifferentBytesIsNotADuplicate() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_1.jpg", bytes: bytes(1))
        try e.lib.addFile("b/IMG_1.jpg", bytes: bytes(2))
        #expect(try await e.scanAndRefresh().isEmpty)
        #expect(e.counter.count == 2)  // same size: both read, hashes differ
    }

    @Test func renamedCopyInAnotherAlbumIsADuplicate() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_1.jpg", bytes: bytes(1))
        try e.lib.addFile("b/Holiday.jpg", bytes: bytes(1))
        try e.lib.addFile("b/Other.jpg", bytes: bytes(3, 99))  // no size match: never read
        let sets = try await e.scanAndRefresh()
        try #require(sets.count == 1)
        #expect(Set(sets[0].copies.map(\.photoId)) == [try e.id("a/IMG_1"), try e.id("b/Holiday")])
        #expect(Set(sets[0].members.map(\.versionPath)) == ["a/IMG_1.jpg", "b/Holiday.jpg"])
        #expect(sets[0].members.allSatisfy { $0.kind == .jpeg && $0.size == 64 })
        #expect(Set(sets[0].members.map(\.folder)) == ["a", "b"])
        #expect(sets[0].copies.allSatisfy { $0.redundant })
        #expect(sets[0].reclaimableBytes == 64)
        #expect(e.counter.names == ["Holiday.jpg", "IMG_1.jpg"])
        #expect(try e.index.duplicateSetCount() == 1)
    }

    @Test func rawJpegPairIsNotADuplicateOfItself() async throws {
        let e = try Env()
        // Byte-identical files in one photo group are one photo, not two copies.
        try e.lib.addFile("a/IMG_2.CR2", bytes: bytes(7))
        try e.lib.addFile("a/IMG_2.jpg", bytes: bytes(7))
        #expect(try await e.scanAndRefresh().isEmpty)
        #expect(e.counter.count == 0)  // the only size match is inside one group
    }

    @Test func emptyFilesAreNeverDuplicates() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_1.jpg")
        try e.lib.addFile("b/IMG_1.jpg")
        #expect(try await e.scanAndRefresh().isEmpty)
    }

    @Test func groupWithAnExtraEditIsNotRedundant() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_3.jpg", bytes: bytes(1))
        try e.lib.addFile("b/IMG_3.jpg", bytes: bytes(1))
        try e.lib.addFile("b/IMG_3-edited.jpg", bytes: bytes(9, 80))  // b's own edit
        let sets = try await e.scanAndRefresh()
        try #require(sets.count == 1)
        let a = try e.id("a/IMG_3"), b = try e.id("b/IMG_3")
        let byID = Dictionary(uniqueKeysWithValues: sets[0].copies.map { ($0.photoId, $0) })
        #expect(byID[a]?.redundant == true)
        #expect(byID[b]?.redundant == false)
        #expect(sets[0].removable(keeping: a).isEmpty)  // b has its own edit
        #expect(sets[0].removable(keeping: b) == [a])
        #expect(sets[0].reclaimableBytes == 64)
    }

    @Test func copyMissingTheRawIsRedundantButNotTheOtherWayRound() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_4.CR2", bytes: bytes(5, 70))
        try e.lib.addFile("a/IMG_4.jpg", bytes: bytes(6))
        try e.lib.addFile("b/IMG_4.jpg", bytes: bytes(6))
        let sets = try await e.scanAndRefresh()
        try #require(sets.count == 1)
        let a = try e.id("a/IMG_4"), b = try e.id("b/IMG_4")
        #expect(sets[0].removable(keeping: a) == [b])
        #expect(sets[0].removable(keeping: b).isEmpty)  // a's RAW has no copy
    }

    @Test func groupsSharingAnyFileFormOneSet() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_5.CR2", bytes: bytes(5, 70))
        try e.lib.addFile("a/IMG_5.jpg", bytes: bytes(6))
        try e.lib.addFile("b/IMG_5.CR2", bytes: bytes(5, 70))
        try e.lib.addFile("b/IMG_5.jpg", bytes: bytes(6))
        let sets = try await e.scanAndRefresh()
        try #require(sets.count == 1)
        #expect(sets[0].copies.count == 2 && sets[0].members.count == 4)
        #expect(sets[0].reclaimableBytes == 134)
    }

    @Test func incrementalRefreshHashesOnlyNewFiles() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_1.jpg", bytes: bytes(1))
        try e.lib.addFile("b/IMG_1.jpg", bytes: bytes(1))
        try e.lib.addFile("c/Unique.jpg", bytes: bytes(2, 10))
        #expect(try await e.scanAndRefresh().count == 1)
        #expect(e.counter.count == 2)

        e.counter.reset()
        #expect(try await e.scanAndRefresh().count == 1)
        #expect(e.counter.count == 0)  // nothing changed: all from the cache

        e.counter.reset()
        try e.lib.addFile("c/Copy.jpg", bytes: bytes(1))
        try e.lib.addFile("c/Other.jpg", bytes: bytes(3, 11))  // no size match
        let sets = try await e.scanAndRefresh()
        #expect(e.counter.names == ["Copy.jpg"])
        try #require(sets.count == 1)
        #expect(sets[0].copies.count == 3)
    }

    @Test func cancelledRefreshStoresNothing() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_1.jpg", bytes: bytes(1))
        try e.lib.addFile("b/IMG_1.jpg", bytes: bytes(1))
        _ = try await e.scanner.fullScan()
        let dup = e.duplicates
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await dup.refresh()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try e.index.duplicateSets().isEmpty)
    }

    @Test func trashedCopyLeavesTheSet() async throws {
        let e = try Env()
        try e.lib.addFile("a/IMG_1.jpg", bytes: bytes(1))
        try e.lib.addFile("b/IMG_1.jpg", bytes: bytes(1))
        #expect(try await e.scanAndRefresh().count == 1)
        try e.lib.remove("b/IMG_1.jpg")
        _ = try await e.scanner.fullScan()
        #expect(try e.index.duplicateSets().isEmpty)  // even before the next refresh
    }
}

// MARK: - Library

/// A fake Trash in a temp dir: the real one is never touched.
private final class FakeTrash: @unchecked Sendable {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("loupe-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func trash(_ url: URL) throws -> URL {
        let target = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
    var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { String($0.dropFirst(37)) }.sorted()
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
}

@Suite struct DuplicateLibraryTests {
    @Test func trashingRedundantCopiesLeavesTheKeptPhotoUntouched() async throws {
        let lib = try TestLibrary()
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let library = try Library(
            location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path),
            registry: FeatureRegistry(), supportDirectory: support, cacheDirectory: support.appendingPathComponent("cache"))
        let trash = try FakeTrash()
        await library.setTrashItem { try trash.trash($0) }

        try lib.addFile("a/IMG_1.jpg", bytes: bytes(1))
        try lib.addSidecar("a/IMG_1.xmp", rating: 3)
        try lib.addFile("b/IMG_1.jpg", bytes: bytes(1))  // redundant copy
        try lib.addFile("c/Copy.jpg", bytes: bytes(1))
        try lib.addFile("c/Copy-edited.jpg", bytes: bytes(8, 90))  // has its own edit
        _ = await library.initialSync()
        await library.duplicateRefreshDone()
        let sets = try library.index.duplicateSets()
        try #require(sets.count == 1 && sets[0].copies.count == 3)

        func id(_ key: String) throws -> Int64 { try #require(try library.index.photo(key: key)).id! }
        let a = try id("a/IMG_1"), b = try id("b/IMG_1"), c = try id("c/Copy")
        let before = try FileHash.sha256(of: lib.url("a/IMG_1.jpg"))
        let errors = await library.trashRedundantCopies(keeping: a, others: [a, b, c])

        #expect(Set(errors.keys) == [c])
        #expect(errors[c] is DuplicateError)
        #expect(trash.names == ["IMG_1.jpg"])
        #expect(!FileManager.default.fileExists(atPath: lib.url("b/IMG_1.jpg").path))
        #expect(try FileHash.sha256(of: lib.url("a/IMG_1.jpg")) == before)
        #expect(FileManager.default.fileExists(atPath: lib.url("a/IMG_1.xmp").path))
        #expect(FileManager.default.fileExists(atPath: lib.url("c/Copy.jpg").path))
        #expect(FileManager.default.fileExists(atPath: lib.url("c/Copy-edited.jpg").path))
        #expect(try library.index.photo(id: a) != nil && library.index.photo(key: "b/IMG_1") == nil)

        await library.duplicateRefreshDone()
        let after = try library.index.duplicateSets()
        try #require(after.count == 1)
        #expect(Set(after[0].copies.map(\.photoId)) == [a, c])
        await library.stop()
    }

    @Test func aCopyChangedOnDiskSinceTheRefreshIsNotTrashed() async throws {
        let lib = try TestLibrary()
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let library = try Library(
            location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path),
            registry: FeatureRegistry(), supportDirectory: support, cacheDirectory: support.appendingPathComponent("cache"))
        let trash = try FakeTrash()
        await library.setTrashItem { try trash.trash($0) }

        try lib.addFile("a/IMG_1.jpg", bytes: bytes(1))
        try lib.addFile("b/IMG_1.jpg", bytes: bytes(1))
        _ = await library.initialSync()
        await library.duplicateRefreshDone()
        #expect(try library.index.duplicateSetCount() == 1)
        func id(_ key: String) throws -> Int64 { try #require(try library.index.photo(key: key)).id! }
        let a = try id("a/IMG_1"), b = try id("b/IMG_1")

        // The kept photo was overwritten (same size, new bytes) and no scan has seen it yet.
        try bytes(2).write(to: lib.url("a/IMG_1.jpg"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: lib.url("a/IMG_1.jpg").path)
        let errors = await library.trashRedundantCopies(keeping: a, others: [b])
        #expect(errors[b] is DuplicateError)
        #expect(trash.names.isEmpty)
        #expect(FileManager.default.fileExists(atPath: lib.url("b/IMG_1.jpg").path))
        await library.stop()
    }
}
