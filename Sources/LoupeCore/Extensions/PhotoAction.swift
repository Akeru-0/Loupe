import Foundation

/// What an action is invoked on: the selected photos and (optionally) the focused version.
public struct ActionSelection: Sendable {
    public var photos: [PhotoRecord]
    public var versions: [Int64: [VersionRecord]]
    public var focusedVersion: VersionRecord?
    public var root: URL

    public init(photos: [PhotoRecord], versions: [Int64: [VersionRecord]], focusedVersion: VersionRecord? = nil, root: URL) {
        self.photos = photos
        self.versions = versions
        self.focusedVersion = focusedVersion
        self.root = root
    }

    /// The focused version if set, otherwise each photo's display version.
    public func targetFiles() -> [URL] {
        if let focusedVersion { return [focusedVersion.url(in: root)] }
        return photos.compactMap { photo in
            guard let id = photo.id, let display = versions[id]?.first(where: \.isDisplay) else { return nil }
            return display.url(in: root)
        }
    }
}

/// Services the app offers to actions.
@MainActor public protocol ActionContext: AnyObject {
    func share(_ urls: [URL])
    func log(_ message: String)
    func present(_ error: any Error)
    func chooseApplication() async -> URL?
}

public struct ActionMenuEntry: Identifiable {
    public var id: String
    public var title: String
    public var systemImage: String?
    public var shortcut: Character?
    public var isEnabled: Bool
    public var children: [ActionMenuEntry]
    public var perform: (@MainActor (any ActionContext) async throws -> Void)?

    public init(
        id: String, title: String, systemImage: String? = nil, shortcut: Character? = nil, isEnabled: Bool = true,
        children: [ActionMenuEntry] = [], perform: (@MainActor (any ActionContext) async throws -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.children = children
        self.perform = perform
    }
}

public protocol PhotoAction: Sendable {
    var id: String { get }
    @MainActor func entries(for selection: ActionSelection) -> [ActionMenuEntry]
}
