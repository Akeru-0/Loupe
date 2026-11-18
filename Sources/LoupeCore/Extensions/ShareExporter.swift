import Foundation

/// Produces a shareable copy of a file in `directory`. Never modifies the source.
public protocol ShareExporter: Sendable {
    var id: String { get }
    var title: String { get }
    func canExport(_ kind: VersionKind) -> Bool
    func export(_ file: URL, kind: VersionKind, removeLocation: Bool, into directory: URL) throws -> URL
}
