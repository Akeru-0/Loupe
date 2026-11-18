import Foundation
import Testing
import LoupeCore
@testable import LoupeFeatures

final class ShortcutCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var calls: [[String]] { lock.withLock { _calls } }
    var runner: ScriptRunner.ShortcutRunner {
        { args in
            self.lock.withLock { self._calls.append(args) }
            return ScriptResult(exitCode: 0, output: "ok\n")
        }
    }
}

final class RevealCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func reveal(_ url: URL) { lock.withLock { _urls.append(url) } }
}

@Suite @MainActor struct ScriptTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String, _ body: String, executable: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    @Test func catalogListsExecutablesAndShortcuts() throws {
        try write("run.sh", "#!/bin/sh\n")
        try write("notes.txt", "hi", executable: false)
        try write("Resize for Web.shortcut", "", executable: false)
        let items = ScriptCatalog(directory: dir).scripts()
        #expect(items.map(\.title) == ["Resize for Web", "run"])
        #expect(items.map(\.kind) == [.shortcut, .executable])
    }

    @Test func passesPathsWithSpacesVerbatim() async throws {
        let script = try write("echo.sh", "#!/bin/sh\necho \"$#|$1\"\n")
        let file = URL(fileURLWithPath: "/tmp/some dir/a b.jpg")
        let result = try await ScriptRunner.run(
            ScriptItem(url: script, title: "echo", kind: .executable), files: [file], photoKeys: ["a"], kinds: [.jpeg])
        #expect(result.output == "1|/tmp/some dir/a b.jpg\n")
    }

    @Test func setsEnvironmentAndHomebrewPath() async throws {
        let script = try write("env.sh", "#!/bin/sh\necho \"$LOUPE_PHOTO_IDS|$LOUPE_VERSION_KINDS|$PATH\"\n")
        let result = try await ScriptRunner.run(
            ScriptItem(url: script, title: "env", kind: .executable),
            files: [URL(fileURLWithPath: "/x.cr2")], photoKeys: ["a/IMG_1"], kinds: [.raw])
        #expect(result.output.hasPrefix("a/IMG_1|raw|/opt/homebrew/bin:"))
    }

    @Test func reportsNonZeroExit() async throws {
        let script = try write("fail.sh", "#!/bin/sh\necho oops >&2\nexit 3\n")
        let result = try await ScriptRunner.run(
            ScriptItem(url: script, title: "fail", kind: .executable), files: [], photoKeys: [], kinds: [])
        #expect(result.exitCode == 3)
        #expect(result.output == "oops\n")
    }

    @Test func failureToLaunchThrows() async {
        let item = ScriptItem(url: dir.appendingPathComponent("missing"), title: "missing", kind: .executable)
        await #expect(throws: (any Error).self) {
            try await ScriptRunner.run(item, files: [], photoKeys: [], kinds: [])
        }
    }

    @Test func shortcutRunsOncePerFile() async throws {
        let calls = ShortcutCalls()
        let item = ScriptItem(url: dir.appendingPathComponent("Resize.shortcut"), title: "Resize", kind: .shortcut)
        let files = [URL(fileURLWithPath: "/p/a b.jpg"), URL(fileURLWithPath: "/p/c.jpg")]
        let result = try await ScriptRunner.run(
            item, files: files, photoKeys: ["a b", "c"], kinds: [.jpeg, .jpeg], shortcutRunner: calls.runner)
        #expect(calls.calls == [
            ["run", "Resize", "--input-path", "/p/a b.jpg"], ["run", "Resize", "--input-path", "/p/c.jpg"],
        ])
        #expect(result.exitCode == 0)
    }

    @Test func actionListsScriptsAndRunsThem() async throws {
        try write("echo.sh", "#!/bin/sh\necho \"$LOUPE_PHOTO_IDS|$LOUPE_VERSION_KINDS\"\n")
        let reveal = RevealCalls()
        let action = ScriptsAction(directory: dir, reveal: reveal.reveal, shortcutRunner: ShortcutCalls().runner)
        let root = URL(fileURLWithPath: "/tmp/loupe-script-root")
        let photo = PhotoRecord(id: 1, locationId: "l", folderPath: "a", stem: "p", stemKey: "p", addedDate: Date())
        let version = VersionRecord(photoId: 1, path: "a/p.jpg", kind: .jpeg, size: 1, modified: Date(), isDisplay: true)
        let selection = ActionSelection(photos: [photo], versions: [1: [version]], root: root)

        let entries = action.entries(for: selection)
        #expect(entries.map(\.title) == ["Scripts"])
        let children = entries[0].children
        #expect(children.map(\.title) == ["echo", "Open Scripts Folder"])

        let context = FakeContext()
        try await children[0].perform?(context)
        #expect(context.logs == ["Script echo exited 0\na/p|jpeg\n"])

        try await children[1].perform?(context)
        #expect(reveal.urls == [dir])
    }

    @Test func openScriptsFolderCreatesIt() async throws {
        let missing = dir.appendingPathComponent("Scripts")
        let reveal = RevealCalls()
        let action = ScriptsAction(directory: missing, reveal: reveal.reveal)
        let entries = action.entries(for: ActionSelection(photos: [], versions: [:], root: dir))
        try await entries[0].children.last?.perform?(FakeContext())
        #expect(FileManager.default.fileExists(atPath: missing.path))
        #expect(reveal.urls == [missing])
    }
}

