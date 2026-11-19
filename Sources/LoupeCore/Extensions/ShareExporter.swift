import Foundation

/// Produces a shareable copy of a file in `directory`. Never modifies the source.
public protocol ShareExporter: Sendable {
    var id: String { get }
    var title: String { get }
    func canExport(_ kind: VersionKind) -> Bool
    /// `rotation` is the photo's extra turn (`PhotoRecord.rotation`), nil when the file's own orientation applies.
    func export(_ file: URL, kind: VersionKind, rotation: Int?, removeLocation: Bool, into directory: URL) throws -> URL
}
