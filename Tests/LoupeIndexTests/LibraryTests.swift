import CoreServices
import Foundation
import Testing
import GRDB
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

    @Test func stoppedLibraryIgnoresFolderChanges() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try e.lib.addSidecar("a/IMG_1.xmp", rating: 1)
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        let pushes = e.store.pushes
        await e.library.stop()
        try await Task.sleep(for: .milliseconds(1100))
        try e.lib.addSidecar("a/IMG_1.xmp", rating: 5)
        let sidecar = try Data(contentsOf: e.lib.url("a/IMG_1.xmp"))
        try e.lib.addJPEG("a/IMG_2.jpg")
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        await e.library.handleFolderChanges([e.lib.root], rescanAll: true)
        #expect(try e.library.index.photo(id: id)?.rating == 1)
        #expect(try e.library.index.photo(key: "a/IMG_2") == nil)
        #expect(try Data(contentsOf: e.lib.url("a/IMG_1.xmp")) == sidecar)
        #expect(e.store.pushes == pushes)
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

    @Test func unrelatedRescanDoesNotResolveEntries() async throws {
        let (e, id, logs) = try await run(toolkit: "LightCraft")
        #expect(logs.restored.count == 1)
        try e.lib.addJPEG("a/IMG_1-edited.jpg")
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        try writeLater(e, toolkit: "LightCraft", rating: 0)
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.library.index.photo(id: id)?.rating == 4)
        #expect(logs.restored.count == 2)
    }

    @Test func applyBeforeWatcherDoesNotHideStaleRevert() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        _ = await e.library.apply([.setRating(4)], to: [id])
        let logs = Logs()
        try writeLater(e, toolkit: "LightCraft", rating: 0)
        _ = await e.library.apply([.addTag("x")], to: [id])
        let m = try e.library.index.metadata(ofPhoto: id)
        #expect(m.rating == 4)
        #expect(m.tags == ["x"])
        #expect(try e.sidecarText("a/IMG_1.xmp").contains("<xmp:Rating>4</xmp:Rating>"))
        #expect(logs.restored.count == 1)
    }

    @Test func otherWriterChangeWinsAgainstLaterLightCraftSave() async throws {
        let (e, id, logs) = try await run(toolkit: "Other")  // Loupe 4, another app sets 0
        try writeLater(e, toolkit: "LightCraft", rating: 0)  // LightCraft's stale catalog value
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.library.index.photo(id: id)?.rating == 0)
        #expect(logs.restored.isEmpty)
    }

    @Test func otherWriterKeepingOurValueLeavesEntryArmed() async throws {
        let (e, id, logs) = try await run(toolkit: "Other", rewrite: 4)
        try writeLater(e, toolkit: "LightCraft", rating: 0)
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.library.index.photo(id: id)?.rating == 4)
        #expect(logs.restored.count == 1)
    }

    private func pendingFields(_ e: Env, _ id: Int64) async throws -> [String] {
        try await e.library.index.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT field FROM pending_edit WHERE photoId = ? ORDER BY field", arguments: [id])
        }
    }

    @Test func pendingEditsFollowAMovedPhoto() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        try FileManager.default.createDirectory(at: e.lib.url("b"), withIntermediateDirectories: true)
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        _ = await e.library.apply([.setRating(4)], to: [id])
        #expect(try await pendingFields(e, id) == ["rating"])
        #expect(await e.library.move([id], toFolder: "b").isEmpty)
        let newID = try e.id("b/IMG_1")
        #expect(newID != id)
        #expect(try await pendingFields(e, newID) == ["rating"])

        let logs = Logs()
        let url = e.lib.url("b/IMG_1.xmp")
        try sidecar(toolkit: "LightCraft", rating: 0).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        await e.library.handleFolderChanges([e.lib.url("b")], rescanAll: false)
        #expect(try e.library.index.photo(id: newID)?.rating == 4)
        #expect(try e.sidecarText("b/IMG_1.xmp").contains("<xmp:Rating>4</xmp:Rating>"))
        #expect(logs.restored.count == 1)
    }

    @Test func pendingEditsFollowRenameAndDeleteAlbum() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        _ = await e.library.apply([.setRating(4)], to: [try e.id("a/IMG_1")])
        #expect(try await e.library.renameFolder("a", to: "c") == "c")
        #expect(try await pendingFields(e, try e.id("c/IMG_1")) == ["rating"])
        #expect(await e.library.deleteAlbum("c").isEmpty)
        #expect(try await pendingFields(e, try e.id("IMG_1")) == ["rating"])
    }

    @Test func lightCraftMergedIntoLoupeCreatedSidecarIsRecognised() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        let id = try e.id("a/IMG_1")
        _ = await e.library.apply([.setRating(4)], to: [id])
        #expect(try e.sidecarText("a/IMG_1.xmp").contains("x:xmptk=\"Loupe\""))
        let logs = Logs()
        let merged = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Loupe">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
           <xmp:CreatorTool>Loupe</xmp:CreatorTool>
          </rdf:Description>
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:lc="http://ns.lightcraft.app/lc/1.0/">
           <xmp:Rating>0</xmp:Rating>
           <lc:settings>{"version":1}</lc:settings>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let url = e.lib.url("a/IMG_1.xmp")
        try Data(merged.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(try e.library.index.photo(id: id)?.rating == 4)
        #expect(logs.restored.count == 1)
    }
}