@Suite @MainActor struct ScriptSelectionTests {
    let root = URL(fileURLWithPath: "/tmp/loupe-script-root")
    func photo(_ id: Int64, _ folder: String, _ stem: String) -> PhotoRecord {
        PhotoRecord(id: id, locationId: "l", folderPath: folder, stem: stem, stemKey: stem, addedDate: Date())
    }
    func version(_ id: Int64, _ path: String, _ kind: VersionKind, display: Bool) -> VersionRecord {
        VersionRecord(photoId: id, path: path, kind: kind, size: 1, modified: Date(), isDisplay: display)
    }

    @Test func focusedVersionIsTheOnlyTarget() {
        let raw = version(2, "b/q.cr2", .raw, display: false)
        let sel = ActionSelection(
            photos: [photo(1, "a", "p"), photo(2, "b", "q")],
            versions: [1: [version(1, "a/p.jpg", .jpeg, display: true)], 2: [raw, version(2, "b/q.jpg", .jpeg, display: true)]],
            focusedVersion: raw, root: root)
        let targets = sel.targets()
        #expect(targets.map(\.url) == sel.targetFiles())
        #expect(targets.map(\.url) == [root.appendingPathComponent("b/q.cr2")])
        #expect(targets.map { $0.photo?.key } == ["b/q"])
        #expect(targets.map(\.version.kind) == [.raw])
    }

    @Test func focusedVersionIsTargetEvenWithoutPhotos() {
        let raw = version(2, "b/q.cr2", .raw, display: false)
        let sel = ActionSelection(photos: [], versions: [:], focusedVersion: raw, root: root)
        #expect(sel.targetFiles() == [root.appendingPathComponent("b/q.cr2")])
    }

    @Test func displayVersionsInOrderJoinedInEnvironment() async throws {
        let sel = ActionSelection(
            photos: [photo(1, "a", "p"), photo(2, "", "q")],
            versions: [
                1: [version(1, "a/p.jpg", .jpeg, display: true)],
                2: [version(2, "q.mov", .video, display: true)],
            ], root: root)
        #expect(sel.targets().map(\.url) == sel.targetFiles())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("e.sh")
        try "#!/bin/sh\nprintf '%s|%s' \"$LOUPE_PHOTO_IDS\" \"$LOUPE_VERSION_KINDS\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let logs = LogContext()
        let action = ScriptsAction(directory: dir, reveal: { _ in })
        try await action.entries(for: sel)[0].children[0].perform?(logs)
        #expect(logs.logs == ["Script e exited 0\na/p\nq|jpeg\nvideo"])
    }
}

@MainActor final class LogContext: ActionContext {
    var logs: [String] = []
    func share(_ urls: [URL]) {}
    func log(_ message: String) { logs.append(message) }
    func present(_ error: any Error) {}
    func chooseApplication() async -> URL? { nil }
}
