import Foundation

public struct VersionRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64?
    public var photoId: Int64
    /// Relative to the location root.
    public var path: String
    public var kind: VersionKind
    public var size: Int64
    public var modified: Date
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var isDisplay: Bool

    public init(
        id: Int64? = nil, photoId: Int64, path: String, kind: VersionKind, size: Int64, modified: Date,
        pixelWidth: Int? = nil, pixelHeight: Int? = nil, duration: Double? = nil, isDisplay: Bool = false
    ) {
        self.id = id
        self.photoId = photoId
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isDisplay = isDisplay
    }

    public func url(in root: URL) -> URL {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .reduce(root) { $0.appendingPathComponent(String($1)) }
    }
}
