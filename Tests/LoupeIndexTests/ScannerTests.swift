import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeIndex

private struct Env {
    let lib: TestLibrary
    let dbURL: URL
    let index: LibraryIndex
    let scanner: LoupeIndex.Scanner

    init(lib: TestLibrary? = nil) throws {
        self.lib = try lib ?? TestLibrary()
        dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-idx-\(UUID().uuidString).sqlite")
        index = try LibraryIndex(databaseURL: dbURL)
        scanner = LoupeIndex.Scanner(
            index: index, location: LocalFolderLocation(rootURL: self.lib.root),
            settings: LibrarySettings(rootPath: self.lib.root.path))
    }

    func versions(_ key: String) throws -> [VersionRecord] {
        let p = try #require(try index.photo(key: key))
        return try index.versions(ofPhoto: p.id!)
    }

    func snapshot() throws -> [String] {
        try index.allPhotos().map { p in
            let m = try index.metadata(ofPhoto: p.id!)
            let paths = try index.versions(ofPhoto: p.id!).map { "\($0.kind.rawValue):\($0.path)" }
            return "\(p.key)|\(p.rating)|\(m.tags)|\(m.albums)|\(paths)"
        }.sorted()
    }
}

@Suite struct ScannerTests {
    @Test func indexesTreeAndSkipsExcluded() async throws {
        let e = try Env()
        try e.lib.addFakeRaw("a/IMG_1.CR2")
        try e.lib.addJPEG("a/IMG_1.JPG")
        try e.lib.addJPEG("b/x.png")
        try e.lib.addJPEG(".hidden/y.jpg")
        try e.lib.addJPEG("Test.photoslibrary/z.jpg")
        try e.lib.addJPEG("LightCraft Library/thumbs/t.jpg")
        try e.lib.addFile("notes.txt", bytes: Data("hi".utf8))
        let report = try await e.scanner.fullScan()
        #expect(report.added == 2)
        #expect(try e.index.allPhotos().map(\.key) == ["a/IMG_1", "b/x"])
        let a = try #require(try e.index.photo(key: "a/IMG_1"))
        #expect(a.hasRaw)
        #expect(try e.versions("a/IMG_1").map(\.kind) == [.raw, .jpeg])
    }

