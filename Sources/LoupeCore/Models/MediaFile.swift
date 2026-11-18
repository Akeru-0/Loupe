import Foundation

public struct MediaFile: Hashable, Sendable {
    public var url: URL
    public var size: Int64
    public var modified: Date
    public var created: Date

    public init(url: URL, size: Int64, modified: Date, created: Date) {
        self.url = url
        self.size = size
        self.modified = modified
        self.created = created
    }
}
