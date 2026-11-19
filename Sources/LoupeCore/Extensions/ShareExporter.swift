import Foundation

/// Produces a shareable copy of a file in `directory`. Never modifies the source.
public protocol ShareExporter: Sendable {
    var id: String { get }
    var title: String { get }
    func canExport(_ kind: VersionKind) -> Bool
    /// `orientation` is the photo's override (the sidecar's `tiff:Orientation`), nil when the file's own applies.
    func export(_ file: URL, kind: VersionKind, rotation: Int?, removeLocation: Bool, into directory: URL) throws -> URL
}
