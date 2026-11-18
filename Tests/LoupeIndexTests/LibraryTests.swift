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

@Suite(.serialized) final class StaleRevertGuardLibraryTests {
    private func sidecar(toolkit: String, rating: Int) -> Data {
        Data("""
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="\(toolkit)">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
           <xmp:Rating>\(rating)</xmp:Rating>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """.utf8)
    }

    /// A real external write lands well after Loupe's own; keep the mtime clear of the scanner's 1 ms tolerance.
    nonisolated(unsafe) private var clock = 10.0
    private func writeLater(_ e: Env, toolkit: String, rating: Int) throws {
        let url = e.lib.url("a/IMG_1.xmp")
        try sidecar(toolkit: toolkit, rating: rating).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(clock)], ofItemAtPath: url.path)
        clock += 10
    }

    private final class Logs: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [String] = []
        private var token: (any NSObjectProtocol)?
        init() {
            token = NotificationCenter.default.addObserver(forName: Library.didLog, object: nil, queue: nil) { [self] n in
                lock.lock(); _messages.append(n.userInfo?["message"] as? String ?? ""); lock.unlock()
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
        var restored: [String] { lock.lock(); defer { lock.unlock() }; return _messages.filter { $0.hasPrefix("Restored") } }
    }

    /// Loupe applies rating 4, then `toolkit` writes rating 0 to the sidecar; returns the env after the rescan.
    private func run(toolkit: String, rewrite: Int = 0) async throws -> (Env, Int64, Logs) {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        _ = await e.library.apply([.setRating(4)], to: [id])
        let logs = Logs()
        try writeLater(e, toolkit: toolkit, rating: rewrite)
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        return (e, id, logs)
    }

    @Test func libraryRestoresOnlyAfterLightCraftWrites() async throws {
        let (e, id, logs) = try await run(toolkit: "LightCraft")
        #expect(try e.sidecarText("a/IMG_1.xmp").contains("<xmp:Rating>4</xmp:Rating>"))
        #expect(try e.library.index.photo(id: id)?.rating == 4)
        #expect(logs.restored.count == 1)
        #expect(logs.restored.first?.contains("rating") == true)

        let (o, oid, otherLogs) = try await run(toolkit: "Other")
        #expect(try o.library.index.photo(id: oid)?.rating == 0)
        #expect(otherLogs.restored.isEmpty)
    }

    @Test func correctionDoesNotLoopAndStaysArmed() async throws {
        let (e, id, logs) = try await run(toolkit: "LightCraft")
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        await e.library.handleFolderChanges([e.lib.root], rescanAll: true)
        #expect(logs.restored.count == 1)
        // LightCraft reverts again on its next save: restored again.
        try writeLater(e, toolkit: "LightCraft", rating: 0)
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.library.index.photo(id: id)?.rating == 4)
        #expect(logs.restored.count == 2)
    }

    @Test func differentLightCraftValueWinsAndEntryIsDropped() async throws {
        let (e, id, logs) = try await run(toolkit: "LightCraft", rewrite: 2)
        #expect(try e.library.index.photo(id: id)?.rating == 2)
        #expect(logs.restored.isEmpty)
        // Entry is gone: a later stale 0 is not restored.
        try writeLater(e, toolkit: "LightCraft", rating: 0)
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.library.index.photo(id: id)?.rating == 0)
    }
}
