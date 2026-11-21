import CoreGraphics
import Foundation

/// A decoded image as RGBA bytes, rows from the top: what faces are cut from.
struct RGBAImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Bilinear sample of channel `c` (0 red … 2 blue) at (`x`, `y`) in pixels from the top left; 0 outside.
    func sample(_ x: Double, _ y: Double, _ c: Int) -> Float {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        func at(_ px: Int, _ py: Int) -> Float {
            guard px >= 0, py >= 0, px < width, py < height else { return 0 }
            return Float(pixels[(py * width + px) * 4 + c])
        }
        let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
        let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// SFace's input: the face turned and scaled so its eyes, nose tip and mouth corners land on fixed points of a
/// 112 × 112 square (OpenCV's `FaceRecognizerSF.alignCrop`), as planar RGB floats 0…255 (1 × 3 × 112 × 112).
enum FaceAlignment {
    static let side = 112
    /// Image-left eye, image-right eye, nose tip, image-left and image-right mouth corner (OpenCV's reference).
    static let reference: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// The rotation + uniform scale + shift taking `source` closest to `target` (least squares; no mirroring):
    /// target ≈ [a −b; b a] · source + (tx, ty).
    struct Similarity: Equatable {
        var a: Double, b: Double, tx: Double, ty: Double

        func apply(_ p: CGPoint) -> CGPoint {
            CGPoint(x: a * p.x - b * p.y + tx, y: b * p.x + a * p.y + ty)
        }

        func inverse(_ p: CGPoint) -> CGPoint {
            let x = p.x - tx, y = p.y - ty, d = a * a + b * b
            return CGPoint(x: (a * x + b * y) / d, y: (-b * x + a * y) / d)
        }
    }

    static func similarity(from source: [CGPoint], to target: [CGPoint]) -> Similarity {
        let n = Double(source.count)
        let sx = source.map(\.x).reduce(0, +) / n, sy = source.map(\.y).reduce(0, +) / n
        let dx = target.map(\.x).reduce(0, +) / n, dy = target.map(\.y).reduce(0, +) / n
        var dot = 0.0, cross = 0.0, norm = 0.0
        for (s, t) in zip(source, target) {
            let (px, py, qx, qy) = (s.x - sx, s.y - sy, t.x - dx, t.y - dy)
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            norm += px * px + py * py
        }
        let a = norm > 0 ? dot / norm : 1, b = norm > 0 ? cross / norm : 0
        return Similarity(a: a, b: b, tx: dx - (a * sx - b * sy), ty: dy - (b * sx + a * sy))
    }

    /// The aligned face for `points` (the five landmarks, in pixels from the top left of `image`).
    static func input(from image: RGBAImage, points: [CGPoint]) -> [Float] {
        let transform = similarity(from: points, to: reference)
        let plane = side * side
        var input = [Float](repeating: 0, count: 3 * plane)
        for y in 0..<side {
            for x in 0..<side {
                let source = transform.inverse(CGPoint(x: Double(x), y: Double(y)))
                for c in 0..<3 { input[c * plane + y * side + x] = image.sample(source.x, source.y, c) }
            }
        }
        return input
    }
}
