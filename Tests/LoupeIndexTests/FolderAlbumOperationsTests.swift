import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeIndex

/// Folder albums end to end: folders on disk, the album tree, moves and Delete Album. Temp folders only;
/// nothing here may reach the Trash.
private struct Env {
    let lib: TestLibrary
    let library: Library
    let settings: LibrarySettings

    init() throws {
        lib = try TestLibrary()
        settings = LibrarySettings(rootPath: lib.root.path)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
        library = try Library(
            location: LocalFolderLocation(rootURL: lib.root), settings: settings,
            registry: FeatureRegistry(), supportDirectory: support, cacheDirectory: support.appendingPathComponent("cache"))
    }

    func tree() throws -> [AlbumNode] { try library.index.albumTree(root: lib.root, settings: settings) }
    func id(_ key: String) throws -> Int64 { try #require(try library.index.photo(key: key)).id! }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: lib.url(path).path) }
    func names(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: lib.url(path).path)) ?? []).sorted()
    }
    func photos(_ scope: PhotoQuery.Scope) throws -> [Int64] {
        try library.index.sections(for: PhotoQuery(scope: scope)).flatMap(\.photoIDs)
    }

    /// Trash entries whose name starts with `prefix`, when the Trash can be listed at all (it needs Full Disk Access).
    static func trashEntries(prefix: String) -> [String]? {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
            let names = try? FileManager.default.contentsOfDirectory(atPath: trash.path)
        else { return nil }
        return names.filter { $0.hasPrefix(prefix) }
    }
}

private func addRawGroup(_ lib: TestLibrary, _ dir: String, _ stem: String = "IMG_1") throws {
    let prefix = dir.isEmpty ? "" : dir + "/"
    try lib.addFakeRaw("\(prefix)\(stem).CR2")
    try lib.addJPEG("\(prefix)\(stem).JPG")
    try lib.addSidecar("\(prefix)\(stem).xmp", tags: ["Kept"])
}

@Suite struct FolderAlbumOperationsTests {
    @Test func newEmptyAlbumIsListed() async throws {
        let e = try Env()
        try e.lib.addJPEG("IMG_0.jpg")
        _ = await e.library.initialSync()
        #expect(try await e.library.createFolder(named: "Empty", inFolder: "") == "Empty")
        #expect(try e.tree() == [AlbumNode(path: "Empty", name: "Empty", kind: .album, children: [])])
    }

    @Test func newAlbumInsideGroup() async throws {
        let e = try Env()
        try e.lib.addJPEG("2026/Norway/IMG_0.jpg")
        _ = await e.library.initialSync()
        #expect(try await e.library.createFolder(named: "Iceland", inFolder: "2026") == "2026/Iceland")
        let tree = try e.tree()
        #expect(tree.map(\.name) == ["2026"])
        #expect(tree.first?.kind == .group)
        #expect(tree.first?.children.map(\.name) == ["Iceland", "Norway"])
        #expect(tree.first?.children.map(\.kind) == [.album, .album])
        #expect(tree.first?.children.map(\.path) == ["2026/Iceland", "2026/Norway"])
    }

    @Test func moveIntoAlbumMovesFiles() async throws {
        let e = try Env()
        try addRawGroup(e.lib, "")
        _ = await e.library.initialSync()
        let album = try await e.library.createFolder(named: "a", inFolder: "")
        let errors = await e.library.move([try e.id("IMG_1")], toFolder: album)
        #expect(errors.isEmpty)
        #expect(e.names("a") == ["IMG_1.CR2", "IMG_1.JPG", "IMG_1.xmp"])
        #expect(e.names("") == ["a"])
        #expect(try e.library.index.photo(key: "a/IMG_1")?.folderPath == "a")
        #expect(try e.photos(.unsorted).isEmpty)
        #expect(try e.photos(.folder("a")).count == 1)
        #expect(try e.library.index.metadata(ofPhoto: try e.id("a/IMG_1")).tags == ["Kept"])
    }

    @Test func deleteAlbumReturnsPhotosToUnsorted() async throws {
        let e = try Env()
        let name = "Album-\(UUID().uuidString)"
        try addRawGroup(e.lib, name)
        try e.lib.addFile("\(name)/.DS_Store", bytes: Data("x".utf8))  // Finder's litter does not keep the folder
        _ = await e.library.initialSync()
        let errors = await e.library.deleteAlbum(name)
        #expect(errors.isEmpty)
        #expect(e.names("") == ["IMG_1.CR2", "IMG_1.JPG", "IMG_1.xmp"])
        #expect(!e.exists(name))
        #expect(try e.library.index.photo(key: "IMG_1")?.folderPath == "")
        #expect(try e.photos(.unsorted).count == 1)
        #expect(try e.tree().isEmpty)
        // Removed, never trashed (checked only where the Trash can be read).
        if let trashed = Env.trashEntries(prefix: name) { #expect(trashed.isEmpty) }
    }

    @Test func deleteAlbumKeepsFolderWithSubfolders() async throws {
        let e = try Env()
        try addRawGroup(e.lib, "a")
        try addRawGroup(e.lib, "a/b", "IMG_2")
        _ = await e.library.initialSync()
        let errors = await e.library.deleteAlbum("a")
        #expect(errors.isEmpty)
        #expect(e.names("") == ["IMG_1.CR2", "IMG_1.JPG", "IMG_1.xmp", "a"])
        #expect(e.names("a") == ["b"])
        #expect(e.names("a/b") == ["IMG_2.CR2", "IMG_2.JPG", "IMG_2.xmp"])
        #expect(try e.library.index.photo(key: "a/b/IMG_2") != nil)
        // "a" now holds only a subfolder: a group.
        #expect(try e.tree() == [AlbumNode(path: "a", name: "a", kind: .group, children: [
            AlbumNode(path: "a/b", name: "b", kind: .album, children: []),
        ])])
    }

    @Test func deleteAlbumKeepsFolderWithOtherFilesAndNeverTouchesTheRoot() async throws {
        let e = try Env()
        try addRawGroup(e.lib, "a")
        try e.lib.addFile("a/notes.txt", bytes: Data("keep".utf8))
        try e.lib.addJPEG("IMG_9.jpg")
        _ = await e.library.initialSync()
        #expect(await e.library.deleteAlbum("a").isEmpty)
        #expect(e.names("a") == ["notes.txt"])
        #expect(e.names("").contains("IMG_1.JPG"))
        #expect(await e.library.deleteAlbum("").isEmpty)
        #expect(e.exists("IMG_9.jpg") && e.exists("IMG_1.JPG"))
    }
}
