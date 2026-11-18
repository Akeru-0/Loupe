import Foundation
import Testing
import LoupeTestSupport
@testable import LoupeIndex

@Suite struct AlbumCatalogTests {
    @Test func albumOrderFollowsCatalog() {
        let catalog = AlbumCatalog(albums: [AlbumEntry(name: "B"), AlbumEntry(name: "A"), AlbumEntry(name: "Gone")])
        // Every catalog album (an empty one too), then unlisted known albums alphabetically.
        #expect(catalog.orderedNames(including: ["A", "B", "C"]) == ["B", "A", "Gone", "C"])
        #expect(AlbumCatalog(albums: [AlbumEntry(name: "B"), AlbumEntry(name: "A")])
            .orderedNames(including: ["A", "B", "C"]) == ["B", "A", "C"])
    }

    @Test func catalogRoundTripsAndRejectsCorrupt() throws {
        let lib = try TestLibrary()
        #expect(try AlbumCatalogIO.load(root: lib.root) == AlbumCatalog())
        let catalog = AlbumCatalog(albums: [AlbumEntry(name: "Trip", cover: "a/IMG_1"), AlbumEntry(name: "Z")])
        try AlbumCatalogIO.save(catalog, root: lib.root)
        #expect(try AlbumCatalogIO.load(root: lib.root) == catalog)
        try lib.addFile(".loupe/albums.json", bytes: Data("{oops".utf8))
        #expect(throws: AlbumCatalogError.corrupt) { try AlbumCatalogIO.load(root: lib.root) }
    }
}
