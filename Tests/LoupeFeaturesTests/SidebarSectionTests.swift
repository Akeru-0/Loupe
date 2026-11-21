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
        try lib.addJPEG("Photos/IMG_7.jpg")  // where imports go: photos, not an album
        try lib.addJPEG("Photos/2026/IMG_8.jpg")
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
        // Folders are albums now: no separate "Folders" section, no keyword albums.
        #expect(sections.map(\.title) == [nil, "Media Types", "Utilities", "Albums", "Tags"])
        let items = try sections.map { try $0.items(index: index, root: lib.root, settings: settings) }
        try #require(items.count == 5)
        #expect(items[1].isEmpty)  // plain 40x30 JPEGs: no videos, panoramas or RAW, so nothing is listed
        // Utilities are always listed; no duplicate check has run, so Duplicates has no count.
        #expect(items[2].map(\.title) == ["People", "Recently Edited", "Duplicates", "Imports", "Hidden", "Recently Deleted"])
        #expect(items[2].map(\.scope) == [.people, .recentlyEdited(days: 30), .duplicates, .imports, .hidden, .recentlyDeleted])
        #expect(items[2].map(\.systemImage) == ["person.crop.square", "slider.horizontal.3", "square.on.square", "square.and.arrow.down", "eye.slash", "trash"])
        #expect(items[2].map(\.badge) == [nil, nil, nil, nil, nil, nil])  // nobody found yet; no failed uploads
        #expect(items[2].allSatisfy { $0.dropTarget == nil })

        let library = items[0]
        #expect(library.map(\.title) == ["Library", "Favorites", "Recently Added"])
        #expect(library.map(\.scope) == [.all, .favorites, .recentlyAdded(days: 30)])
        #expect(library.map(\.systemImage) == ["photo.on.rectangle", "heart", "clock"])
        #expect(library.map(\.dropTarget) == [nil, nil, nil])
        #expect(library.allSatisfy { $0.children.isEmpty })

        // The real folder tree: a folder with photos (or an empty one) is an album, a folder with only subfolders
        // is a group. Hidden, package and excluded folders are skipped; ":" on disk shows as "/".
        let albums = items[3]
        #expect(albums.map(\.title) == ["Empty", "Screen shots/recording", "Trip"])  // no Photos
        #expect(albums.map(\.scope) == [.folderTree("Empty"), .folder("Screen shots:recording"), .folder("Trip")])
        #expect(albums.map(\.dropTarget) == [nil, .folder("Screen shots:recording"), .folder("Trip")])
        #expect(albums.map(\.systemImage) == ["folder", "rectangle.stack", "rectangle.stack"])
        try #require(albums.count == 3)
        #expect(albums[0].children.map(\.title) == ["Nested"])
        #expect(albums[0].children.map(\.scope) == [.folder("Empty/Nested")])
        #expect(albums[0].children.map(\.dropTarget) == [.folder("Empty/Nested")])
        #expect(albums[0].children.map(\.systemImage) == ["rectangle.stack"])
        #expect(albums[1].children.isEmpty)
        #expect(albums[2].children.map(\.title) == ["Day 1"])
        #expect(albums[2].children.map(\.dropTarget) == [.folder("Trip/Day 1")])

        let tags = items[4]
        #expect(tags.map(\.title) == ["Beach", "Iceland"])
        #expect(tags.map(\.scope) == [.tag("Beach"), .tag("Iceland")])
        #expect(tags.allSatisfy { $0.systemImage == "tag" && $0.dropTarget == nil })

        func flatten(_ items: [SidebarItem]) -> [SidebarItem] { items.flatMap { [$0] + flatten($0.children) } }
        let all = flatten(items.flatMap { $0 })
        // Keyword albums ("Albums|…" in the sidecar, the catalog) stay in the files but are not shown.
        #expect(!all.contains { ["Zebra", "Gone", "Alpha", "Middle"].contains($0.title) })
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func mediaTypesListOnlyWhatTheLibraryHas() async throws {
        let lib = try TestLibrary()
        let fm = FileManager.default
        try lib.addJPEG("pano.jpg", width: 3000, height: 1000)
        try lib.addJPEG("IMG_1.jpg")
        _ = try lib.addFakeRaw("IMG_1.cr2")
        let settings = LibrarySettings(rootPath: lib.root.path)
        let dbURL = fm.temporaryDirectory.appendingPathComponent("loupe-sidebar-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: dbURL.path + suffix) } }
        let index = try LibraryIndex(databaseURL: dbURL)
        _ = try await LoupeIndex.Scanner(index: index, location: LocalFolderLocation(rootURL: lib.root), settings: settings)
            .fullScan()
        var registry = FeatureRegistry()
        SidebarFeature.register(in: &registry)
        let section = try #require(registry.sidebarSections.first { $0.title == "Media Types" })
        let items = try section.items(index: index, root: lib.root, settings: settings)
        // No videos here: Videos is hidden.
        #expect(items.map(\.title) == ["Panoramas", "RAW"])
        #expect(items.map(\.scope) == [.mediaType(.panoramas), .mediaType(.raw)])
        #expect(items.map(\.systemImage) == ["pano", "camera.aperture"])
        #expect(items.allSatisfy { $0.dropTarget == nil })
    }

    @Test func duplicatesShowTheirCount() async throws {
        let lib = try TestLibrary()
        let fm = FileManager.default
        try lib.addFile("a/IMG_1.jpg", bytes: Data(repeating: 1, count: 50))
        try lib.addFile("b/IMG_1.jpg", bytes: Data(repeating: 1, count: 50))
        try lib.addFile("a/IMG_2.jpg", bytes: Data(repeating: 2, count: 60))
        try lib.addFile("c/IMG_2.jpg", bytes: Data(repeating: 2, count: 60))
        let settings = LibrarySettings(rootPath: lib.root.path, recentlyAddedDays: 7)
        let dbURL = fm.temporaryDirectory.appendingPathComponent("loupe-sidebar-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: dbURL.path + suffix) } }
        let index = try LibraryIndex(databaseURL: dbURL)
        _ = try await LoupeIndex.Scanner(index: index, location: LocalFolderLocation(rootURL: lib.root), settings: settings)
            .fullScan()
        try await DuplicateIndex(index: index, root: lib.root).refresh()
        var registry = FeatureRegistry()
        SidebarFeature.register(in: &registry)
        let section = try #require(registry.sidebarSections.first { $0.title == "Utilities" })
        let items = try section.items(index: index, root: lib.root, settings: settings)
        #expect(items.map(\.scope) == [.people, .recentlyEdited(days: 7), .duplicates, .imports, .hidden, .recentlyDeleted])  // Recently Added's window
        #expect(items.map(\.badge) == [nil, nil, 2, nil, nil, nil])
    }
}
