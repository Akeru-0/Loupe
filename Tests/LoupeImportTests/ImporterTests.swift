import Foundation
import Testing
import LoupeCore
import LoupeIndex
import LoupeTestSupport
@testable import LoupeImport

/// Every path under `url` with its size and modification date: the card must look exactly the same afterwards.
private func snapshot(_ url: URL) -> [String: String] {
    var out: [String: String] = [:]
    let fm = FileManager.default
    guard let e = fm.enumerator(atPath: url.path) else { return out }
    for case let rel as String in e {
        let attrs = (try? fm.attributesOfItem(atPath: url.appendingPathComponent(rel).path)) ?? [:]
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        out[rel] = "\(attrs[.size] ?? "-") \(mtime)"
    }
    return out
}

/// Every name under `url`, hidden ones included.
private func allNames(_ url: URL) -> [String] {
    ((FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String]) ?? []).sorted()
}

private func sha(_ url: URL) throws -> String { try FileHash.sha256(of: url) }

/// A card with IMG_1 (a RAW over two 4 MB chunks plus a JPEG) and IMG_2 (a RAW).
private func makeCard(_ volumes: FakeVolumes) throws -> (Card, [PhotoGroup]) {
    let card = try volumes.addCard()
    try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_1.CR2", bytes: randomBytes(9 * 1024 * 1024 + 123))
    try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_1.JPG", bytes: randomBytes(3000))
    try volumes.addFile("EOS_DIGITAL/DCIM/100CANON/IMG_2.CR2", bytes: randomBytes(4000))
    return (card, try CardListing.groups(on: card, editMarkers: markers))
}

/// Stand-in for `st_dev`, since fake card and library share one temp volume: paths under a fake volume are
/// "the card", everything else "the Mac". It deliberately does not follow symlinks.
private let fakeVolumeIdentity: Importer.VolumeIdentity = { url in url.path.contains("/loupe-volumes-") ? 1 : 2 }

private func importer(
    _ library: IndexedLibrary, index: LibraryIndex? = nil, copier: Importer.Copier? = nil,
    capacity: Importer.Capacity? = nil, volumeIdentity: Importer.VolumeIdentity? = nil
) -> Importer {
    Importer(
        root: library.root, index: index ?? library.index, editMarkers: markers,
        copier: copier ?? Importer.streamCopy, hasher: { try FileHash.sha256(of: $0, uncached: true) }, capacity: capacity ?? { _ in Int64.max },
        volumeIdentity: volumeIdentity ?? fakeVolumeIdentity)
}

private func makeLibrary(_ library: IndexedLibrary) throws -> Library {
    try Library(
        location: LocalFolderLocation(rootURL: library.root), settings: LibrarySettings(rootPath: library.root.path),
        registry: FeatureRegistry(), supportDirectory: library.support,
        cacheDirectory: library.support.appendingPathComponent("cache"))
}

@Suite struct ImporterTests {
    @Test func importCopiesAndVerifies() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        let before = snapshot(volumes.url)

