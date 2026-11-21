import AppKit
import Foundation

/// What Loupe does in LightCraft over its control channel (`LightCraftControl`): find the photos it has for files,
/// open photos for editing, and make it re-read sidecars Loupe changed.
public enum LightCraftBridge {
    public static let bundleID = "ai.storyteller.lightcraft"

    public enum BridgeError: LocalizedError {
        /// LightCraft runs, but wasn't started with the control port, so Loupe can't drive it.
        case runningWithoutControl
        case didNotStart
        case notImported([URL])

        public var errorDescription: String? {
            switch self {
            case .runningWithoutControl:
                "LightCraft is running without Loupe's connection and didn't quit. Quit LightCraft, then choose "
                    + "Edit again: Loupe starts it connected."
            case .didNotStart: "LightCraft didn't start its control connection."
            case .notImported(let files):
                "LightCraft didn't import \(files.map(\.lastPathComponent).joined(separator: ", "))."
            }
        }
    }

    // MARK: - Connecting

    /// Connects to LightCraft, starting it with the control port when it isn't running. When it runs without the
    /// port (opened from the Dock or Finder), it is quit the normal way (it saves, and may ask about unsaved work) and
    /// started again connected.
    public static func connect(app: URL, port: UInt16 = LightCraftControl.defaultPort) async throws -> LightCraftControl {
        if let control = await Task.detached(operation: { try? LightCraftControl(port: port) }).value { return control }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !running.isEmpty {
            for app in running { app.terminate() }
            var quit = false
            for _ in 0..<40 {  // up to 20 s, time to answer a "save changes?" question
                try await Task.sleep(for: .milliseconds(500))
                if running.allSatisfy(\.isTerminated) { quit = true; break }
            }
            guard quit else { throw BridgeError.runningWithoutControl }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--control", String(port)]
        configuration.environment = ["LIGHTCRAFT_CONTROL_PORT": String(port)]
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        for _ in 0..<60 {  // it opens its library first
            try await Task.sleep(for: .milliseconds(500))
            if let control = await Task.detached(operation: { try? LightCraftControl(port: port) }).value { return control }
        }
        throw BridgeError.didNotStart
    }

    // MARK: - Operations (blocking: call off the main thread)

    /// LightCraft's photo ids for those of `files` it has (not in its Recently Deleted), by file.
    public static func ids(for files: [URL], control: LightCraftControl) throws -> [URL: Int] {
        var ids: [URL: Int] = [:]
        for (folder, inFolder) in Dictionary(grouping: files, by: { $0.deletingLastPathComponent() }) {
            let result = try control.execute("catalog.query", ["filter": ["folder": folder.path], "limit": 100_000])
            var byName: [String: Int] = [:]
            for photo in (result as? [String: Any])?["photos"] as? [[String: Any]] ?? [] {
                guard photo["deleted"] as? Bool != true, let id = photo["id"] as? Int,
                    let name = photo["fileName"] as? String
                else { continue }
                byName[key(name)] = id
            }
            for file in inFolder { ids[file] = byName[key(file.lastPathComponent)] }
        }
        return ids
    }

    /// Edit in LightCraft: imports the files it doesn't have yet (in place: nothing is copied or moved), selects
    /// them and shows the first in the Detail view.
    public static func edit(_ files: [URL], control: LightCraftControl) throws {
        var ids = try ids(for: files, control: control)
        let missing = files.filter { ids[$0] == nil }
        if !missing.isEmpty {
            try control.execute("library.import", ["paths": missing.map(\.path), "mode": "add"], timeout: 60)
            // The app imports on a worker thread: wait for the photos to be in its catalog.
            let deadline = Date().addingTimeInterval(30)
            while files.contains(where: { ids[$0] == nil }), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                ids = try self.ids(for: files, control: control)
            }
        }
        let selected = files.compactMap { ids[$0] }
        guard !selected.isEmpty else { throw BridgeError.notImported(files) }
        try control.execute("library.select", ["ids": selected])
        _ = try? control.request("ui.set", ["view": "detail"])
    }

    /// After Loupe changed these files' sidecar: LightCraft reads it again, so it doesn't write its old values back.
    /// Photos LightCraft doesn't have are left alone.
    public static func reload(_ files: [URL], control: LightCraftControl) throws {
        let ids = Set(try self.ids(for: files, control: control).values)
        guard !ids.isEmpty else { return }
        try control.execute("photo.readMetadataFromFile", ["ids": ids.sorted()])
    }

    /// File names as LightCraft and the file system compare them.
    private static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
}
