import Foundation

/// A place besides the XMP sidecar that mirrors Loupe's metadata (e.g. Finder tags).
/// `files` are always media (version) files, never sidecars.
public protocol MetadataStore: Sendable {
    var id: String { get }
    /// Writes `metadata` to the store and returns an opaque state blob to hand back next time.
    func push(_ metadata: PhotoMetadata, files: [URL], lastState: Data?) throws -> Data
    /// Changes made in the store since `lastState` was recorded.
    func pull(files: [URL], lastState: Data?) throws -> [MetadataChange]
}
