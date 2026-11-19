import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import LoupeCore
import LoupeTestSupport
@testable import LoupeMedia

private let devRaw = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("dev-library/IMG_2174.CR2").path

private func mediaFile(_ url: URL) -> MediaFile {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    let modified = Date(timeIntervalSince1970: 1_000_000)
    return MediaFile(url: url, size: size, modified: modified, created: modified)
}

/// A lossless 40×20 TIFF with four flat quadrants of different colours, tagged with `orientation`.
private func quadrantTIFF(at url: URL, orientation: Int) throws {
    let w = 40, h = 20
    let ctx = try #require(CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let colours: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
    for (i, c) in colours.enumerated() {
        ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fill(CGRect(x: (i % 2) * w / 2, y: (i / 2) * h / 2, width: w / 2, height: h / 2))
    }
    let image = try #require(ctx.makeImage())
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

private func pixels(_ image: CGImage) throws -> [Int] {
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = try #require(CGContext(
        data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return [w, h] + bytes.map(Int.init)
}

@Suite struct OrientedRenderingTests {
    let dir: URL

    init() throws { dir = try makeTempDir() }

    func jpeg(_ name: String, orientation: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try TestImages.makeJPEG(at: url, width: 400, height: 300, orientation: orientation)
        return url
    }

    @Test func thumbnailHonoursOverride() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailCache(directory: dir.appendingPathComponent("cache"))
        let file = mediaFile(try jpeg("a.jpg"))
        let plain = try #require(await cache.thumbnail(for: file, kind: .jpeg, orientation: nil))
        #expect(plain.width > plain.height)
        let turned = try #require(await cache.thumbnail(for: file, kind: .jpeg, orientation: 6))
        #expect(turned.height > turned.width)
        // A file shown portrait by its own EXIF, overridden back to 1.
        let upright = mediaFile(try jpeg("b.jpg", orientation: 6))
        let own = try #require(await cache.thumbnail(for: upright, kind: .jpeg, orientation: nil))
        #expect(own.height > own.width)
        let back = try #require(await cache.thumbnail(for: upright, kind: .jpeg, orientation: 1))
        #expect(back.width > back.height)
    }

    @Test func overrideChangesCacheKey() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = mediaFile(try jpeg("a.jpg"))
        let keys = [nil, 1, 3, 6, 8].map { ThumbnailCache.key(for: file, orientation: $0) }
        #expect(Set(keys).count == keys.count)
        // A cached rotated thumbnail is never handed out for the unrotated photo (or the other way round).
        let cache = ThumbnailCache(directory: dir.appendingPathComponent("cache"))
        _ = await cache.thumbnail(for: file, kind: .jpeg, orientation: 6)
        let plain = try #require(await cache.thumbnail(for: file, kind: .jpeg, orientation: nil))
        #expect(plain.width > plain.height)
        let turned = try #require(await cache.thumbnail(for: file, kind: .jpeg, orientation: 6))
        #expect(turned.height > turned.width)
    }

    @Test func loaderHonoursOverride() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try jpeg("a.jpg")
        let plain = try #require(ImageLoader.image(at: url, maxPixelSize: 1000, orientation: nil))
        #expect(plain.width == 400 && plain.height == 300)
        let turned = try #require(ImageLoader.image(at: url, maxPixelSize: 1000, orientation: 8))
        #expect(turned.width == 300 && turned.height == 400)
        let flipped = try #require(ImageLoader.image(at: url, maxPixelSize: 1000, orientation: 3))
        #expect(flipped.width == 400 && flipped.height == 300)
    }

    /// Every embedded orientation (mirrored ones included) overridden with every orientation looks exactly like a
    /// file that has the override as its own orientation.
    @Test func overrideOnAnyEmbeddedMatchesNativeOrientation() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        var native: [Int: [Int]] = [:]
        for o in 1...8 {
            let url = dir.appendingPathComponent("native-\(o).tif")
            try quadrantTIFF(at: url, orientation: o)
            native[o] = try pixels(try #require(ImageLoader.image(at: url, maxPixelSize: 40, orientation: nil)))
        }
        let cache = ThumbnailCache(directory: dir.appendingPathComponent("cache"), maxPixelSize: 40)
        for embedded in 1...8 {
            let url = dir.appendingPathComponent("native-\(embedded).tif")
            for override in 1...8 {
                let loaded = try #require(ImageLoader.image(at: url, maxPixelSize: 40, orientation: override))
                #expect(try pixels(loaded) == native[override], "embedded \(embedded), override \(override)")
                let thumb = try #require(await cache.thumbnail(for: mediaFile(url), kind: .image, orientation: override))
                #expect(thumb.width == loaded.width && thumb.height == loaded.height)
            }
        }
    }

    @Test func mediaInfoSwapsForEffectiveOrientation() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try jpeg("a.jpg")
        var info = await MediaInfoReader.read(plain, kind: .jpeg, orientation: nil)
        #expect(info.pixelWidth == 400 && info.pixelHeight == 300)
        info = await MediaInfoReader.read(plain, kind: .jpeg, orientation: 6)
        #expect(info.pixelWidth == 300 && info.pixelHeight == 400)
        let portrait = try jpeg("b.jpg", orientation: 8)
        info = await MediaInfoReader.read(portrait, kind: .jpeg, orientation: nil)
        #expect(info.pixelWidth == 300 && info.pixelHeight == 400)
        info = await MediaInfoReader.read(portrait, kind: .jpeg, orientation: 2)
        #expect(info.pixelWidth == 400 && info.pixelHeight == 300)
    }

    /// The dev RAW's own orientation (6) comes from the RAW metadata, not from a JPEG's EXIF.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: devRaw)))
    func rawOrientationFromRawMetadata() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(fileURLWithPath: devRaw)
        let cache = ThumbnailCache(directory: dir.appendingPathComponent("cache"))
        let own = try #require(await cache.thumbnail(for: mediaFile(url), kind: .raw, orientation: nil))
        #expect(own.height > own.width)
        let unrotated = try #require(await cache.thumbnail(for: mediaFile(url), kind: .raw, orientation: 1))
        #expect(unrotated.width > unrotated.height)
        let loaded = try #require(ImageLoader.image(at: url, maxPixelSize: 600, orientation: 1))
        #expect(loaded.width > loaded.height)
        let info = await MediaInfoReader.read(url, kind: .raw, orientation: 1)
        #expect(info.pixelWidth == 5184 && info.pixelHeight == 3456)
    }
}
