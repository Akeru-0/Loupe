import Foundation
import ImageIO
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeMedia

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-media-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct MediaInfoTests {
    @Test func readsExifDateWithOffset() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        try TestImages.makeJPEG(at: url, width: 40, height: 30, exif: [
            kCGImagePropertyExifDateTimeOriginal: "2026:09:06 14:30:00",
            kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
        ])
        let info = await MediaInfoReader.read(url, kind: .jpeg, rotation: nil)
        #expect(info.captureDate == ISO8601DateFormatter().date(from: "2026-09-06T12:30:00Z"))
    }

    @Test func swapsDimensionsForRotation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        try TestImages.makeJPEG(at: url, width: 400, height: 300, orientation: 6)
        let info = await MediaInfoReader.read(url, kind: .jpeg, rotation: nil)
        #expect(info.pixelWidth == 300)
        #expect(info.pixelHeight == 400)
    }

    @Test func readsCameraLensAndLocation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        try TestImages.makeJPEG(
            at: url, width: 40, height: 30,
            exif: [kCGImagePropertyExifLensModel: "EF-S18-55mm"],
            tiff: [kCGImagePropertyTIFFModel: "Canon EOS 600D"], gps: true)
        let info = await MediaInfoReader.read(url, kind: .jpeg, rotation: nil)
        #expect(info.cameraModel == "Canon EOS 600D")
        #expect(info.lensModel == "EF-S18-55mm")
        #expect(info.hasLocation)
    }
}
