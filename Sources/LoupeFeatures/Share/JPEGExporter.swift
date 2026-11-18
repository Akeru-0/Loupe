import Foundation
import ImageIO
import LoupeCore
import UniformTypeIdentifiers

/// Renders a JPEG (orientation baked in, optionally downsized, never upscaled). Works for RAW too.
public struct JPEGExporter: ShareExporter {
    public let id: String
    public let title: String
    public let maxLongEdge: Int?
    public let quality: Double

    public init(id: String, title: String, maxLongEdge: Int?, quality: Double) {
        self.id = id
        self.title = title
        self.maxLongEdge = maxLongEdge
        self.quality = quality
    }

    public static let highQuality = JPEGExporter(id: "hq", title: "High Quality", maxLongEdge: nil, quality: 0.85)
    public static let small = JPEGExporter(id: "small", title: "Small", maxLongEdge: 2048, quality: 0.80)

    public func canExport(_ kind: VersionKind) -> Bool { kind != .video && kind != .live }

    public func export(_ file: URL, kind: VersionKind, removeLocation: Bool, into directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { throw ShareExportError.unreadable(file) }
        let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = (sourceProps[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (sourceProps[kCGImagePropertyPixelHeight] as? Int) ?? 0
        var longEdge = max(w, h)
        if let maxLongEdge { longEdge = longEdge > 0 ? min(longEdge, maxLongEdge) : maxLongEdge }
        guard longEdge > 0 else { throw ShareExportError.unreadable(file) }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        else { throw ShareExportError.unreadable(file) }

        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
        ]
        if var exif = sourceProps[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            props[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = sourceProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let iptc = sourceProps[kCGImagePropertyIPTCDictionary] { props[kCGImagePropertyIPTCDictionary] = iptc }
        if !removeLocation, let gps = sourceProps[kCGImagePropertyGPSDictionary] { props[kCGImagePropertyGPSDictionary] = gps }

        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ShareExportError.encodeFailed(file) }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: folder)
            throw ShareExportError.encodeFailed(file)
        }
        return out
    }
}
