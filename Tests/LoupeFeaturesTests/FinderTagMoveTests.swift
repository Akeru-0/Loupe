import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeFeatures
@testable import LoupeIndex

/// The real Finder-tag store with a real library: tag removals and un-favorites made in Loupe must hold after
/// the photo was moved by Loupe (move, Rename Album, Delete Album give it a new id).
@Suite struct FinderTagMoveTests {
    private struct Env {
        let lib: TestLibrary
        let library: Library

        init() throws {
            lib = try TestLibrary()
            let support = FileManager.default.temporaryDirectory
                .appendingPathComponent("loupe-support-\(UUID().uuidString)")
            var registry = FeatureRegistry()
            registry.metadataStores = [FinderTagStore()]
            library = try Library(
                location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path),
                registry: registry, supportDirectory: support, cacheDirectory: support.appendingPathComponent("cache"))
        }

        func id(_ key: String) throws -> Int64 { try #require(try library.index.photo(key: key)).id! }

        /// IMG_1 in `a/`, tagged X and favorite through Loupe (so Finder carries both), plus an empty album `b/`.
        func prepare() async throws -> Int64 {
            try lib.addJPEG("a/IMG_1.jpg")
            try FileManager.default.createDirectory(at: lib.url("b"), withIntermediateDirectories: true)
            _ = await library.initialSync()
            let id = try id("a/IMG_1")
            #expect(await library.apply([.addTag("X"), .setFavorite(true)], to: [id]).isEmpty)
            return id
        }

        /// Removes X and the favorite in Loupe, then lets the watcher see Loupe's own sidecar write.
        func removeAndSettle(key: String, folder: String) async throws -> PhotoMetadata {
            let id = try id(key)
            #expect(await library.apply([.removeTag("X"), .setFavorite(false)], to: [id]).isEmpty)
            await library.handleFolderChanges([lib.url(folder)], rescanAll: false)
            await library.handleFolderChanges([lib.root], rescanAll: true)
            return try library.index.metadata(ofPhoto: try self.id(key))
        }
    }

    @Test func removalHoldsWithoutMove() async throws {
        let e = try Env()
        _ = try await e.prepare()
        let m = try await e.removeAndSettle(key: "a/IMG_1", folder: "a")
        #expect(m.tags.isEmpty)
        #expect(!m.isFavorite)
    }

    @Test func removalHoldsAfterMove() async throws {
        let e = try Env()
        let id = try await e.prepare()
        #expect(await e.library.move([id], toFolder: "b").isEmpty)
        let m = try await e.removeAndSettle(key: "b/IMG_1", folder: "b")
        #expect(m.tags.isEmpty)
        #expect(!m.isFavorite)
    }

    @Test func removalHoldsAfterRenameFolder() async throws {
        let e = try Env()
        _ = try await e.prepare()
        #expect(try await e.library.renameFolder("a", to: "c") == "c")
        let m = try await e.removeAndSettle(key: "c/IMG_1", folder: "c")
        #expect(m.tags.isEmpty)
        #expect(!m.isFavorite)
    }

    @Test func removalHoldsAfterDeleteAlbum() async throws {
        let e = try Env()
        _ = try await e.prepare()
        #expect(await e.library.deleteAlbum("a").isEmpty)
        let m = try await e.removeAndSettle(key: "IMG_1", folder: "")
        #expect(m.tags.isEmpty)
        #expect(!m.isFavorite)
    }
}
