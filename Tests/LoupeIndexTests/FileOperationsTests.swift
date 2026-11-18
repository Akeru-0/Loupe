import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeIndex

private struct Env {
    let lib: TestLibrary
    let library: Library
    let support: URL

    init() throws {
        lib = try TestLibrary()
        support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
        library = try Library(
            location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path),
            registry: FeatureRegistry(), supportDirectory: support, cacheDirectory: support.appendingPathComponent("cache"))
    }

    func id(_ key: String) throws -> Int64 { try #require(try library.index.photo(key: key)).id! }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: lib.url(path).path) }
    func names(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: lib.url(path).path)) ?? []).sorted()
    }
}

private func groups(in folder: URL) throws -> [PhotoGroup] {
    let fm = FileManager.default
    let urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    let files = urls.filter { $0.pathExtension.lowercased() != "xmp" }
        .map { MediaFile(url: $0, size: 0, modified: Date(timeIntervalSince1970: 0), created: Date(timeIntervalSince1970: 0)) }
    return PhotoGrouper(editMarkers: ["-", "_edited", " (edited"])
        .group(files, sidecars: urls.filter { $0.pathExtension.lowercased() == "xmp" }, in: folder)
}

private func addFullGroup(_ lib: TestLibrary, _ dir: String) throws {
    try lib.addFakeRaw("\(dir)/IMG_1.CR2")
    try lib.addJPEG("\(dir)/IMG_1.JPG")
    try lib.addJPEG("\(dir)/IMG_1-edited.jpeg")
    try lib.addSidecar("\(dir)/IMG_1.xmp")
    try lib.addSidecar("\(dir)/IMG_1.CR2.xmp")
}

@Suite struct FileOperationsTests {
    @Test func movesWholeGroupIncludingSidecars() throws {
        let lib = try TestLibrary()
        try addFullGroup(lib, "a")
        try lib.addFile("b/keep.txt")
        let g = try #require(try groups(in: lib.url("a")).first)
        let moved = try FileOperations.moveGroup(g, to: lib.url("b"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.url("a").path).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: lib.url("b").path).sorted()
        #expect(names == ["IMG_1-edited.jpeg", "IMG_1.CR2", "IMG_1.CR2.xmp", "IMG_1.JPG", "IMG_1.xmp", "keep.txt"])
        #expect(moved.allFiles.count == 5 && moved.allFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func collisionRenamesWholeGroup() throws {
        let lib = try TestLibrary()
        try addFullGroup(lib, "a")
        try lib.addJPEG("b/img_1.jpg")  // different case still collides
        let g = try #require(try groups(in: lib.url("a")).first)
        let moved = try FileOperations.moveGroup(g, to: lib.url("b"))
        #expect(moved.stem == "IMG_1 (1)")
        let names = try FileManager.default.contentsOfDirectory(atPath: lib.url("b").path).sorted()
        #expect(names == ["IMG_1 (1)-edited.jpeg", "IMG_1 (1).CR2", "IMG_1 (1).CR2.xmp", "IMG_1 (1).JPG", "IMG_1 (1).xmp", "img_1.jpg"])
        #expect(try groups(in: lib.url("b")).count == 2)
    }

    @Test func collisionSkipsTakenNumbers() throws {
        let lib = try TestLibrary()
        try lib.addJPEG("a/IMG_1.JPG")
        try lib.addJPEG("b/IMG_1.JPG")
        try lib.addJPEG("b/IMG_1 (1).JPG")
        let g = try #require(try groups(in: lib.url("a")).first)
        let moved = try FileOperations.moveGroup(g, to: lib.url("b"))
        #expect(moved.stem == "IMG_1 (2)")
    }

    @Test func nfdStemAndCaseDifferencesRename() throws {
        let lib = try TestLibrary()
        let nfd = "Cafe\u{301}"
        try lib.addJPEG("a/\(nfd).jpg")
        try lib.addSidecar("a/\(nfd.uppercased()).xmp")
        try lib.addJPEG("b/\(nfd.precomposedStringWithCanonicalMapping).jpg")
        let g = try #require(try groups(in: lib.url("a")).first)
        let moved = try FileOperations.moveGroup(g, to: lib.url("b"))
        #expect(moved.stem.hasSuffix("(1)"))
        #expect(moved.allFiles.count == 2 && moved.allFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(moved.allFiles.allSatisfy { $0.lastPathComponent.contains("(1)") })
    }

