import Foundation
import Testing
import LoupeCore
import LoupeIndex
import LoupeTestSupport
@testable import LoupeImport

/// A library folder with its own index; `scan()` indexes whatever is on disk.
final class IndexedLibrary: @unchecked Sendable {
    let lib: TestLibrary
    let index: LibraryIndex
    let support: URL

    init() throws {
        lib = try TestLibrary()
        support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        index = try LibraryIndex(databaseURL: support.appendingPathComponent("index.sqlite"))
    }

    var root: URL { lib.root }

    func scan() async throws {
        let location = LocalFolderLocation(rootURL: lib.root)
        _ = try await LoupeIndex.Scanner(index: index, location: location, settings: LibrarySettings(rootPath: lib.root.path))
            .fullScan()
    }

    deinit { try? FileManager.default.removeItem(at: support) }
}

let markers = ["-", "_edited", " (edited"]

/// A hasher that counts the files it reads under `root`.
final class CountingHasher: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var _reads: [String] = []
    init(root: URL) { self.root = root }
    var reads: [String] { lock.lock(); defer { lock.unlock() }; return _reads }
    func hash(_ url: URL) throws -> String {
        if url.path.hasPrefix(root.path + "/") { lock.lock(); _reads.append(url.lastPathComponent); lock.unlock() }
        return try FileHash.sha256(of: url)
    }
}

@Suite struct DuplicateFinderTests {
    @Test func sameSizeDifferentBytesIsNew() async throws {
        let library = try IndexedLibrary()
        try library.lib.addFile("a/X.CR2", bytes: randomBytes(1000))
        try await library.scan()
        let volumes = try FakeVolumes()
        let card = try volumes.addCard()
        try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_1.CR2", bytes: randomBytes(1000))
        let groups = try CardListing.groups(on: card, editMarkers: markers)

        let report = try await DuplicateFinder(index: library.index, root: library.root, photosLibrary: nil)
            .present(groups)
        #expect(report.presentFiles.isEmpty)
        #expect(!report.isOnMac(try #require(groups.first)))
    }

    @Test func renamedCopyIsPresent() async throws {
        let library = try IndexedLibrary()
        let bytes = randomBytes(1500)
        try library.lib.addFile("Trip/X.CR2", bytes: bytes)
        try await library.scan()
        let volumes = try FakeVolumes()
        let card = try volumes.addCard()
        let cr2 = try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_9.CR2", bytes: bytes)
        try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_9.JPG", bytes: randomBytes(300))
        try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_10.CR2", bytes: bytes)
        let groups = try CardListing.groups(on: card, editMarkers: markers)

        let report = try await DuplicateFinder(index: library.index, root: library.root, photosLibrary: nil)
            .present(groups)
        #expect(report.presentFiles.contains(cr2))
        #expect(report.presentFiles.count == 2)  // IMG_9.CR2 and IMG_10.CR2; not the JPG
        let byStem = Dictionary(uniqueKeysWithValues: groups.map { ($0.stem, $0) })
        #expect(report.isOnMac(try #require(byStem["IMG_10"])))
        #expect(!report.isOnMac(try #require(byStem["IMG_9"])))  // its JPG is new
    }

    @Test func photosLibraryOriginalsAreChecked() async throws {
        let library = try IndexedLibrary()
        let bytes = randomBytes(2000)
        let photos = library.root.appendingPathComponent("Photos Library.photoslibrary")
        try library.lib.addFile("Photos Library.photoslibrary/originals/A/0A1B2C3D-UUID.cr2", bytes: bytes)
        try await library.scan()  // the package is never indexed
        let volumes = try FakeVolumes()
        let card = try volumes.addCard()
        let cr2 = try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_1.CR2", bytes: bytes)
        let groups = try CardListing.groups(on: card, editMarkers: markers)

        let without = try await DuplicateFinder(index: library.index, root: library.root, photosLibrary: nil)
            .present(groups)
        #expect(without.presentFiles.isEmpty)
        let report = try await DuplicateFinder(index: library.index, root: library.root, photosLibrary: photos)
            .present(groups)
        #expect(report.presentFiles == [cr2])
        #expect(report.photosLibraryChecked)
    }

    @Test func unreadablePhotosLibraryIsReported() async throws {
        let library = try IndexedLibrary()
        let bytes = randomBytes(2000)
        let photos = library.root.appendingPathComponent("Photos Library.photoslibrary")
        let originals = photos.appendingPathComponent("originals")
        try library.lib.addFile("Photos Library.photoslibrary/originals/A/UUID.cr2", bytes: bytes)
        try await library.scan()
        let volumes = try FakeVolumes()
        let card = try volumes.addCard()
        try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_1.CR2", bytes: bytes)
        let groups = try CardListing.groups(on: card, editMarkers: markers)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: originals.path)
        defer {  // before `library` is cleaned up, or its removal would fail on the locked folder
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originals.path)
            withExtendedLifetime(library) {}
        }
        let report = try await DuplicateFinder(index: library.index, root: library.root, photosLibrary: photos)
            .present(groups)
        #expect(!report.photosLibraryChecked)
        #expect(report.presentFiles.isEmpty)
    }

    @Test func hashesAreCached() async throws {
        let library = try IndexedLibrary()
        let bytes = randomBytes(1200)
        let x = try library.lib.addFile("a/X.CR2", bytes: bytes)
        try library.lib.addFile("a/Y.CR2", bytes: randomBytes(1200))  // same size, other bytes
        try library.lib.addFile("a/Z.CR2", bytes: randomBytes(77))  // no size match: never hashed
        try await library.scan()
        let volumes = try FakeVolumes()
        let card = try volumes.addCard()
        let cr2 = try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_1.CR2", bytes: bytes)
        try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_2.CR2", bytes: randomBytes(500))  // no size match
        let groups = try CardListing.groups(on: card, editMarkers: markers)

        let libHasher = CountingHasher(root: library.root)
        let cardHasher = CountingHasher(root: volumes.url)
        let finder = DuplicateFinder(
            index: library.index, root: library.root, photosLibrary: nil,
            hasher: { url in _ = try cardHasher.hash(url); return try libHasher.hash(url) })

        let first = try await finder.present(groups)
        #expect(first.presentFiles == [cr2])
        #expect(Set(libHasher.reads).isSubset(of: ["X.CR2", "Y.CR2"]) && !libHasher.reads.isEmpty)
        #expect(cardHasher.reads == ["IMG_1.CR2"])  // IMG_2 has no size match

        let before = libHasher.reads.count
        let second = try await finder.present(groups)
        #expect(second.presentFiles == [cr2])
        #expect(libHasher.reads.count == before)

        // A changed file is hashed again.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: x.path)
        let third = try await finder.present(groups)
        #expect(third.presentFiles == [cr2])
        #expect(libHasher.reads.count > before)
        #expect(libHasher.reads.dropFirst(before).contains("X.CR2"))
    }
}
