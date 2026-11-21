import Foundation
import ImageIO

/// Camera and exposure details for the Info panel, already formatted for display. Reads only the file's
/// properties (no decode). A field is nil when the file doesn't record it.
public struct ExifSummary: Sendable {
    public var camera: String?
    public var lens: String?
    /// "ISO 100"
    public var iso: String?
    /// "70 mm"
    public var focalLength: String?
    /// "0 ev", "+0.7 ev"
    public var exposureBias: String?
    /// "ƒ4", "ƒ2.8"
    public var aperture: String?
    /// "1/400 s", "2 s"
    public var shutter: String?
    /// The SF Symbol and name of the metering mode.
    public var metering: (symbol: String, name: String)?
    public var flashFired = false

    /// The exposure values in the order the Info panel lists them.
    public var exposure: [String] { [iso, focalLength, exposureBias, aperture, shutter].compactMap { $0 } }

    public init() {}

    public init(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let camera = (model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)")
            .trimmingCharacters(in: .whitespaces)
        if !camera.isEmpty { self.camera = camera }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty { self.lens = lens }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first.flatMap(Self.number), iso > 0 {
            self.iso = "ISO \(Int(iso.rounded()))"
        }
        if let focal = Self.number(exif[kCGImagePropertyExifFocalLength]), focal > 0 {
            focalLength = "\(Self.decimal(focal)) mm"
        }
        if let bias = Self.number(exif[kCGImagePropertyExifExposureBiasValue]) {
            exposureBias = abs(bias) < 0.05 ? "0 ev" : "\(bias > 0 ? "+" : "")\(Self.decimal(bias)) ev"
        }
        if let f = Self.number(exif[kCGImagePropertyExifFNumber]), f > 0 { aperture = "ƒ\(Self.decimal(f))" }
        if let t = Self.number(exif[kCGImagePropertyExifExposureTime]), t > 0 { shutter = Self.shutter(t) }
        if let mode = Self.number(exif[kCGImagePropertyExifMeteringMode]) { metering = Self.metering(Int(mode)) }
        if let flash = Self.number(exif[kCGImagePropertyExifFlash]) { flashFired = Int(flash) & 1 == 1 }
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

    /// EXIF MeteringMode → SF Symbol and name; nil for unknown or "other".
    private static func metering(_ mode: Int) -> (symbol: String, name: String)? {
        switch mode {
        case 1: ("camera.metering.center.weighted.average", "Average Metering")
        case 2: ("camera.metering.center.weighted", "Center-Weighted Metering")
        case 3: ("camera.metering.spot", "Spot Metering")
        case 4: ("camera.metering.multispot", "Multi-Spot Metering")
        case 5: ("camera.metering.matrix", "Pattern Metering")
        case 6: ("camera.metering.partial", "Partial Metering")
        default: nil
        }
    }
}
