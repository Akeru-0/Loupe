import AppKit
import LoupeCore

/// "Edit": opens the selected photo files in the default external editor (chosen the first time). Its children
/// ("Edit With ▸" in menus) only choose the default: the apps that open the file, the current default checked, and
/// "Other…" for any app.
public struct EditInAction: PhotoAction {
    public static let lightCraftBundleID = LightCraftBridge.bundleID

    /// Side effects, injectable so tests never launch apps.
    public struct Hooks: Sendable {
        public var openFiles: @Sendable (_ files: [URL], _ app: URL) async throws -> Void
        public var revealFiles: @Sendable (_ files: [URL]) -> Void
        public var activateApp: @Sendable (_ app: URL) async throws -> Void
        /// Opens the files in LightCraft over its control channel (starting it connected if needed).
        public var editInLightCraft: @Sendable (_ files: [URL], _ app: URL) async throws -> Void

        public init(
            openFiles: @escaping @Sendable ([URL], URL) async throws -> Void,
            revealFiles: @escaping @Sendable ([URL]) -> Void,
            activateApp: @escaping @Sendable (URL) async throws -> Void,
            editInLightCraft: @escaping @Sendable ([URL], URL) async throws -> Void = Hooks.liveLightCraft
        ) {
            self.openFiles = openFiles
            self.revealFiles = revealFiles
            self.activateApp = activateApp
            self.editInLightCraft = editInLightCraft
        }

        public static let liveLightCraft: @Sendable ([URL], URL) async throws -> Void = { files, app in
            let control = try await LightCraftBridge.connect(app: app)
            try await Task.detached { try LightCraftBridge.edit(files, control: control) }.value
            await MainActor.run {
                _ = NSRunningApplication.runningApplications(withBundleIdentifier: LightCraftBridge.bundleID).first?.activate()
            }
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
        // LightCraft edits the RAW of a RAW + JPEG photo (its sidecar describes the RAW), unless a version is focused.
        let lightCraftFiles = selection.focusedVersion != nil ? files : selection.photos.compactMap { photo -> URL? in
            guard let id = photo.id, let versions = selection.versions[id] else { return nil }
            return (versions.first { $0.kind == .raw } ?? versions.first(where: \.isDisplay) ?? versions.first)?
                .url(in: selection.root)
        }
        let defaults = self.defaults
        let hooks = self.hooks
        let defaultEditor = EditorPreferences.defaultEditor(in: defaults)

        func open(_ app: URL, _ context: any ActionContext) async throws {
            if Bundle(url: app)?.bundleIdentifier == Self.lightCraftBundleID {
                // LightCraft declares no document types: it is driven over its control channel instead. If that
                // can't be done, the files are shown in Finder to drag in.
                do {
                    try await hooks.editInLightCraft(lightCraftFiles, app)
                } catch {
                    hooks.revealFiles(lightCraftFiles)
                    try await hooks.activateApp(app)
                    context.log("Couldn't open in LightCraft: \(error.localizedDescription) "
                        + "Drag the selected file into LightCraft instead.")
                }
            } else {
                try await hooks.openFiles(files, app)
            }
        }
        func appEntry(_ app: URL, isDefault: Bool) -> ActionMenuEntry {
            ActionMenuEntry(
                id: "edit-in.app.\(app.path)", title: FileManager.default.displayName(atPath: app.path),
                systemImage: isDefault ? "checkmark" : nil
            ) { _ in EditorPreferences.setDefaultEditor(app, in: defaults) }
        }

        var children: [ActionMenuEntry] = []
        if let defaultEditor { children.append(appEntry(defaultEditor, isDefault: true)) }
        for app in appsForFile(first) where app.standardizedFileURL != defaultEditor?.standardizedFileURL {
            children.append(appEntry(app, isDefault: false))
        }
        children.append(ActionMenuEntry(id: "edit-in.choose", title: "Other…") { context in
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
