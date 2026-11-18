import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeIndex

private final class RecordingStore: MetadataStore, @unchecked Sendable {
    let id = "recording"
    private let lock = NSLock()
    private var _pushes = 0
    private var scripted: [[MetadataChange]] = []
    private var _pushedFiles: [[URL]] = []
    var pushes: Int { lock.lock(); defer { lock.unlock() }; return _pushes }
    var pushedFiles: [[URL]] { lock.lock(); defer { lock.unlock() }; return _pushedFiles }
    func script(_ changes: [MetadataChange]) { lock.lock(); scripted.append(changes); lock.unlock() }
    func push(_ metadata: PhotoMetadata, files: [URL], lastState: Data?) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        _pushes += 1
        _pushedFiles.append(files)
        return Data("state".utf8)
    }
    func pull(files: [URL], lastState: Data?) throws -> [MetadataChange] {
        lock.lock(); defer { lock.unlock() }
        return scripted.isEmpty ? [] : scripted.removeFirst()
    }
}

private struct Env {
    let lib: TestLibrary
    let library: Library
    let store = RecordingStore()
    let support: URL

    init() throws {
        lib = try TestLibrary()
        support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
        var registry = FeatureRegistry()
        let store = self.store
        registry.metadataStores = [store]
        library = try Library(
            location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path),
            registry: registry, supportDirectory: support, cacheDirectory: support.appendingPathComponent("cache"))
    }

    func id(_ key: String) throws -> Int64 { try #require(try library.index.photo(key: key)).id! }
    func sidecarText(_ path: String) throws -> String { try String(contentsOf: lib.url(path), encoding: .utf8) }
    func sidecarDate(_ path: String) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: lib.url(path).path)[.modificationDate] as? Date)
    }
}

@Suite struct LibraryTests {
    @Test func applyWritesSidecarAndIndex() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        let errors = await e.library.apply([.setRating(4), .addTag("Iceland")], to: [id])
        #expect(errors.isEmpty)
        let text = try e.sidecarText("a/IMG_1.xmp")
        #expect(text.contains("Iceland"))
        #expect(text.contains("4"))
        #expect(try e.library.index.photo(id: id)?.rating == 4)
        #expect(try e.library.index.metadata(ofPhoto: id).tags == ["Iceland"])
        #expect(e.store.pushedFiles.last?.allSatisfy { $0.pathExtension != "xmp" } == true)
    }

    @Test func applyReportsPerPhotoFailures() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/bad.jpg")
        try e.lib.addJPEG("a/good.jpg")
        let junk = Data("this is not xml <<<".utf8)
        try e.lib.addFile("a/bad.xmp", bytes: junk)
        _ = await e.library.initialSync()
        let bad = try e.id("a/bad"), good = try e.id("a/good")
        let errors = await e.library.apply([.setRating(2)], to: [bad, good])
        #expect(Set(errors.keys) == [bad])
        #expect(try Data(contentsOf: e.lib.url("a/bad.xmp")) == junk)
        #expect(try e.sidecarText("a/good.xmp").contains("2"))
        #expect(try e.library.index.photo(id: good)?.rating == 2)
    }

    @Test func externalSidecarEditIsReloaded() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addSidecar("a/IMG_1.xmp", rating: 1)
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        #expect(try e.library.index.photo(id: id)?.rating == 1)
        try await Task.sleep(for: .milliseconds(1100))
        try e.lib.addSidecar("a/IMG_1.xmp", rating: 5)
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.library.index.photo(id: id)?.rating == 5)
    }

    @Test func ownWritesDoNotLoop() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        let base = e.store.pushes
        _ = await e.library.apply([.setRating(3)], to: [id])
        let stamp = try e.sidecarDate("a/IMG_1.xmp")
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        await e.library.handleFolderChanges([e.lib.root], rescanAll: true)
        #expect(try e.sidecarDate("a/IMG_1.xmp") == stamp)
        #expect(e.store.pushes == base + 1)
        #expect(try e.library.index.photo(id: id)?.rating == 3)
    }

    @Test func storeChangesFlowIntoXMP() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        e.store.script([.addTag("FromStore")])
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.sidecarText("a/IMG_1.xmp").contains("FromStore"))
        #expect(try e.library.index.metadata(ofPhoto: try e.id("a/IMG_1")).tags == ["FromStore"])
    }

    @Test func applyToVanishedPhotoFailsCleanly() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addJPEG("a/keep.jpg")
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        try e.lib.remove("a/IMG_1.jpg")
        let errors = await e.library.apply([.setRating(2)], to: [id])
        #expect(Set(errors.keys) == [id])
        #expect(!FileManager.default.fileExists(atPath: e.lib.url("a/IMG_1.xmp").path))
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.library.index.photo(key: "a/IMG_1") == nil)
        #expect(try e.library.index.photo(key: "a/keep") != nil)
    }

    @Test func unreadableRootKeepsIndex() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        let moved = e.lib.root.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: e.lib.root, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: e.lib.root) }
        await e.library.handleFolderChanges([e.lib.root], rescanAll: true)
        #expect(try e.library.index.photo(key: "a/IMG_1") != nil)
    }
}