    @Test func failedMoveRollsBack() throws {
        let lib = try TestLibrary()
        try addFullGroup(lib, "a")
        let g = try #require(try groups(in: lib.url("a")).first)
        let before = try FileManager.default.contentsOfDirectory(atPath: lib.url("a").path).sorted()
        try lib.remove("a/IMG_1.xmp")  // a file that vanished after the group was read
        try lib.addFile("b/placeholder")
        // The group still lists the sidecar through the folder listing, so make a version fail instead.
        try lib.remove("a/IMG_1-edited.jpeg")
        #expect(throws: (any Error).self) { try FileOperations.moveGroup(g, to: lib.url("b")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.url("a").path).sorted()
            == before.filter { $0 != "IMG_1.xmp" && $0 != "IMG_1-edited.jpeg" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.url("b").path) == ["placeholder"])
    }

    @Test func missingDestinationIsRefused() throws {
        let lib = try TestLibrary()
        try lib.addJPEG("a/IMG_1.JPG")
        let g = try #require(try groups(in: lib.url("a")).first)
        #expect(throws: (any Error).self) { try FileOperations.moveGroup(g, to: lib.url("nope")) }
        #expect(FileManager.default.fileExists(atPath: lib.url("a/IMG_1.JPG").path))
    }

    @Test func sameFolderDoesNothingEvenWithDifferentSpelling() throws {
        let lib = try TestLibrary()
        try lib.addJPEG("Trip/IMG_1.JPG")
        let g = try #require(try groups(in: lib.url("Trip")).first)
        let moved = try FileOperations.moveGroup(g, to: lib.url("trip"))
        #expect(moved == g)
        #expect(FileManager.default.fileExists(atPath: lib.url("Trip/IMG_1.JPG").path))
    }

    @Test func trashRemovesAllFiles() throws {
        let lib = try TestLibrary()
        try addFullGroup(lib, "a")
        let g = try #require(try groups(in: lib.url("a")).first)
        let trashed = try FileOperations.trashGroup(g)
        defer { for u in trashed { try? FileManager.default.removeItem(at: u) } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.url("a").path).isEmpty)
        #expect(trashed.count == 5 && trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func libraryMoveCarriesEditSidecarAndCaseVariants() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addJPEG("a/IMG_1-edited.jpg")
        try e.lib.addSidecar("a/IMG_1.xmp")
        try e.lib.addSidecar("a/IMG_1-edited.xmp")
        try e.lib.addJPEG("a/IMG_2.jpg")
        try e.lib.addFile("b/placeholder")
        _ = await e.library.initialSync()
        let errors = await e.library.move([try e.id("a/IMG_1")], toFolder: "b")
        #expect(errors.isEmpty)
        #expect(e.names("a") == ["IMG_2.jpg"])
        #expect(e.names("b").filter { $0 != "placeholder" }.count >= 4)
        #expect(e.names("b").contains("IMG_1-edited.xmp"))
        #expect(try e.library.index.photo(key: "b/IMG_1") != nil)
        #expect(try e.library.index.photo(key: "a/IMG_1") == nil)
        #expect(try e.library.index.photo(key: "a/IMG_2") != nil)
    }

    @Test func libraryMoveRefusesMissingAndIgnoredDestinations() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addFile("LightCraft Library/placeholder")
        try e.lib.addFile(".hidden/placeholder")
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        for dest in ["nope", "LightCraft Library", ".hidden", "../x", "a/../a"] {
            let errors = await e.library.move([id], toFolder: dest)
            #expect(errors[id] != nil, "\(dest)")
        }
        #expect(e.exists("a/IMG_1.jpg"))
        #expect(await e.library.move([id], toFolder: "A").isEmpty)  // same folder, different case: no-op
        #expect(e.exists("a/IMG_1.jpg") && e.names("a") == ["IMG_1.jpg"])
    }

    @Test func libraryTrashRemovesPhoto() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addSidecar("a/IMG_1.xmp")
        try e.lib.addSidecar("a/IMG_1-edited.xmp")
        try e.lib.addJPEG("a/IMG_1-edited.jpg")
        _ = await e.library.initialSync()
        let (errors, trashed) = await e.library.trashReturningItems([try e.id("a/IMG_1")])
        defer { for u in trashed { try? FileManager.default.removeItem(at: u) } }
        #expect(errors.isEmpty && trashed.count == 4)
        #expect(e.names("a").isEmpty)
        #expect(try e.library.index.photo(key: "a/IMG_1") == nil)
    }

    @Test func albumCoverFollowsMove() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addFile("b/placeholder")
        try AlbumCatalogIO.save(AlbumCatalog(albums: [AlbumEntry(name: "Trip", cover: "a/IMG_1"),
                                                      AlbumEntry(name: "Other", cover: "a/IMG_9")]), root: e.lib.root)
        _ = await e.library.initialSync()
        _ = await e.library.move([try e.id("a/IMG_1")], toFolder: "b")
        let catalog = try AlbumCatalogIO.load(root: e.lib.root)
        #expect(catalog.albums.map(\.cover) == ["b/IMG_1", "a/IMG_9"])
    }

    @Test func renameFolderReindexes() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addJPEG("a/sub/IMG_2.jpg")
        try AlbumCatalogIO.save(AlbumCatalog(albums: [AlbumEntry(name: "Trip", cover: "a/sub/IMG_2")]), root: e.lib.root)
        _ = await e.library.initialSync()
        let new = try await e.library.renameFolder("a", to: "c")
        #expect(new == "c")
        #expect(try e.library.index.photo(key: "c/IMG_1") != nil)
        #expect(try e.library.index.photo(key: "c/sub/IMG_2") != nil)
        #expect(try e.library.index.photo(key: "a/IMG_1") == nil)
        #expect(try AlbumCatalogIO.load(root: e.lib.root).albums.first?.cover == "c/sub/IMG_2")
    }

    @Test func renameFolderNeverReplacesAndAllowsCaseChange() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addJPEG("b/IMG_2.jpg")
        _ = await e.library.initialSync()
        await #expect(throws: (any Error).self) { try await e.library.renameFolder("a", to: "B") }
        #expect(e.exists("a/IMG_1.jpg") && e.exists("b/IMG_2.jpg"))
        for bad in ["", ".", "..", ".x", "x/y", "x:y", "LightCraft Library"] {
            await #expect(throws: (any Error).self) { try await e.library.renameFolder("a", to: bad) }
        }
        let new = try await e.library.renameFolder("a", to: "A")
        #expect(new == "A")
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.lib.root.path).contains("A"))
        #expect(try e.library.index.photo(key: "A/IMG_1") != nil)
    }

    @Test func createFolderRefusesExistingAndInvalid() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        #expect(try await e.library.createFolder(named: "new", inFolder: "a") == "a/new")
        #expect(e.exists("a/new"))
        await #expect(throws: (any Error).self) { try await e.library.createFolder(named: "NEW", inFolder: "a") }
        await #expect(throws: (any Error).self) { try await e.library.createFolder(named: "x", inFolder: "missing") }
        await #expect(throws: (any Error).self) { try await e.library.createFolder(named: "a/b", inFolder: "") }
        #expect(try await e.library.createFolder(named: "top", inFolder: "") == "top")
    }
}

