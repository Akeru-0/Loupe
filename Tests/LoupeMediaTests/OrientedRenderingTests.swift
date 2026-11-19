import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
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

/// `rotation` is the photo's extra turn (the sidecar's `tiff:Orientation` relative to the file it describes),
/// applied on top of each file's own orientation.
@Suite struct OrientedRenderingTests {
    let dir: URL

    init() throws { dir = try makeTempDir() }

    func jpeg(_ name: String, orientation: Int = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try TestImages.makeJPEG(at: url, width: 400, height: 300, orientation: orientation)
        return url
    }

    @Test func thumbnailHonoursRotation() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailCache(directory: dir.appendingPathComponent("cache"))
        let file = mediaFile(try jpeg("a.jpg"))
        let plain = try #require(await cache.thumbnail(for: file, kind: .jpeg, rotation: nil))
        #expect(plain.width > plain.height)
        let turned = try #require(await cache.thumbnail(for: file, kind: .jpeg, rotation: 6))
        #expect(turned.height > turned.width)
        // A file shown portrait by its own EXIF, turned a quarter back.
        let upright = mediaFile(try jpeg("b.jpg", orientation: 6))
        let own = try #require(await cache.thumbnail(for: upright, kind: .jpeg, rotation: nil))
        #expect(own.height > own.width)
        let back = try #require(await cache.thumbnail(for: upright, kind: .jpeg, rotation: 8))
        #expect(back.width > back.height)
    }

    @Test func rotationChangesCacheKey() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = mediaFile(try jpeg("a.jpg"))
        let keys = [nil, 2, 3, 6, 8].map { ThumbnailCache.key(for: file, rotation: $0) }
        #expect(Set(keys).count == keys.count)
        #expect(ThumbnailCache.key(for: file, rotation: 1) == ThumbnailCache.key(for: file, rotation: nil))
        // The earlier build tagged its orientation override "|o<n>": those disk thumbnails must not be reused.
        let base = "\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)"
        func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(ThumbnailCache.key(for: file, rotation: 6) == hash(base + "|r6"))
        #expect(ThumbnailCache.key(for: file, rotation: 6) != hash(base + "|o6"))
        // A cached rotated thumbnail is never handed out for the unrotated photo (or the other way round).
        let cache = ThumbnailCache(directory: dir.appendingPathComponent("cache"))
        _ = await cache.thumbnail(for: file, kind: .jpeg, rotation: 6)
        let plain = try #require(await cache.thumbnail(for: file, kind: .jpeg, rotation: nil))
        #expect(plain.width > plain.height)
        let turned = try #require(await cache.thumbnail(for: file, kind: .jpeg, rotation: 6))
        #expect(turned.height > turned.width)
    }

    @Test func loaderHonoursRotation() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try jpeg("a.jpg")
        let plain = try #require(ImageLoader.image(at: url, maxPixelSize: 1000, rotation: nil))
        #expect(plain.width == 400 && plain.height == 300)
        let turned = try #require(ImageLoader.image(at: url, maxPixelSize: 1000, rotation: 8))
        #expect(turned.width == 300 && turned.height == 400)
        let flipped = try #require(ImageLoader.image(at: url, maxPixelSize: 1000, rotation: 3))
        #expect(flipped.width == 400 && flipped.height == 300)
    }

    /// For every own orientation (mirrored ones included) and every rotation: the file is shown as it shows by
    /// itself, then turned; that equals a file whose own orientation is the composition.
    @Test func rotationOnTopOfAnyOwnOrientation() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        var native: [Int: [Int]] = [:]
        for o in 1...8 {
            let url = dir.appendingPathComponent("native-\(o).tif")
            try TestImages.makeQuadrantTIFF(at: url, width: 40, height: 20, orientation: o)
            native[o] = TestImages.pixels(try #require(ImageLoader.image(at: url, maxPixelSize: 40, rotation: nil)))
        }
        let cache = ThumbnailCache(directory: dir.appendingPathComponent("cache"), maxPixelSize: 40)
        for own in 1...8 {
            let url = dir.appendingPathComponent("native-\(own).tif")
            let shown = try #require(ImageLoader.image(at: url, maxPixelSize: 40, rotation: nil))
            for r in 1...8 {
                let rotation = Orientation(exif: r)!
                let loaded = try #require(ImageLoader.image(at: url, maxPixelSize: 40, rotation: r))
                #expect(TestImages.pixels(loaded) == TestImages.pixels(try #require(rotation.apply(to: shown))))
                let composed = rotation.composed(after: Orientation(exif: own)!).exif
                #expect(TestImages.pixels(loaded) == native[composed], "own \(own), rotation \(r)")
                let thumb = try #require(await cache.thumbnail(for: mediaFile(url), kind: .image, rotation: r))
                #expect(TestImages.pixels(thumb) == TestImages.pixels(loaded))
            }
        }
    }

    @Test func mediaInfoSwapsForRotation() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try jpeg("a.jpg")
        var info = await MediaInfoReader.read(plain, kind: .jpeg, rotation: nil)
        #expect(info.pixelWidth == 400 && info.pixelHeight == 300)
        info = await MediaInfoReader.read(plain, kind: .jpeg, rotation: 6)
        #expect(info.pixelWidth == 300 && info.pixelHeight == 400)
        let portrait = try jpeg("b.jpg", orientation: 8)
        info = await MediaInfoReader.read(portrait, kind: .jpeg, rotation: nil)
        #expect(info.pixelWidth == 300 && info.pixelHeight == 400)
        info = await MediaInfoReader.read(portrait, kind: .jpeg, rotation: 6)
        #expect(info.pixelWidth == 400 && info.pixelHeight == 300)
        info = await MediaInfoReader.read(portrait, kind: .jpeg, rotation: 2)
        #expect(info.pixelWidth == 300 && info.pixelHeight == 400)
    }

    /// The dev RAW's own orientation (6) comes from the RAW metadata, not from a JPEG's EXIF.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: devRaw)))
    func rawOrientationFromRawMetadata() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(fileURLWithPath: devRaw)
        let cache = ThumbnailCache(directory: dir.appendingPathComponent("cache"))
        let own = try #require(await cache.thumbnail(for: mediaFile(url), kind: .raw, rotation: nil))
        #expect(own.height > own.width)
        let turnedBack = try #require(await cache.thumbnail(for: mediaFile(url), kind: .raw, rotation: 8))
        #expect(turnedBack.width > turnedBack.height)
        let loaded = try #require(ImageLoader.image(at: url, maxPixelSize: 600, rotation: 8))
        #expect(loaded.width > loaded.height)
        #expect(await MediaInfoReader.read(url, kind: .raw, rotation: nil).pixelWidth == 3456)
        let info = await MediaInfoReader.read(url, kind: .raw, rotation: 8)
        #expect(info.pixelWidth == 5184 && info.pixelHeight == 3456)
    }
}
