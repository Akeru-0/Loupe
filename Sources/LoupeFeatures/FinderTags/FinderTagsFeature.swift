import LoupeIndex

public enum FinderTagsFeature: LoupeFeature {
    public static func register(in registry: inout FeatureRegistry) {
        registry.metadataStores.append(FinderTagStore())
    }
}
