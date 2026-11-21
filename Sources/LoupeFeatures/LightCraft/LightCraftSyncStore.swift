import Foundation
import LoupeCore

/// Keeps LightCraft in step with Loupe's metadata edits. LightCraft reads a sidecar only on import (or when told to)
/// and writes its own values back on its next save, so after Loupe writes a photo's sidecar this tells a running,
/// connected LightCraft to re-read it (`photo.readMetadataFromFile`). Only when a value Loupe edits changed since the
/// last push: the first push just records the state (LightCraft read the sidecar when it imported the photo).
/// Without LightCraft on its control port this does nothing, and the stale-revert guard covers the edit instead.
public struct LightCraftSyncStore: MetadataStore {
    public let id = "lightcraft"
    private let port: UInt16
    private let reload: @Sendable ([URL]) -> Void

    public init(port: UInt16 = LightCraftControl.defaultPort) {
        self.port = port
        reload = { files in
            guard let control = try? LightCraftControl(port: port, timeout: 0.2) else { return }
            try? LightCraftBridge.reload(files, control: control)
        }
    }

    /// For tests: `reload` instead of LightCraft.
    init(reload: @escaping @Sendable ([URL]) -> Void) {
        port = LightCraftControl.defaultPort
        self.reload = reload
    }

    public func push(_ metadata: PhotoMetadata, files: [URL], lastState: Data?) throws -> Data {
        let state = Self.state(of: metadata)
        if let lastState, lastState != state { reload(files) }
        return state
    }

    /// LightCraft's own edits come back through the sidecar, which the scanner reads.
    public func pull(files: [URL], lastState: Data?) throws -> [MetadataChange] { [] }

    /// The values Loupe edits that LightCraft also keeps.
    static func state(of m: PhotoMetadata) -> Data {
        let fields: [String: Any] = [
            "rating": m.rating, "favorite": m.isFavorite, "hidden": m.isHidden,
            "tags": m.tags.sorted(), "albums": m.albums.sorted(),
        ]
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }
}
