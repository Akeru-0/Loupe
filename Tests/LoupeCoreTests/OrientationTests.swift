import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LoupeCore

private let all = (1...8).map { Orientation(exif: $0)! }

/// A 3×2 RGBA image whose six pixels all differ, so every one of the eight orientations (and any dimension swap)
/// gives a different result.
private func sample() throws -> CGImage {
    var bytes: [UInt8] = []
    for i in 0..<6 { bytes += [UInt8(40 * i), UInt8(255 - 40 * i), UInt8(17 * i + 3), 255] }
    let ctx = try #require(CGContext(
        data: &bytes, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(ctx.makeImage())
}

/// Width, height and RGBA bytes (top row first) of `image`.
private func pixels(_ image: CGImage) throws -> [Int] {
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = try #require(CGContext(
        data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return [w, h] + bytes.map(Int.init)
}

@Suite struct OrientationTests {
    @Test func onlyExifValuesExist() {
        #expect(Orientation(exif: 0) == nil)
        #expect(Orientation(exif: 9) == nil)
        #expect(Orientation.up.exif == 1)
    }

    @Test func fourClockwiseTurnsReturnHome() {
        for o in all {
            #expect(o.rotated(clockwise: true).rotated(clockwise: true).rotated(clockwise: true).rotated(clockwise: true) == o)
            #expect(o.rotated(clockwise: false).rotated(clockwise: false).rotated(clockwise: false).rotated(clockwise: false) == o)
        }
    }

    @Test func clockwiseThenCounterIsIdentity() {
        for o in all {
            #expect(o.rotated(clockwise: true).rotated(clockwise: false) == o)
            #expect(o.rotated(clockwise: false).rotated(clockwise: true) == o)
        }
    }

    @Test func knownTable() {
        func cycle(from start: Int) -> [Int] {
            var o = Orientation(exif: start)!
            var out = [o.exif]
            for _ in 0..<4 {
                o = o.rotated(clockwise: true)
                out.append(o.exif)
            }
            return out
        }
        #expect(cycle(from: 1) == [1, 6, 3, 8, 1])
        #expect(cycle(from: 2) == [2, 7, 4, 5, 2])
    }

    @Test func swapsDimensionsForFiveToEight() {
        #expect(all.filter(\.swapsDimensions).map(\.exif) == [5, 6, 7, 8])
    }

    @Test func effectivePrefersOverrideThenEmbedded() {
        #expect(Orientation.effective(override: 8, embedded: 6).exif == 8)
        #expect(Orientation.effective(override: nil, embedded: 6).exif == 6)
        #expect(Orientation.effective(override: nil, embedded: nil) == .up)
        #expect(Orientation.effective(override: 0, embedded: 3).exif == 3)  // invalid values are ignored
    }

    /// Ground truth: ImageIO's own rendering of a lossless TIFF tagged with each orientation.
    @Test func applyMatchesImageIO() throws {
        let image = try sample()
        for o in all {
            let data = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: o.exif] as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            let source = try #require(CGImageSourceCreateWithData(data, nil))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3,
            ]
            let expected = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
            let actual = try #require(o.apply(to: image))
            #expect(try pixels(actual) == pixels(expected), "orientation \(o.exif)")
        }
    }

    @Test func relativeComposesBack() throws {
        let image = try sample()
        for a in all {
            let shownAsA = try #require(a.apply(to: image))
            for b in all {
                let corrected = try #require(b.relative(to: a).apply(to: shownAsA))
                let direct = try #require(b.apply(to: image))
                #expect(try pixels(corrected) == pixels(direct), "\(b.exif) relative to \(a.exif)")
            }
        }
    }

    @Test func composedAfterUndoesRelative() {
        for a in all {
            for b in all { #expect(b.relative(to: a).composed(after: a) == b, "\(b.exif) relative to \(a.exif)") }
            #expect(Orientation.up.composed(after: a) == a)
            #expect(a.composed(after: .up) == a)
        }
    }

    /// The sidecar's value is about the file it describes; every version gets the same extra turn from it.
    @Test func rotationIsRelativeToTheBaseFile() {
        #expect(Orientation.rotation(override: nil, baseEmbedded: 6) == nil)
        #expect(Orientation.rotation(override: 0, baseEmbedded: 6) == nil)  // invalid: no override
        #expect(Orientation.rotation(override: 6, baseEmbedded: 6) == nil)  // says what the file says
        #expect(Orientation.rotation(override: 1, baseEmbedded: nil) == nil)
        #expect(Orientation.rotation(override: 3, baseEmbedded: 6)?.exif == 6)  // a further quarter turn clockwise
        #expect(Orientation.rotation(override: 6, baseEmbedded: nil)?.exif == 6)
        #expect(Orientation.rotation(override: 1, baseEmbedded: 6)?.exif == 8)
        for base in all {
            for o in all where o != base {
                #expect(Orientation.rotation(override: o.exif, baseEmbedded: base.exif)?.composed(after: base) == o)
            }
        }
    }

    @Test func rotationTurnsTheShownImage() throws {
        // Rotating clockwise must turn what the user sees clockwise, whatever the starting orientation.
        let image = try sample()
        for o in all {
            let shown = try #require(o.apply(to: image))
            let turned = try #require(o.rotated(clockwise: true).apply(to: image))
            let expected = try #require(Orientation(exif: 6)!.apply(to: shown))
            #expect(try pixels(turned) == pixels(expected), "orientation \(o.exif)")
        }
    }
}
