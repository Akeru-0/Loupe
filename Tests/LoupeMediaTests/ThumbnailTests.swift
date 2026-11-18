import Foundation
import ImageIO
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeMedia

private func mediaFile(_ url: URL, modified: Date = Date(timeIntervalSince1970: 1_000_000)) -> MediaFile {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    return MediaFile(url: url, size: size, modified: modified, created: modified)
}

private let devRaw = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("dev-library/IMG_2174.CR2").path

@Suite struct ThumbnailTests {
    @Test func thumbnailIsBoundedAndCached() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("big.jpg")
        try TestImages.makeJPEG(at: src, width: 4000, height: 3000)
        let cacheDir = dir.appendingPathComponent("cache")
        let cache = ThumbnailCache(directory: cacheDir)
        let file = mediaFile(src)

        let first = try #require(await cache.thumbnail(for: file, kind: .jpeg))
        #expect((256...512).contains(max(first.width, first.height)))

        let key = ThumbnailCache.key(for: file)
        let cached = cacheDir.appendingPathComponent(String(key.prefix(2))).appendingPathComponent("\(key).jpg")
        #expect(FileManager.default.fileExists(atPath: cached.path))

        try FileManager.default.removeItem(at: src)
        let second = await cache.thumbnail(for: file, kind: .jpeg)
        #expect(second != nil)
    }

    @Test func keyChangesWhenFileChanges() {
        let url = URL(fileURLWithPath: "/tmp/x.jpg")
        let a = MediaFile(url: url, size: 10, modified: Date(timeIntervalSince1970: 1), created: Date(timeIntervalSince1970: 1))
        var b = a
        b.modified = Date(timeIntervalSince1970: 2)
        #expect(ThumbnailCache.key(for: a) != ThumbnailCache.key(for: b))
    }

    @Test func unreadableMediaYieldsNil() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.jpg")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let junk = dir.appendingPathComponent("junk.mov")
        try Data(repeating: 0x41, count: 2048).write(to: junk)
        let cacheDir = dir.appendingPathComponent("cache")
        let cache = ThumbnailCache(directory: cacheDir)

        #expect(await cache.thumbnail(for: mediaFile(empty), kind: .jpeg) == nil)
        #expect(await cache.thumbnail(for: mediaFile(junk), kind: .video) == nil)
        #expect(await MediaInfoReader.read(empty, kind: .jpeg) == MediaInfo())
        #expect(await MediaInfoReader.read(junk, kind: .video) == MediaInfo())

        let written = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: nil)?
            .allObjects.compactMap { $0 as? URL } ?? []
        let isEmpty = written.filter { $0.pathExtension == "jpg" }.isEmpty
        #expect(isEmpty)
    }

    @Test func loaderAppliesOrientation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        try TestImages.makeJPEG(at: url, width: 400, height: 300, orientation: 6)
        let image = try #require(ImageLoader.image(at: url, maxPixelSize: 1000))
        #expect(image.width == 300)
        #expect(image.height == 400)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: devRaw)))
    func realRawGetsLargeThumbnail() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailCache(directory: dir)
        let file = mediaFile(URL(fileURLWithPath: devRaw))
        let image = try #require(await cache.thumbnail(for: file, kind: .raw))
        #expect(max(image.width, image.height) >= 256)
    }
}
