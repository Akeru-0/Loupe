import Foundation

/// One row of the disposable index: a photo (all versions of one stem in one folder).
public struct PhotoRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64?
    public var locationId: String
    /// Relative to the location root; `""` is the root itself.
    public var folderPath: String
    public var stem: String
    public var stemKey: String
    public var captureDate: Date?
    public var addedDate: Date
    public var rating: Int
    public var isFavorite: Bool
    public var hasLightCraftEdits: Bool
    public var cameraModel: String?
    public var lensModel: String?
    public var hasRaw: Bool
    public var hasVideo: Bool
    public var sidecarModified: Date?
    /// Names and mtimes of legacy (`<file>.<ext>.xmp`) sidecars, so changes to them are noticed.
    public var legacySidecarFingerprint: String?
    /// The sidecar's `tiff:Orientation`, overriding the files' own orientation; nil when there is none.
    public var orientationOverride: Int?

    public init(
        id: Int64? = nil, locationId: String, folderPath: String, stem: String, stemKey: String,
        captureDate: Date? = nil, addedDate: Date, rating: Int = 0, isFavorite: Bool = false,
        hasLightCraftEdits: Bool = false, cameraModel: String? = nil, lensModel: String? = nil,
        hasRaw: Bool = false, hasVideo: Bool = false, sidecarModified: Date? = nil,
        legacySidecarFingerprint: String? = nil, orientationOverride: Int? = nil
    ) {
        self.id = id
        self.locationId = locationId
        self.folderPath = folderPath
        self.stem = stem
        self.stemKey = stemKey
        self.captureDate = captureDate
        self.addedDate = addedDate
        self.rating = rating
        self.isFavorite = isFavorite
        self.hasLightCraftEdits = hasLightCraftEdits
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.hasRaw = hasRaw
        self.hasVideo = hasVideo
        self.sidecarModified = sidecarModified
        self.legacySidecarFingerprint = legacySidecarFingerprint
        self.orientationOverride = orientationOverride
    }

    public var key: String { folderPath.isEmpty ? stem : folderPath + "/" + stem }
}
