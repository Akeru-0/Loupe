import Foundation

public struct MediaInfo: Equatable, Sendable {
    public var captureDate: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var cameraModel: String?
    public var lensModel: String?
    public var duration: Double?
    public var hasLocation: Bool

    public init(
        captureDate: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
        cameraModel: String? = nil, lensModel: String? = nil, duration: Double? = nil,
        hasLocation: Bool = false
    ) {
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.duration = duration
        self.hasLocation = hasLocation
    }
}
