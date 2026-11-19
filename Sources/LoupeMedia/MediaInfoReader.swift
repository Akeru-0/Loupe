import AVFoundation
import Foundation
import ImageIO
import LoupeCore

public enum MediaInfoReader {
    /// Pixel width and height are as shown: with `orientation` (the photo's override) if set, else the file's own.
    /// Videos always use their own orientation.
    public static func read(_ url: URL, kind: VersionKind, orientation: Int?) async -> MediaInfo {
        switch kind {
        case .video, .live: return await readVideo(url)
        default: return readImage(url, override: orientation)
        }
    }

    private static func readImage(_ url: URL, override: Int?) -> MediaInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return MediaInfo() }

        var info = MediaInfo()
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        if let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
            formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
            info.captureDate = formatter.date(from: text)
        }

        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let swap = Orientation.effective(override: override, embedded: Orientation.embedded(in: source)).swapsDimensions
            info.pixelWidth = swap ? h : w
            info.pixelHeight = swap ? w : h
        }
        info.cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        info.lensModel = exif?[kCGImagePropertyExifLensModel] as? String
        info.hasLocation = props[kCGImagePropertyGPSDictionary] != nil
        return info
    }

    /// Parses "+02:00" / "-0530" / "Z" style offsets.
    private static func timeZone(fromOffset text: String) -> TimeZone? {
        if text == "Z" { return TimeZone(secondsFromGMT: 0) }
        let digits = text.dropFirst().filter(\.isNumber)
        guard let sign = text.first, sign == "+" || sign == "-", digits.count == 4,
            let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2))
        else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }

    private static func readVideo(_ url: URL) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        var info = MediaInfo()
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite else { return MediaInfo() }
            info.duration = duration
        } catch {
            return MediaInfo()
        }
        info.captureDate = try? await asset.load(.creationDate)?.load(.dateValue)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
            let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            info.pixelWidth = Int(abs(rect.width).rounded())
            info.pixelHeight = Int(abs(rect.height).rounded())
        }
        return info
    }
}
