import Foundation
import Testing
import LoupeCore
import LoupeIndex
import LoupeTestSupport
@testable import LoupeFeatures

@Suite struct SidebarSectionTests {
    @Test func builtInSectionsForTestLibrary() async throws {
        let lib = try TestLibrary()
        let fm = FileManager.default
        try lib.addJPEG("IMG_0.jpg")
        try lib.addJPEG("Trip/IMG_1.jpg")
        try lib.addSidecar("Trip/IMG_1.xmp", tags: ["Iceland", "Beach"], albums: ["Zebra", "Alpha", "Middle"])
        try lib.addJPEG("Trip/Day 1/IMG_2.jpg")
        try fm.createDirectory(at: lib.url("Empty/Nested"), withIntermediateDirectories: true)
        try lib.addJPEG("Screen shots:recording/IMG_3.jpg")
        try lib.addJPEG(".hidden/IMG_4.jpg")
        try lib.addJPEG("Old.photoslibrary/IMG_5.jpg")
        try lib.addJPEG("LightCraft Library/thumbs/t.jpg")
        try lib.addJPEG("Trip/Skip Me/IMG_6.jpg")
        try AlbumCatalogIO.save(
            AlbumCatalog(albums: [AlbumEntry(name: "Zebra"), AlbumEntry(name: "Gone"), AlbumEntry(name: "Alpha")]),
            root: lib.root)

        var settings = LibrarySettings(rootPath: lib.root.path)
        settings.excludedFolderNames.append("skip me")  // matched like the scanner: case-insensitive
        let dbURL = fm.temporaryDirectory.appendingPathComponent("loupe-sidebar-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: dbURL.path + suffix) } }
        let index = try LibraryIndex(databaseURL: dbURL)
        _ = try await LoupeIndex.Scanner(index: index, location: LocalFolderLocation(rootURL: lib.root), settings: settings)
            .fullScan()

        var registry = FeatureRegistry()
        SidebarFeature.register(in: &registry)
        let sections = registry.sidebarSections.sorted { $0.order < $1.order }
        #expect(sections.map(\.title) == [nil, "Albums", "Tags", "Folders"])
        let items = try sections.map { try $0.items(index: index, root: lib.root, settings: settings) }
        try #require(items.count == 4)

        let library = items[0]
        #expect(library.map(\.title) == ["Library", "Favorites", "Recently Added"])
        #expect(library.map(\.scope) == [.all, .favorites, .recentlyAdded(days: 30)])
        #expect(library.map(\.systemImage) == ["photo.on.rectangle", "heart", "clock"])
        #expect(library.allSatisfy { $0.dropTarget == nil && $0.children.isEmpty })

        // Every catalog album in catalog order (an empty one too), then the index's other albums alphabetically.
        let albums = items[1]
        #expect(albums.map(\.title) == ["Zebra", "Gone", "Alpha", "Middle"])
        #expect(albums.map(\.scope) == [.album("Zebra"), .album("Gone"), .album("Alpha"), .album("Middle")])
        #expect(albums.map(\.dropTarget) == [.album("Zebra"), .album("Gone"), .album("Alpha"), .album("Middle")])
        #expect(albums.allSatisfy { $0.systemImage == "rectangle.stack" })

        let tags = items[2]
        #expect(tags.map(\.title) == ["Beach", "Iceland"])
        #expect(tags.map(\.scope) == [.tag("Beach"), .tag("Iceland")])
        #expect(tags.allSatisfy { $0.systemImage == "tag" && $0.dropTarget == nil })

        // The root (its own photos), then the real tree: empty folders included; hidden, package and excluded
        // folders skipped; ":" on disk shows as "/".
        let folders = items[3]
        #expect(folders.map(\.title)
            == [fm.displayName(atPath: lib.root.path), "Empty", "Screen shots/recording", "Trip"])
        #expect(folders.map(\.scope)
            == [.folder(""), .folder("Empty"), .folder("Screen shots:recording"), .folder("Trip")])
        #expect(folders.map(\.dropTarget)
            == [.folder(""), .folder("Empty"), .folder("Screen shots:recording"), .folder("Trip")])
        try #require(folders.count == 4)
        #expect(folders[0].children.isEmpty)
        #expect(folders[1].children.map(\.title) == ["Nested"])
        #expect(folders[1].children.map(\.scope) == [.folder("Empty/Nested")])
        #expect(folders[3].children.map(\.title) == ["Day 1"])
        #expect(folders[3].children.map(\.dropTarget) == [.folder("Trip/Day 1")])

        func flatten(_ items: [SidebarItem]) -> [SidebarItem] { items.flatMap { [$0] + flatten($0.children) } }
        let all = flatten(items.flatMap { $0 })
        #expect(flatten(folders).allSatisfy { $0.systemImage == "folder" })
        #expect(Set(all.map(\.id)).count == all.count)
    }
}