    @Test func metadataComesFromSidecar() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addSidecar("a/IMG_1.xmp", rating: 3, tags: ["Iceland"], albums: ["Trip"])
        _ = try await e.scanner.fullScan()
        let p = try #require(try e.index.photo(key: "a/IMG_1"))
        #expect(p.rating == 3)
        let m = try e.index.metadata(ofPhoto: p.id!)
        #expect(m.tags == ["Iceland"])
        #expect(m.albums == ["Trip"])
        #expect(p.sidecarModified != nil)
    }

    @Test func rescanPicksUpEditAndDeletion() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addJPEG("b/x.png")
        _ = try await e.scanner.fullScan()
        try e.lib.addJPEG("a/IMG_1-edited.jpg")
        let r1 = try await e.scanner.rescan(folder: "a")
        #expect(r1.updated == 1)
        let vs = try e.versions("a/IMG_1")
        #expect(vs.map(\.kind) == [.jpeg, .edit])
        #expect(vs.first { $0.isDisplay }?.kind == .edit)
        try e.lib.remove("b/x.png")
        let r2 = try await e.scanner.rescan(folder: "b")
        #expect(r2.removed == 1)
        #expect(try e.index.photo(key: "b/x") == nil)
    }

    @Test func fullScanRemovesPhotosOfDeletedFolders() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/one.jpg")
        try e.lib.addJPEG("b/two.jpg")
        _ = try await e.scanner.fullScan()
        try e.lib.remove("b")
        let r = try await e.scanner.fullScan()
        #expect(r.removed == 1)
        #expect(try e.index.allPhotos().map(\.key) == ["a/one"])
    }

    @Test func rebuildFromDiskIsIdentical() async throws {
        let e1 = try Env()
        try e1.lib.addFakeRaw("a/IMG_1.CR2")
        try e1.lib.addJPEG("a/IMG_1.JPG")
        try e1.lib.addJPEG("a/IMG_1-edited.jpg")
        try e1.lib.addSidecar("a/IMG_1.xmp", rating: 4, tags: ["x", "y"], albums: ["Trip"])
        try e1.lib.addJPEG("b/x.png")
        try e1.lib.addJPEG("root.jpg")
        let e2 = try Env(lib: e1.lib)
        _ = try await e1.scanner.fullScan()
        _ = try await e2.scanner.fullScan()
        #expect(try e1.snapshot() == e2.snapshot())
        #expect(try e1.snapshot().count == 3)
    }

    @Test func unchangedFilesAreNotReread() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addSidecar("a/IMG_1.xmp", rating: 2)
        let first = try await e.scanner.fullScan()
        #expect(first.added == 1)
        let second = try await e.scanner.fullScan()
        #expect(second.added == 0 && second.updated == 0 && second.removed == 0)
        #expect(second.scannedPhotoIDs.isEmpty)
        // Dates are stored as exact doubles, so sub-millisecond mtimes compare equal.
        let types = try await e.index.dbPool.read { try String.fetchAll($0, sql: "SELECT typeof(modified) FROM version") }
        #expect(types == ["real"])
    }

    @Test func oddNamesSurvive() async throws {
        let e = try Env()
        let odd = "Screan shots:recording/Screenshot 2026-01-01 at 10.00.00 AM (2).png"
        let nfd = "Zlut/Z\u{030C}luti\u{0301}.jpg"  // NFD: Z + caron, i + acute
        try e.lib.addJPEG(odd)
        try e.lib.addJPEG(nfd)
        let r = try await e.scanner.fullScan()
        #expect(r.failed.isEmpty)
        #expect(try e.index.photo(key: "Screan shots:recording/Screenshot 2026-01-01 at 10.00.00 AM (2)") != nil)
        #expect(try e.index.photo(key: "Zlut/Z\u{030C}luti\u{0301}") != nil)
        #expect(try e.index.photo(key: "Zlut/\u{017D}lut\u{00ED}") != nil)  // NFC lookup finds it too
        let v = try e.versions("Zlut/Z\u{030C}luti\u{0301}")
        #expect(FileManager.default.fileExists(atPath: v[0].url(in: e.lib.root).path))
    }

    @Test func unreadableFilesAreNotFatal() async throws {
        let e = try Env()
        try e.lib.addFile("broken.jpg")  // 0 bytes
        try e.lib.addFile("junk.mov", bytes: Data("not a movie".utf8))
        try e.lib.addJPEG("c/good.jpg")
        let bad = try e.lib.addFile("c/good.xmp", bytes: Data("<x:xmpmeta><rdf:Description><xmp:Rating>3".utf8))
        let before = try Data(contentsOf: bad)
        let r = try await e.scanner.fullScan()
        #expect(try e.index.photo(key: "broken") != nil)
        #expect(try e.index.photo(key: "junk") != nil)
        let good = try #require(try e.index.photo(key: "c/good"))
        #expect(good.rating == 0)
        #expect(r.failed == ["c/good.xmp"])
        #expect(try Data(contentsOf: bad) == before)
    }

    @Test func lightCraftExportNamedLikeRawIsEdit() async throws {
        let e = try Env()
        try e.lib.addFakeRaw("a/IMG_1.CR2")
        try e.lib.addJPEG("a/IMG_1.jpg", creatorTool: "LightCraft 1.0")
        _ = try await e.scanner.fullScan()
        let vs = try e.versions("a/IMG_1")
        #expect(vs.map(\.kind) == [.raw, .edit])
        #expect(vs.first { $0.isDisplay }?.kind == .edit)
        #expect(try e.index.allPhotos().count == 1)
    }

    @Test func cameraJpegNextToRawStaysJpeg() async throws {
        let e = try Env()
        try e.lib.addFakeRaw("a/IMG_1.CR2")
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = try await e.scanner.fullScan()
        #expect(try e.versions("a/IMG_1").map(\.kind) == [.raw, .jpeg])
    }

    // MARK: - Fix round 1

    @Test func missingRootThrowsAndKeepsIndex() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/one.jpg")
        try e.lib.addJPEG("b/two.jpg")
        _ = try await e.scanner.fullScan()
        try FileManager.default.removeItem(at: e.lib.root)
        await #expect(throws: (any Error).self) { _ = try await e.scanner.fullScan() }
        await #expect(throws: (any Error).self) { _ = try await e.scanner.rescan(folder: "a") }
        #expect(try e.index.allPhotos().count == 2)
    }

    @Test func unreadableSubfolderKeepsItsPhotos() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/one.jpg")
        try e.lib.addJPEG("b/two.jpg")
        try e.lib.addJPEG("b/deep/three.jpg")
        _ = try await e.scanner.fullScan()
        let b = e.lib.url("b").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: b)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b) }
        _ = try? await e.scanner.fullScan()
        await #expect(throws: (any Error).self) { _ = try await e.scanner.rescan(folder: "b") }
        #expect(try e.index.allPhotos().map(\.key) == ["a/one", "b/two", "b/deep/three"])
    }

    @Test func rescanHonoursExclusionHiddenAndPackageRules() async throws {
        let e = try Env()
        try e.lib.addJPEG("Test.photoslibrary/sub/z.jpg")
        try e.lib.addJPEG("LightCraft Library/thumbs/t.jpg")
        try e.lib.addJPEG(".hidden/y.jpg")
        try e.lib.addJPEG("ok/in.jpg")
        for f in ["Test.photoslibrary/sub", "Test.photoslibrary", "LightCraft Library/thumbs", "LightCraft Library", ".hidden"] {
            _ = try await e.scanner.rescan(folder: f)
        }
        #expect(try e.index.allPhotos().isEmpty)
        _ = try await e.scanner.rescan(folder: "ok")
        #expect(try e.index.allPhotos().count == 1)
    }

    @Test func rescanCanonicalisesFolderSpelling() async throws {
        let e = try Env()
        let nfd = "Z\u{030C}lu\u{0074}\u{030C}"
        let nfc = "\u{017D}lu\u{0165}"
        try e.lib.addJPEG("\(nfd)/a.jpg")
        _ = try await e.scanner.fullScan()
        _ = try await e.scanner.rescan(folder: nfc)
        _ = try await e.scanner.rescan(folder: nfd + "/")
        _ = try await e.scanner.rescan(folder: nfc + "/")
        #expect(try e.index.allPhotos().count == 1)
        #expect(try e.index.photo(key: "\(nfc)/a") != nil)
        #expect(try e.index.photo(key: "\(nfd)/a") != nil)
        let before = try e.snapshot()
        _ = try await e.scanner.fullScan()
        #expect(try e.index.allPhotos().count == 1)
        let fresh = try Env(lib: e.lib)
        _ = try await fresh.scanner.fullScan()
        #expect(try e.snapshot() == fresh.snapshot())
        #expect(before == (try e.snapshot()))
    }

    @Test func legacySidecarChangesAreDetected() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addSidecar("a/IMG_1.jpg.xmp", rating: 2)
        _ = try await e.scanner.fullScan()
        #expect(try e.index.photo(key: "a/IMG_1")?.rating == 2)
        try e.lib.addSidecar("a/IMG_1.jpg.xmp", rating: 4)
        _ = try await e.scanner.rescan(folder: "a")
        #expect(try e.index.photo(key: "a/IMG_1")?.rating == 4)
        try e.lib.remove("a/IMG_1.jpg.xmp")
        _ = try await e.scanner.rescan(folder: "a")
        #expect(try e.index.photo(key: "a/IMG_1")?.rating == 0)
    }
}
