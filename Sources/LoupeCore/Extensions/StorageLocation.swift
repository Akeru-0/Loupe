import Foundation

public protocol StorageLocation: Sendable {
    var id: String { get }
    var displayName: String { get }
    var rootURL: URL { get }
}

public struct LocalFolderLocation: StorageLocation {
    public let rootURL: URL
    public var id: String { "local" }
    public var displayName: String { "Mac" }

    public init(rootURL: URL) { self.rootURL = rootURL }
}
