import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeIndex

@Suite struct FavoritesFolderTests {
    private struct Env {
        let lib: TestLibrary
        let library: Library
        var folder: FavoritesFolder { FavoritesFolder(index: library.index, root: lib.root) }

        init() throws {
            lib = try TestLibrary()
            let support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
            library = try Library(
                location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path),
                registry: FeatureRegistry(), supportDirectory: support,
                cacheDirectory: support.appendingPathComponent("cache"))
        }

        /// The folder's files, hidden ones too.
        func copies() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: lib.url("Favorites").path)) ?? []).sorted()
        }

        func text(_ path: String) -> String? { try? String(contentsOf: lib.url(path), encoding: .utf8) }

        func id(_ stem: String) throws -> Int64 {
            try #require(try library.index.allPhotos().first { $0.stem == stem }?.id)
        }

        /// Makes `path` look changed later than everything else.
        func touch(_ path: String, _ text: String, secondsAhead: Double = 10) throws {
            try Data(text.utf8).write(to: lib.url(path))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(secondsAhead)],
                                                  ofItemAtPath: lib.url(path).path)
        }
    }

    @Test func favoritesAreCopiedWithAllTheirFilesAndSameNamesKeptApart() async throws {
        let e = try Env()
        try e.lib.addFakeRaw("Trip/IMG_1.CR2")
        try e.lib.addJPEG("Trip/IMG_1.JPG")
        try e.lib.addSidecar("Trip/IMG_1.xmp", tags: ["Favorite"])
        try e.lib.addJPEG("Photos/IMG_1.JPG")  // the same name, another day
        try e.lib.addSidecar("Photos/IMG_1.xmp", tags: ["Favorite"])
        try e.lib.addJPEG("IMG_2.JPG")  // not a favorite
        _ = await e.library.initialSync()

        let report = try e.folder.sync()
        #expect(report.copied == 5 && report.failures.isEmpty)
        let copies = e.copies()
        #expect(copies.filter { $0.hasPrefix("IMG_1.") }.count + copies.filter { $0.hasPrefix("IMG_1 (2).") }.count == 5)
        #expect(Set(copies.map { ($0 as NSString).pathExtension.uppercased() }) == ["CR2", "JPG", "XMP"])
        #expect(!copies.contains { $0.hasPrefix("IMG_2") })
        // Byte for byte the originals.
        #expect(try Data(contentsOf: e.lib.url("Favorites/IMG_1.CR2")) == Data(contentsOf: e.lib.url("Trip/IMG_1.CR2")))

        // The folder is never indexed: still three photos, and not an album.
        _ = await e.library.initialSync()
        #expect(try e.library.index.allPhotos().count == 3)
        #expect(try e.library.index.albumTree(root: e.lib.root, settings: LibrarySettings(rootPath: e.lib.root.path))
            .map(\.path).sorted() == ["Photos", "Trip"])
        #expect(try e.folder.sync() == FavoritesFolder.Report())  // nothing to do
    }

    @Test func changesGoBothWaysAndEditsSurviveUnfavoriting() async throws {
        let e = try Env()
        try e.lib.addJPEG("Trip/IMG_1.JPG")
        try e.lib.addSidecar("Trip/IMG_1.xmp", tags: ["Favorite"])
        _ = await e.library.initialSync()
        _ = try e.folder.sync()

        // Changed in the library: the copy follows.
        try e.touch("Trip/IMG_1.xmp", "library edit")
        #expect(try e.folder.sync().copied == 1)
        #expect(e.text("Favorites/IMG_1.xmp") == "library edit")

        // Edited in the folder (an editor wrote the sidecar) and a new version saved there: both go back.
        try e.touch("Favorites/IMG_1.xmp", "editor edit", secondsAhead: 20)
        try e.lib.addJPEG("Favorites/IMG_1-edited.jpg")
        try e.lib.addFile("Favorites/notes.txt", bytes: Data("mine".utf8))  // not a photo's: left alone
        let back = try e.folder.sync()
        #expect(back.copiedBack == 2)
        #expect(e.text("Trip/IMG_1.xmp") == "editor edit")
        #expect(FileManager.default.fileExists(atPath: e.lib.url("Trip/IMG_1-edited.jpg").path))

        // Both changed: the newer wins.
        try e.touch("Trip/IMG_1.xmp", "older", secondsAhead: 30)
        try e.touch("Favorites/IMG_1.xmp", "newer", secondsAhead: 40)
        _ = try e.folder.sync()
        #expect(e.text("Trip/IMG_1.xmp") == "newer")

        // No longer a favorite: its copies go (the edit is in the library), the user's own file stays.
        try e.touch("Trip/IMG_1.xmp", "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>", secondsAhead: 50)
        _ = await e.library.initialSync()
        let removed = try e.folder.sync()
        #expect(removed.removed == 3)
        #expect(e.copies() == ["notes.txt"])
        #expect(FileManager.default.fileExists(atPath: e.lib.url("Trip/IMG_1-edited.jpg").path))
    }

    @Test func aMovedPhotoIsNotBroughtBackAndHiddenOrDeletedOnesGo() async throws {
        let e = try Env()
        try e.lib.addJPEG("Trip/IMG_1.JPG")
        try e.lib.addSidecar("Trip/IMG_1.xmp", tags: ["Favorite"])
        try e.lib.addJPEG("Trip/IMG_3.JPG")
        try e.lib.addSidecar("Trip/IMG_3.xmp", tags: ["Favorite"])
        _ = await e.library.initialSync()
        _ = try e.folder.sync()
        #expect(e.copies().count == 4)

        // Moved to another album: the copy follows it under the same name, nothing comes back to Trip.
        try FileManager.default.createDirectory(at: e.lib.url("Iceland"), withIntermediateDirectories: true)
        let moved = await e.library.move([try e.id("IMG_1")], toFolder: "Iceland")
        #expect(moved.isEmpty, "\(moved)")
        _ = try e.folder.sync()
        #expect(!FileManager.default.fileExists(atPath: e.lib.url("Trip/IMG_1.JPG").path))
        #expect(e.copies().filter { $0.hasPrefix("IMG_1") } == ["IMG_1.JPG", "IMG_1.xmp"])

        // Hidden: out of the folder too.
        let hidden = await e.library.apply([.setHidden(true)], to: [try e.id("IMG_3")])
        #expect(hidden.isEmpty)
        _ = try e.folder.sync()
        #expect(!e.copies().contains { $0.hasPrefix("IMG_3") })
    }

    @Test func onlyTheTopFavoritesFolderIsSkipped() async throws {
        let e = try Env()
        try e.lib.addJPEG("Favorites/IMG_9.JPG")  // Loupe's folder
        try e.lib.addJPEG("Trips/Favorites/IMG_8.JPG")  // an album of the user's that happens to be called that
        _ = await e.library.initialSync()
        #expect(try e.library.index.allPhotos().map(\.stem) == ["IMG_8"])
    }
}
