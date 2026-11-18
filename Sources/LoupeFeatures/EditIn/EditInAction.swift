import AppKit
import LoupeCore

/// "Edit": opens the selected photo files in an external editor (the default one first).
public struct EditInAction: PhotoAction {
    public static let lightCraftBundleID = "ai.storyteller.lightcraft"

    /// Side effects, injectable so tests never launch apps.
    public struct Hooks: Sendable {
        public var openFiles: @Sendable (_ files: [URL], _ app: URL) async throws -> Void
        public var revealFiles: @Sendable (_ files: [URL]) -> Void
        public var activateApp: @Sendable (_ app: URL) async throws -> Void

        public init(
            openFiles: @escaping @Sendable ([URL], URL) async throws -> Void,
            revealFiles: @escaping @Sendable ([URL]) -> Void,
            activateApp: @escaping @Sendable (URL) async throws -> Void
        ) {
            self.openFiles = openFiles
            self.revealFiles = revealFiles
            self.activateApp = activateApp
        }

        public static let live = Hooks(
            openFiles: { files, app in
                _ = try await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            },
            revealFiles: { NSWorkspace.shared.activateFileViewerSelecting($0) },
            activateApp: { app in
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        )
    }

    public let id = "edit-in"
    private let appsForFile: @Sendable (URL) -> [URL]
    private let hooks: Hooks
    private let defaults: any PreferenceStore

    public init(
        appsForFile: @escaping @Sendable (URL) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
        hooks: Hooks = .live,
        defaults: any PreferenceStore = UserDefaultsStore.standard
    ) {
        self.appsForFile = appsForFile
        self.hooks = hooks
        self.defaults = defaults
    }

    @MainActor public func entries(for selection: ActionSelection) -> [ActionMenuEntry] {
        let files = selection.targetFiles()
        guard let first = files.first else { return [] }
        let defaults = self.defaults
        let hooks = self.hooks
        let defaultEditor = EditorPreferences.defaultEditor(in: defaults)

        func open(_ app: URL, _ context: any ActionContext) async throws {
            if Bundle(url: app)?.bundleIdentifier == Self.lightCraftBundleID {
                // LightCraft declares no document types, so it can't be asked to open files.
                hooks.revealFiles(files)
                try await hooks.activateApp(app)
                context.log("LightCraft can't open files directly — drag the selected file into LightCraft")
            } else {
                try await hooks.openFiles(files, app)
            }
        }
        func appEntry(_ app: URL, isDefault: Bool) -> ActionMenuEntry {
            let name = FileManager.default.displayName(atPath: app.path)
            return ActionMenuEntry(
                id: "edit-in.app.\(app.path)", title: isDefault ? "\(name) (Default)" : name
            ) { context in try await open(app, context) }
        }

        var children: [ActionMenuEntry] = []
        if let defaultEditor { children.append(appEntry(defaultEditor, isDefault: true)) }
        for app in appsForFile(first) where app.standardizedFileURL != defaultEditor?.standardizedFileURL {
            children.append(appEntry(app, isDefault: false))
        }
        children.append(ActionMenuEntry(id: "edit-in.choose", title: "Choose Default Editor…") { context in
            if let app = await context.chooseApplication() { EditorPreferences.setDefaultEditor(app, in: defaults) }
        })

        return [ActionMenuEntry(
            id: "edit-in", title: "Edit", systemImage: "pencil", shortcut: "e", children: children
        ) { context in
            if let app = EditorPreferences.defaultEditor(in: defaults) {
                try await open(app, context)
            } else if let app = await context.chooseApplication() {
                EditorPreferences.setDefaultEditor(app, in: defaults)
                try await open(app, context)
            }
        }]
    }
}
