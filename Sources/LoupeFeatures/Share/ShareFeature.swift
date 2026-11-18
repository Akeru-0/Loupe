import LoupeCore
import LoupeIndex

public enum ShareFeature: LoupeFeature {
    public static func register(in registry: inout FeatureRegistry) {
        registry.shareExporters.append(contentsOf: [OriginalExporter(), JPEGExporter.highQuality, JPEGExporter.small] as [any ShareExporter])
        registry.actions.append(ShareAction(exporters: registry.shareExporters))
    }
}
