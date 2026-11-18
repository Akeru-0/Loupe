import LoupeIndex

/// Every feature the app registers at launch, in registration order.
public enum BuiltInFeatures {
    public static let all: [any LoupeFeature.Type] = [
        SidebarFeature.self, FinderTagsFeature.self, EditInFeature.self, ShareFeature.self, ScriptsFeature.self,
    ]
}
