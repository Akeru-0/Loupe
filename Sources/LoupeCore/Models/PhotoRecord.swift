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
    public var isHidden: Bool
    public var hasLightCraftEdits: Bool
    public var cameraModel: String?
    public var lensModel: String?
    public var hasRaw: Bool
    public var hasVideo: Bool
    public var sidecarModified: Date?
    /// Names and mtimes of legacy (`<file>.<ext>.xmp`) sidecars, so changes to them are noticed.
    public var legacySidecarFingerprint: String?
    /// The sidecar's `tiff:Orientation`, read against the file the sidecar describes (`PhotoGroup.orientationBase`);
    /// nil when there is none or it only repeats that file's own orientation.
    public var orientationOverride: Int?
    /// The extra turn (EXIF value) every version is shown with on top of its own orientation; nil for none.
    /// See `Orientation.rotation(override:baseEmbedded:)`.
    public var rotation: Int?
    /// The newest of: the newest edit version's mtime, and the sidecar's mtime if it has LightCraft edits.
    /// Nil for a photo never edited. Recently Edited lists by it.
    public var lastEditedAt: Date?

    public init(
        id: Int64? = nil, locationId: String, folderPath: String, stem: String, stemKey: String,
        captureDate: Date? = nil, addedDate: Date, rating: Int = 0, isFavorite: Bool = false, isHidden: Bool = false,
        hasLightCraftEdits: Bool = false, cameraModel: String? = nil, lensModel: String? = nil,
        hasRaw: Bool = false, hasVideo: Bool = false, sidecarModified: Date? = nil,
        legacySidecarFingerprint: String? = nil, orientationOverride: Int? = nil,
        rotation: Int? = nil, lastEditedAt: Date? = nil
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
        self.isHidden = isHidden
        self.hasLightCraftEdits = hasLightCraftEdits
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.hasRaw = hasRaw
        self.hasVideo = hasVideo
        self.sidecarModified = sidecarModified
        self.legacySidecarFingerprint = legacySidecarFingerprint
        self.orientationOverride = orientationOverride
        self.rotation = rotation
        self.lastEditedAt = lastEditedAt
    }

    public var key: String { folderPath.isEmpty ? stem : folderPath + "/" + stem }
}
