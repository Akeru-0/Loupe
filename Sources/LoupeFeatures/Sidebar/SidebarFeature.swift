import LoupeIndex

public enum SidebarFeature: LoupeFeature {
    public static func register(in registry: inout FeatureRegistry) {
        registry.sidebarSections.append(contentsOf: [
            LibrarySidebarSection(), MediaTypesSidebarSection(), AlbumsSidebarSection(), TagsSidebarSection(),
        ] as [any SidebarSection])
    }
}
