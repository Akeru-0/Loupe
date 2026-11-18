import LoupeCore

public struct FeatureRegistry: Sendable {
    public var metadataStores: [any MetadataStore] = []
    public var actions: [any PhotoAction] = []
    public var shareExporters: [any ShareExporter] = []
    public init() {}
}
