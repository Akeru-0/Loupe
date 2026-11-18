import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum TestImages {
    public struct TestImageError: Error { public let message: String }

    /// Writes a small solid-colour JPEG, optionally with EXIF/TIFF/GPS properties and embedded XMP.
    public static func makeJPEG(
        at url: URL,
        width: Int,
        height: Int,
        orientation: Int = 1,
        exif: [CFString: Any] = [:],
        tiff: [CFString: Any] = [:],
        gps: Bool = false,
        embeddedXMP: (rating: Int, subjects: [String])? = nil,
        creatorTool: String? = nil
    ) throws {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = {
            ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()
        }(ctx) else { throw TestImageError(message: "cannot create bitmap") }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw TestImageError(message: "cannot create destination") }

        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }
        if gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 64.1466,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 21.9426,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any]
        }

        if embeddedXMP != nil || creatorTool != nil {
            let xmp = embeddedXMP ?? (rating: 0, subjects: [])
            let metadata = CGImageMetadataCreateMutable()
            let rating = CGImageMetadataTagCreate(
                kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic,
                "Rating" as CFString, .string, String(xmp.rating) as CFString)
            let subjects = xmp.subjects.compactMap {
                CGImageMetadataTagCreate(
                    kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                    "subject" as CFString, .string, $0 as CFString)
            }
            guard let rating,
                CGImageMetadataSetTagWithPath(metadata, nil, "xmp:Rating" as CFString, rating),
                let bag = CGImageMetadataTagCreate(
                    kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                    "subject" as CFString, .arrayUnordered, subjects as CFArray),
                CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, bag)
            else { throw TestImageError(message: "cannot build XMP metadata") }
            if let creatorTool {
                guard let tool = CGImageMetadataTagCreate(
                    kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic,
                    "CreatorTool" as CFString, .string, creatorTool as CFString),
                    CGImageMetadataSetTagWithPath(metadata, nil, "xmp:CreatorTool" as CFString, tool)
                else { throw TestImageError(message: "cannot build XMP metadata") }
            }
            CGImageDestinationAddImageAndMetadata(dest, image, metadata, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw TestImageError(message: "finalize failed") }
    }
}
