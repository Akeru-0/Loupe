import AppKit
import LoupeCore

/// "Scripts" submenu: runs each script in the Scripts folder on the selected photos' files.
public struct ScriptsAction: PhotoAction {
    public let id = "scripts"
    private let directory: URL
    private let reveal: @Sendable (URL) -> Void
    private let shortcutRunner: ScriptRunner.ShortcutRunner

    public init(
        directory: URL,
        reveal: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) },
        shortcutRunner: @escaping ScriptRunner.ShortcutRunner = ScriptRunner.liveShortcutRunner
    ) {
        self.directory = directory
        self.reveal = reveal
        self.shortcutRunner = shortcutRunner
    }

    /// Files, photo keys and version kinds, in matching order.
    private func inputs(for selection: ActionSelection) -> (files: [URL], keys: [String], kinds: [VersionKind]) {
        if let focused = selection.focusedVersion {
            let photo = selection.photos.first { $0.id == focused.photoId } ?? selection.photos.first
            return ([focused.url(in: selection.root)], [photo?.key ?? ""], [focused.kind])
        }
        var files: [URL] = [], keys: [String] = [], kinds: [VersionKind] = []
        for photo in selection.photos {
            guard let id = photo.id, let display = selection.versions[id]?.first(where: \.isDisplay) else { continue }
            files.append(display.url(in: selection.root))
            keys.append(photo.key)
            kinds.append(display.kind)
        }
        return (files, keys, kinds)
    }

    @MainActor public func entries(for selection: ActionSelection) -> [ActionMenuEntry] {
        let (files, keys, kinds) = inputs(for: selection)
        let directory = self.directory
        let reveal = self.reveal
        let shortcutRunner = self.shortcutRunner

        var children = ScriptCatalog(directory: directory).scripts().map { item in
            ActionMenuEntry(id: "scripts.run.\(item.url.path)", title: item.title, isEnabled: !files.isEmpty) { context in
                let result = try await ScriptRunner.run(
                    item, files: files, photoKeys: keys, kinds: kinds, shortcutRunner: shortcutRunner)
                context.log("Script \(item.title) exited \(result.exitCode)\n\(result.output)")
            }
        }
        children.append(ActionMenuEntry(id: "scripts.open-folder", title: "Open Scripts Folder") { _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            reveal(directory)
        })
        return [ActionMenuEntry(id: "scripts", title: "Scripts", systemImage: "applescript", children: children)]
    }
}
