import AppKit
import Foundation
import Testing
import LoupeCore
@testable import LoupeFeatures

@MainActor final class FakeContext: ActionContext {
    var logs: [String] = []
    var chosen: URL?
    func share(_ urls: [URL]) {}
    func log(_ message: String) { logs.append(message) }
    func present(_ error: any Error) {}
    func chooseApplication() async -> URL? { chosen }
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [([URL], URL)] = []
    private var _revealed: [[URL]] = []
    private var _activated: [URL] = []
    var opened: [([URL], URL)] { lock.withLock { _opened } }
    var revealed: [[URL]] { lock.withLock { _revealed } }
    var activated: [URL] { lock.withLock { _activated } }
    var hooks: EditInAction.Hooks {
        .init(
            openFiles: { f, a in self.lock.withLock { self._opened.append((f, a)) } },
            revealFiles: { f in self.lock.withLock { self._revealed.append(f) } },
            activateApp: { a in self.lock.withLock { self._activated.append(a) } }
        )
    }
}

@Suite @MainActor struct EditInTests {
    let root = URL(fileURLWithPath: "/tmp/loupe-editin-root")
    let suite = "loupe-editin-\(UUID().uuidString)"
    let defaults: UserDefaults
    let calls = Calls()

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    func photo(_ id: Int64) -> PhotoRecord {
        PhotoRecord(id: id, locationId: "l", folderPath: "", stem: "p\(id)", stemKey: "p\(id)", addedDate: Date())
    }
    func version(_ photo: Int64, _ path: String, _ kind: VersionKind, display: Bool) -> VersionRecord {
        VersionRecord(photoId: photo, path: path, kind: kind, size: 1, modified: Date(), isDisplay: display)
    }
    func fakeApp(_ bundleID: String, name: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-editin-\(UUID().uuidString)/\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    func selection(focused: Bool = false) -> ActionSelection {
        let raw = version(1, "a/p1.CR2", .image, display: false)
        let jpg = version(1, "a/p1.jpg", .image, display: true)
        let other = version(2, "p2.jpg", .image, display: true)
        return ActionSelection(
            photos: [photo(1), photo(2)], versions: [1: [raw, jpg], 2: [other]],
            focusedVersion: focused ? raw : nil, root: root)
    }
    func action(apps: [URL] = []) -> EditInAction {
        EditInAction(appsForFile: { _ in apps }, hooks: calls.hooks, defaults: defaults)
    }

    @Test func targetsFocusedVersion() {
        #expect(selection(focused: true).targetFiles() == [root.appendingPathComponent("a/p1.CR2")])
    }

    @Test func targetsDisplayVersions() {
        #expect(selection().targetFiles() == [root.appendingPathComponent("a/p1.jpg"), root.appendingPathComponent("p2.jpg")])
    }

    @Test func editEntryShapeAndDefaultFirst() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let def = try fakeApp("x.default", name: "Default")
        let other = try fakeApp("x.other", name: "Other")
        EditorPreferences.setDefaultEditor(def, in: defaults)
        // The system doesn't list the default; it must still come first.
        let entries = action(apps: [other]).entries(for: selection())
        #expect(entries.count == 1)
        let edit = entries[0]
        #expect(edit.title == "Edit")
        #expect(edit.shortcut == "e")
        #expect(edit.children.map(\.id) == ["edit-in.app.\(def.path)", "edit-in.app.\(other.path)", "edit-in.choose"])
        #expect(edit.children.last?.title == "Choose Default Editor…")
    }

    @Test func normalAppOpensTargetFiles() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = try fakeApp("x.normal", name: "Normal")
        EditorPreferences.setDefaultEditor(app, in: defaults)
        let ctx = FakeContext()
        try await action().entries(for: selection())[0].perform!(ctx)
        #expect(calls.opened.count == 1)
        #expect(calls.opened[0].0 == selection().targetFiles())
        #expect(calls.opened[0].1.path == app.path)
        #expect(calls.revealed.isEmpty && calls.activated.isEmpty && ctx.logs.isEmpty)
    }

    @Test func lightCraftRevealsActivatesAndLogsButNeverOpens() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let lc = try fakeApp("ai.storyteller.lightcraft", name: "LightCraft")
        EditorPreferences.setDefaultEditor(lc, in: defaults)
        let ctx = FakeContext()
        try await action().entries(for: selection())[0].perform!(ctx)
        #expect(calls.opened.isEmpty)
        #expect(calls.revealed == [selection().targetFiles()])
        #expect(calls.activated.map(\.path) == [lc.path])
        #expect(ctx.logs == ["LightCraft can't open files directly — drag the selected file into LightCraft"])
    }

    @Test func noDefaultChoosesSavesAndOpens() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = try fakeApp("x.chosen", name: "Chosen")
        let ctx = FakeContext()
        ctx.chosen = app
        try await action().entries(for: selection())[0].perform!(ctx)
        #expect(EditorPreferences.defaultEditor(in: defaults)?.path == app.path)
        #expect(calls.opened.count == 1)
    }

    @Test func childOpensOnceWithoutChangingDefault() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let def = try fakeApp("x.default", name: "Default")
        let other = try fakeApp("x.other", name: "Other")
        EditorPreferences.setDefaultEditor(def, in: defaults)
        let child = action(apps: [other]).entries(for: selection())[0].children[1]
        try await child.perform!(FakeContext())
        #expect(calls.opened.count == 1 && calls.opened[0].1.path == other.path)
        #expect(EditorPreferences.defaultEditor(in: defaults)?.path == def.path)
    }
}