/// Notifications of one library (others run in parallel tests).
private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var _changes = 0
    private var _albums = 0
    private var tokens: [any NSObjectProtocol] = []
    init(_ library: Library) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: Library.didChange, object: library, queue: nil) { [self] _ in
            lock.lock(); _changes += 1; lock.unlock()
        })
        tokens.append(center.addObserver(forName: Library.albumsDidChange, object: nil, queue: nil) { [self] _ in
            lock.lock(); _albums += 1; lock.unlock()
        })
    }
    deinit { for t in tokens { NotificationCenter.default.removeObserver(t) } }
    var changes: Int { lock.lock(); defer { lock.unlock() }; return _changes }
    var albums: Int { lock.lock(); defer { lock.unlock() }; return _albums }
}

/// Watcher input on a real ~/Pictures: Photos, LightCraft and Photo Booth libraries write constantly.
@Suite struct WatcherChurnTests {
    private func flags(_ f: Int) -> FSEventStreamEventFlags { FSEventStreamEventFlags(f) }

    @Test func eventsInsideIgnoredFoldersCauseNoRescan() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        for dir in ["Test.photoslibrary/database", "LightCraft Library/cache", ".hidden/x"] {
            try FileManager.default.createDirectory(at: e.lib.url(dir), withIntermediateDirectories: true)
        }
        _ = await e.library.initialSync()
        try e.lib.addJPEG("new.jpg")  // only a rescan would find it
        let notes = Notes(e.library)
        let dirCreated = flags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        let fileModified = flags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        var paths: [String] = []
        var eventFlags: [FSEventStreamEventFlags] = []
        for dir in ["Test.photoslibrary/database", "LightCraft Library/cache", ".hidden/x"] {
            paths += [e.lib.url(dir + "/sub").path, e.lib.url(dir + "/file.db").path]
            eventFlags += [dirCreated, fileModified]
        }
        let changes = FolderWatcher.classify(paths: paths, flags: eventFlags)
        #expect(!changes.directories.isEmpty)  // the old code turned these into a full scan
        await e.library.handleFolderChanges(changes)
        #expect(try e.library.index.photo(key: "new") == nil)
        #expect(await e.library.fullScans == 0)
        #expect(notes.changes == 0)

        // `.loupe` is hidden too, but album edits there still reach the sidebar.
        await e.library.handleFolderChanges(
            FolderWatcher.classify(paths: [e.lib.url(".loupe/albums.json").path], flags: [fileModified]))
        #expect(notes.albums >= 1)
        #expect(try e.library.index.photo(key: "new") == nil)
    }

    @Test func rapidFullScanRequestsCoalesce() async throws {
        let e = try Env()
        for i in 1...5 { try e.lib.addJPEG("a/IMG_\(i).jpg") }
        _ = await e.library.initialSync()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await e.library.handleFolderChanges(FolderWatcher.Changes(rescanAll: true)) }
            }
        }
        let scans = await e.library.fullScans
        #expect(scans >= 1 && scans <= 2)
    }

    @Test func unchangedRescanPostsNoDidChange() async throws {
        let e = try Env()
        try e.lib.addJPEG("a/IMG_1.jpg")
        _ = await e.library.initialSync()
        let notes = Notes(e.library)
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        await e.library.handleFolderChanges([e.lib.root], rescanAll: true)
        #expect(notes.changes == 0)
        try e.lib.addJPEG("a/IMG_2.jpg")
        await e.library.handleFolderChanges([e.lib.url("a")], rescanAll: false)
        #expect(notes.changes == 1)
    }
}
