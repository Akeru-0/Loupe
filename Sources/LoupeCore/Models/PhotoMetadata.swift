/// User-facing metadata Loupe owns in an XMP sidecar.
public struct PhotoMetadata: Equatable, Sendable {
    public var rating: Int
    public var tags: [String]
    public var albums: [String]
    public var isFavorite: Bool
    /// Hidden photos are left out of every view but Hidden.
    public var isHidden: Bool
    public var hasLightCraftEdits: Bool
    /// The sidecar's `tiff:Orientation` (1…8), or nil when it has none and the file's own orientation applies.
    public var orientation: Int?

    public init(
        rating: Int = 0,
        tags: [String] = [],
        albums: [String] = [],
        isFavorite: Bool = false,
        isHidden: Bool = false,
        hasLightCraftEdits: Bool = false,
        orientation: Int? = nil
    ) {
        self.rating = rating
        self.tags = tags
        self.albums = albums
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.hasLightCraftEdits = hasLightCraftEdits
        self.orientation = orientation
    }
}

public enum MetadataChange: Hashable, Sendable, Codable {
    case setRating(Int)
    case setFavorite(Bool)
    case setHidden(Bool)
    case addTag(String)
    case removeTag(String)
    case addToAlbum(String)
    case removeFromAlbum(String)
    /// Turns the photo a quarter turn, as `tiff:Orientation` in the sidecar; the image file is never touched.
    case rotate(clockwise: Bool)
}

public enum Keywords {
    public static let favorite = "Favorite"
    public static let hidden = "Hidden"
    public static let albumPrefix = "Albums|"
}
