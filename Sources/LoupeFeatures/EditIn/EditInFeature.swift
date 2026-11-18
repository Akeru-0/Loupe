import LoupeIndex

public enum EditInFeature: LoupeFeature {
    public static func register(in registry: inout FeatureRegistry) {
        registry.actions.append(EditInAction())
    }
}