        let result = try await importer(library).run(ImportPlan(groups: groups, destinationFolder: ""), progress: { _ in })
        #expect(result.imported.sorted() == ["IMG_1.CR2", "IMG_1.JPG", "IMG_2.CR2"])
        #expect(result.failed.isEmpty && result.skipped.isEmpty)
        #expect(allNames(library.root) == ["IMG_1.CR2", "IMG_1.JPG", "IMG_2.CR2"])  // no temp files left
        for name in ["IMG_1.CR2", "IMG_1.JPG", "IMG_2.CR2"] {
            let source = volumes.url.appendingPathComponent("EOS_DIGITAL/DCIM/100CANON/\(name)")
            #expect(try sha(library.root.appendingPathComponent(name)) == sha(source))
        }
        #expect(snapshot(volumes.url) == before)
        let records = try ImportRecord.all(in: library.index)
        #expect(records.map(\.sourceName).sorted() == ["IMG_1.CR2", "IMG_1.JPG", "IMG_2.CR2"])
    }

    @Test func importIntoNewNestedAlbum() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        let result = try await importer(library)
            .run(ImportPlan(groups: groups, destinationFolder: "2026/Card test"), progress: { _ in })
        #expect(result.imported.sorted() == ["2026/Card test/IMG_1.CR2", "2026/Card test/IMG_1.JPG", "2026/Card test/IMG_2.CR2"])
        #expect(result.destinationFolder == "2026/Card test")
        #expect(allNames(library.root.appendingPathComponent("2026/Card test")) == ["IMG_1.CR2", "IMG_1.JPG", "IMG_2.CR2"])
    }

    @Test func refusesHiddenExcludedPackageOrEscapingDestinations() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        try library.lib.addFile("Real/keep.txt", bytes: Data())
        for dest in [".hidden", "Real/.x", "a/../b", "..", "LightCraft Library", "lightcraft library/x", "x.photoslibrary"] {
            await #expect(throws: ImportError.self, "\(dest)") {
                try await importer(library).run(ImportPlan(groups: groups, destinationFolder: dest), progress: { _ in })
            }
        }
        #expect(allNames(library.root) == ["Real", "Real/keep.txt"])
    }

    @Test func collisionGetsSuffixNotOverwrite() async throws {
        let library = try IndexedLibrary()
        let mine = randomBytes(9 * 1024 * 1024 + 123)
        let existing = try library.lib.addFile("IMG_1.CR2", bytes: mine)
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)

        let result = try await importer(library).run(ImportPlan(groups: groups, destinationFolder: ""), progress: { _ in })
        #expect(result.imported.sorted() == ["IMG_1 (1).CR2", "IMG_1 (1).JPG", "IMG_2.CR2"])
        #expect(try Data(contentsOf: existing) == mine)
        #expect(allNames(library.root) == ["IMG_1 (1).CR2", "IMG_1 (1).JPG", "IMG_1.CR2", "IMG_2.CR2"])
    }

    @Test func corruptCopyIsCleanedUp() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        // Corrupts IMG_1.JPG, the second file of IMG_1: its RAW, already copied, must go too.
        let corrupting: Importer.Copier = { source, temp in
            let digest = try Importer.streamCopy(source, temp)
            if source.lastPathComponent == "IMG_1.JPG" {
                var data = try Data(contentsOf: temp)
                data[10] ^= 0xFF
                try data.write(to: temp)
            }
            return digest
        }
        let result = try await importer(library, copier: corrupting)
            .run(ImportPlan(groups: groups, destinationFolder: ""), progress: { _ in })
        #expect(result.imported == ["IMG_2.CR2"])
        #expect(Set(result.failed.keys.map(\.lastPathComponent)) == ["IMG_1.CR2", "IMG_1.JPG"])
        #expect(allNames(library.root) == ["IMG_2.CR2"])
        #expect(try ImportRecord.all(in: library.index).map(\.sourceName) == ["IMG_2.CR2"])
    }

    @Test func notEnoughSpaceThrowsBeforeCopying() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        for dest in ["", "2026/New"] {
            await #expect {
                try await importer(library, capacity: { _ in 10 })
                    .run(ImportPlan(groups: groups, destinationFolder: dest), progress: { _ in })
            } throws: { error in
                guard case ImportError.notEnoughSpace(let needed, let available) = error else { return false }
                return available == 10 && needed >= Int64(9 * 1024 * 1024 + 123 + 7000)
            }
        }
        #expect(allNames(library.root).isEmpty)
    }

    @Test func cancelledImportLeavesNothing() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        let cancelling: Importer.Copier = { source, temp in
            withUnsafeCurrentTask { $0?.cancel() }  // cancelled while copying the first file of IMG_1
            return try Importer.streamCopy(source, temp)
        }
        let task = Task {
            try await importer(library, copier: cancelling)
                .run(ImportPlan(groups: groups, destinationFolder: ""), progress: { _ in })
        }
        let result = try await task.value
        #expect(result.imported.isEmpty)
        #expect(Set(result.skipped.map(\.lastPathComponent)) == ["IMG_1.CR2", "IMG_1.JPG", "IMG_2.CR2"])
        #expect(allNames(library.root).isEmpty)
    }

    @Test func reimportFindsNothingNew() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        let lib = try makeLibrary(library)

        let hasher = CountingHasher(root: library.root)
        let finder = DuplicateFinder(index: lib.index, root: library.root, photosLibrary: nil, hasher: hasher.hash)
        #expect(try await finder.present(groups).presentFiles.isEmpty)
        let result = try await lib.importFiles(
            ImportPlan(groups: groups, destinationFolder: "2026/Card"), progress: { _ in },
            using: importer(library, index: lib.index))
        #expect(result.imported.count == 3)
        #expect(try lib.index.photo(key: "2026/Card/IMG_1") != nil)  // rescanned in the serial section
        let report = try await finder.present(groups)
        #expect(groups.allSatisfy(report.isOnMac))
        #expect(hasher.reads.isEmpty)  // the copies' hashes were cached by the import
    }

    @Test func symlinkedDestinationIsRefused() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (card, groups) = try makeCard(volumes)
        let fm = FileManager.default
        let cardFolder = card.dcimURL.appendingPathComponent("100CANON")
        try fm.createSymbolicLink(at: library.root.appendingPathComponent("Card"), withDestinationURL: cardFolder)
        try fm.createDirectory(at: library.root.appendingPathComponent("Real"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: library.root.appendingPathComponent("Real/Link"), withDestinationURL: cardFolder)
        let before = snapshot(volumes.url)

        for dest in ["Card", "card/New", "Real/Link", "Real/Link/Deeper"] {
            await #expect(throws: ImportError.self, "\(dest)") {
                try await importer(library).run(ImportPlan(groups: groups, destinationFolder: dest), progress: { _ in })
            }
        }
        #expect(snapshot(volumes.url) == before)
        #expect(allNames(library.root) == ["Card", "Real", "Real/Link"])
    }

    @Test func libraryOnTheCardsVolumeIsRefused() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        let before = snapshot(volumes.url)
        for dest in ["", "2026/New"] {
            await #expect(throws: ImportError.self, "\(dest)") {
                try await importer(library, volumeIdentity: { _ in 7 })  // everything on one volume
                    .run(ImportPlan(groups: groups, destinationFolder: dest), progress: { _ in })
            }
        }
        #expect(allNames(library.root).isEmpty)
        #expect(snapshot(volumes.url) == before)
    }

    @Test func importDoesNotBlockEdits() async throws {
        let library = try IndexedLibrary()
        let volumes = try FakeVolumes()
        let (_, groups) = try makeCard(volumes)
        try library.lib.addJPEG("Other/A.jpg")
        let lib = try makeLibrary(library)
        _ = try await LoupeIndex.Scanner(
            index: lib.index, location: LocalFolderLocation(rootURL: library.root),
            settings: LibrarySettings(rootPath: library.root.path)
        ).fullScan()
        let other = try #require(try lib.index.photo(key: "Other/A")?.id)

        // The first copy waits (up to 5 s) until the edit below has finished.
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let first = Box(true)
        let gated: Importer.Copier = { source, temp in
            if first.value {
                first.value = false
                started.signal()
                _ = gate.wait(timeout: .now() + 5)
            }
            return try Importer.streamCopy(source, temp)
        }
        let done = Box(false)
        let importer = importer(library, index: lib.index, copier: gated)
        let task = Task {
            let result = try await lib.importFiles(
                ImportPlan(groups: groups, destinationFolder: ""), progress: { _ in }, using: importer)
            done.value = true
            return result
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { _ = started.wait(timeout: .now() + 5); c.resume() }
        }

        let errors = await lib.apply([.setRating(3)], to: [other])
        #expect(errors.isEmpty)
        #expect(!done.value)  // the edit did not wait for the import
        gate.signal()
        let result = try await task.value
        #expect(result.imported.sorted() == ["IMG_1.CR2", "IMG_1.JPG", "IMG_2.CR2"])
        #expect(try lib.index.photo(key: "IMG_1") != nil)  // rescanned at the end
        #expect(try lib.index.metadata(ofPhoto: other).rating == 3)
    }
}
