import Foundation
import ImageIO

/// Human-readable camera and exposure lines for the Info panel. Reads only the file's properties (no decode).
public enum ExifSummary {
    public static func lines(for url: URL) -> [(label: String, value: String)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [] }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var lines: [(label: String, value: String)] = []

        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let camera = model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        if !camera.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(("Camera", camera.trimmingCharacters(in: .whitespaces)))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty { lines.append(("Lens", lens)) }
        if let f = number(exif[kCGImagePropertyExifFNumber]), f > 0 { lines.append(("Aperture", "ƒ/\(decimal(f))")) }
        if let t = number(exif[kCGImagePropertyExifExposureTime]), t > 0 { lines.append(("Shutter", shutter(t))) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first.flatMap(number), iso > 0 {
            lines.append(("ISO", "ISO \(Int(iso.rounded()))"))
        }
        if let focal = number(exif[kCGImagePropertyExifFocalLength]), focal > 0 {
            lines.append(("Focal length", "\(decimal(focal)) mm"))
        }
        if let bias = number(exif[kCGImagePropertyExifExposureBiasValue]), abs(bias) >= 0.05 {
            lines.append(("Exposure bias", "\(bias > 0 ? "+" : "")\(decimal(bias)) EV"))
        }
        return lines
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// One decimal at most: 2.8 → "2.8", 8.0 → "8".
    private static func decimal(_ x: Double) -> String {
        let r = (x * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    /// 0.004 → "1/250 s"; 0.4 → "0.4 s"; 2 → "2 s".
    private static func shutter(_ t: Double) -> String {
        if t < 1 {
            let n = 1 / t
            if abs(n - n.rounded()) / n < 0.05 { return "1/\(Int(n.rounded())) s" }
        }
        return "\(decimal(t)) s"
    }
}
