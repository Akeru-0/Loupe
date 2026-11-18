import Foundation
import ImageIO
import LoupeCore

public enum EmbeddedMetadataReader {
    /// Reads XMP embedded in an image file via ImageIO. Returns nil when there is none or it is unreadable.
    public static func metadata(in imageURL: URL) -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
            let embedded = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
            let data = CGImageMetadataCreateXMPData(embedded, nil) as Data?
        else { return nil }
        return try? XMPDocument(data: data).metadata
    }
}
