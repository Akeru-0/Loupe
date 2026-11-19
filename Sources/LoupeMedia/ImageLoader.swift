import CoreGraphics
import Foundation
import ImageIO
import LoupeCore

public enum ImageLoader {
    /// Decodes an image shown with its effective orientation (`orientation`, the sidecar's override, else the
    /// file's own) whose long edge is at most `maxPixelSize`. Also renders RAW.
    public static func image(at url: URL, maxPixelSize: Int, orientation: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(from: source, maxPixelSize: maxPixelSize, orientation: orientation)
    }

    public static func image(from source: CGImageSource, maxPixelSize: Int, orientation: Int?) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return oriented(decoded, source: source, override: orientation)
    }

    /// The one orientation rule every renderer uses. `decoded` came from `source` with the file's own orientation
    /// applied (`kCGImageSourceCreateThumbnailWithTransform`); with an override, it is turned on from there.
    static func oriented(_ decoded: CGImage, source: CGImageSource, override: Int?) -> CGImage? {
        guard let target = override.flatMap(Orientation.init(exif:)) else { return decoded }
        let own = Orientation.effective(override: nil, embedded: Orientation.embedded(in: source))
        return target.relative(to: own).apply(to: decoded)
    }
}