@Suite struct GroupMergeTests {
    private func sets(_ gs: [PhotoGroup]) -> [Set<String>] {
        gs.map { Set($0.allFiles.map(\.lastPathComponent)) }
    }

    @Test func differentExtensionSameStemStaysSeparate() throws {
        let lib = try TestLibrary()
        try lib.addFakeRaw("a/IMG_1.CR2")
        try lib.addSidecar("a/IMG_1.xmp")
        try lib.addFile("b/IMG_1.HEIC")
        let g = try #require(try groups(in: lib.url("a")).first)
        let moved = try FileOperations.moveGroup(g, to: lib.url("b"))
        #expect(moved.stem == "IMG_1 (1)")
        let gs = try groups(in: lib.url("b"))
        #expect(gs.count == 2)
        #expect(sets(gs).contains(["IMG_1.HEIC"]))
    }

    @Test func movedPhotoIsNotAbsorbedAsEdit() throws {
        let lib = try TestLibrary()
        try lib.addJPEG("a/IMG_1.jpg")
        try lib.addJPEG("b/IMG_1-2.jpg")
        let g = try #require(try groups(in: lib.url("a")).first)
        try FileOperations.moveGroup(g, to: lib.url("b"))
        #expect(try groups(in: lib.url("b")).count == 2)
    }

    @Test func movedPhotoDoesNotAbsorbExisting() throws {
        let lib = try TestLibrary()
        try lib.addJPEG("a/IMG_1-2.jpg")
        try lib.addJPEG("b/IMG_1.jpg")
        let g = try #require(try groups(in: lib.url("a")).first)
        // "IMG_1-2 (n)" still derives from IMG_1 whatever n is, so no name keeps the photos apart: refuse, move nothing.
        #expect(throws: (any Error).self) { try FileOperations.moveGroup(g, to: lib.url("b")) }
        #expect(FileManager.default.fileExists(atPath: lib.url("a/IMG_1-2.jpg").path))
        #expect(try groups(in: lib.url("b")).count == 1)
    }

    @Test func batchWithSharedStemStaysSeparate() async throws {
        let e = try Env()
        try e.lib.addFakeRaw("a/IMG_5.CR2")
        try e.lib.addJPEG("c/IMG_5.HEIC")
        try e.lib.addFile("b/placeholder")
        _ = await e.library.initialSync()
        let errors = await e.library.move([try e.id("a/IMG_5"), try e.id("c/IMG_5")], toFolder: "b")
        #expect(errors.isEmpty)
        #expect(try groups(in: e.lib.url("b")).count == 2)
    }
}
