import CoreGraphics
import Foundation
import ImageIO

/// An EXIF orientation (1…8): how stored pixels must be turned and mirrored to be shown upright.
///
/// Every value is "mirror horizontally (or not), then turn a number of quarter turns clockwise":
///
/// | EXIF | mirrored | quarter turns |
/// |---|---|---|
/// | 1 | no | 0 |  6 | no | 1 |  3 | no | 2 |  8 | no | 3 |
/// | 2 | yes | 0 |  7 | yes | 1 |  4 | yes | 2 |  5 | yes | 3 |
///
/// Composition and inverses are computed in that form, so rotating keeps any mirroring.
public struct Orientation: Hashable, Sendable {
    public let exif: Int

    public init?(exif: Int) {
        guard (1...8).contains(exif) else { return nil }
        self.exif = exif
    }

    public static let up = Orientation(exif: 1)!

    /// The photo's effective orientation: the sidecar's override if valid, else the file's own, else upright.
    public static func effective(override: Int?, embedded: Int?) -> Orientation {
        override.flatMap(Orientation.init(exif:)) ?? embedded.flatMap(Orientation.init(exif:)) ?? .up
    }

    /// The orientation ImageIO reports for the first image (EXIF/TIFF, or a RAW's own metadata), if any.
    public static func embedded(in source: CGImageSource) -> Int? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyOrientation] as? Int).flatMap { (1...8).contains($0) ? $0 : nil }
    }

    /// What the user sees, turned a further quarter turn.
    public func rotated(clockwise: Bool) -> Orientation {
        Orientation(Transform(quarterTurns: transform.quarterTurns + (clockwise ? 1 : 3), mirrored: transform.mirrored))
    }

    /// The transform to apply to an image already shown with `base` so that it is shown with `self`.
    public func relative(to base: Orientation) -> Orientation {
        Orientation(transform.after(base.transform.inverse))
    }

    /// `self` applied to an image already shown with `base`: the orientation that shows it in one step.
    /// Undoes `relative(to:)`: `b.relative(to: a).composed(after: a) == b`.
    public func composed(after base: Orientation) -> Orientation {
        Orientation(transform.after(base.transform))
    }

    /// The photo's **rotation**: the extra turn every version gets on top of its own orientation.
    /// A sidecar's `tiff:Orientation` (`override`) describes the file the sidecar belongs to
    /// (`PhotoGroup.orientationBase`), so the turn is the override relative to that file's own orientation
    /// (`baseEmbedded`). nil when there is no valid override or it says what that file already says.
    public static func rotation(override: Int?, baseEmbedded: Int?) -> Orientation? {
        guard let target = override.flatMap(Orientation.init(exif:)) else { return nil }
        let base = effective(override: nil, embedded: baseEmbedded)
        return target == base ? nil : target.relative(to: base)
    }

    /// A stored rotation (`PhotoRecord.rotation`) as a turn that changes anything; nil for none, invalid or 1.
    public static func turn(_ rotation: Int?) -> Orientation? {
        rotation.flatMap(Orientation.init(exif:)).flatMap { $0 == .up ? nil : $0 }
    }

    /// True when the shown image is the stored one with width and height exchanged.
    public var swapsDimensions: Bool { transform.quarterTurns % 2 == 1 }

    /// The image turned and mirrored as this orientation says. Pure pixel work, no file I/O.
    public func apply(to image: CGImage) -> CGImage? {
        guard self != .up else { return image }
        var width = CGFloat(image.width), height = CGFloat(image.height)
        // Device = transform(user). Each step maps the current upright picture into the next one's box.
        var ctm = CGAffineTransform.identity
        if transform.mirrored {
            ctm = ctm.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0))
        }
        for _ in 0..<transform.quarterTurns {
            // A clockwise quarter turn in y-up coordinates: (x, y) → (y, width − x).
            ctm = ctm.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width))
            swap(&width, &height)
        }
        guard let ctx = Self.context(like: image, width: Int(width), height: Int(height)) else { return nil }
        ctx.interpolationQuality = .none
        ctx.concatenate(ctm)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: - Representation

    private struct Transform: Hashable {
        /// Applied first, about the vertical axis.
        var mirrored: Bool
        /// Clockwise, 0…3, applied after the mirror.
        var quarterTurns: Int

        init(quarterTurns: Int, mirrored: Bool) {
            self.quarterTurns = ((quarterTurns % 4) + 4) % 4
            self.mirrored = mirrored
        }

        /// `self` after `other`: R^a M^m ∘ R^b M^n = R^(a ± b) M^(m xor n), since a mirror reverses turns (M R = R⁻¹ M).
        func after(_ other: Transform) -> Transform {
            Transform(quarterTurns: quarterTurns + (mirrored ? -other.quarterTurns : other.quarterTurns),
                      mirrored: mirrored != other.mirrored)
        }

        /// (R^q M^m)⁻¹ = M^m R^-q, which is R^q M when mirrored and R^-q otherwise.
        var inverse: Transform { Transform(quarterTurns: mirrored ? quarterTurns : -quarterTurns, mirrored: mirrored) }
    }

    private static let byExif: [Transform] = [
        Transform(quarterTurns: 0, mirrored: false),  // 1
        Transform(quarterTurns: 0, mirrored: true),  // 2
        Transform(quarterTurns: 2, mirrored: false),  // 3
        Transform(quarterTurns: 2, mirrored: true),  // 4
        Transform(quarterTurns: 3, mirrored: true),  // 5
        Transform(quarterTurns: 1, mirrored: false),  // 6
        Transform(quarterTurns: 1, mirrored: true),  // 7
        Transform(quarterTurns: 3, mirrored: false),  // 8
    ]

    private var transform: Transform { Self.byExif[exif - 1] }

    private init(_ transform: Transform) {
        exif = Self.byExif.firstIndex(of: transform)! + 1
    }

    /// An 8-bit context in the image's colour space where that works, else sRGB (or grey for grey images).
    private static func context(like image: CGImage, width: Int, height: Int) -> CGContext? {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if image.colorSpace?.model == .monochrome, !hasAlpha {
            return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        let info = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let own = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
        for space in [own, srgb].compactMap({ $0 }) {
            if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space, bitmapInfo: info) {
                return ctx
            }
        }
        return nil
    }
}
