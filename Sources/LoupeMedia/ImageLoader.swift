import CoreGraphics
import Foundation
import ImageIO
import LoupeCore

public enum ImageLoader {
    /// Decodes an image whose long edge is at most `maxPixelSize`, shown with its own orientation and then turned
    /// by `rotation` (the photo's extra turn, `Orientation.rotation(override:baseEmbedded:)`). Also renders RAW.
    public static func image(at url: URL, maxPixelSize: Int, rotation: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(from: source, maxPixelSize: maxPixelSize, rotation: rotation)
    }

    public static func image(from source: CGImageSource, maxPixelSize: Int, rotation: Int?) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return turned(decoded, by: rotation)
    }

    /// The one rendering rule: `decoded` already shows the file's own orientation
    /// (`kCGImageSourceCreateThumbnailWithTransform`); the photo's rotation is applied on top.
    static func turned(_ decoded: CGImage, by rotation: Int?) -> CGImage? {
        guard let turn = Orientation.turn(rotation) else { return decoded }
        return turn.apply(to: decoded)
    }
}
