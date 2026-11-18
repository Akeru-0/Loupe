/// User-facing metadata Loupe owns in an XMP sidecar.
public struct PhotoMetadata: Equatable, Sendable {
    public var rating: Int
    public var tags: [String]
    public var albums: [String]
    public var isFavorite: Bool
    public var hasLightCraftEdits: Bool

    public init(
        rating: Int = 0,
        tags: [String] = [],
        albums: [String] = [],
        isFavorite: Bool = false,
        hasLightCraftEdits: Bool = false
    ) {
        self.rating = rating
        self.tags = tags
        self.albums = albums
        self.isFavorite = isFavorite
        self.hasLightCraftEdits = hasLightCraftEdits
    }
}

public enum MetadataChange: Hashable, Sendable, Codable {
    case setRating(Int)
    case setFavorite(Bool)
    case addTag(String)
    case removeTag(String)
    case addToAlbum(String)
    case removeFromAlbum(String)
}

public enum Keywords {
    public static let favorite = "Favorite"
    public static let albumPrefix = "Albums|"
}
