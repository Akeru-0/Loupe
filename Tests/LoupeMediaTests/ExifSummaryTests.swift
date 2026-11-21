import Foundation
import ImageIO
import Testing
import LoupeTestSupport
@testable import LoupeMedia

@Suite struct ExifSummaryTests {
    @Test func formatsExposure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        try TestImages.makeJPEG(at: url, width: 40, height: 30, exif: [
            kCGImagePropertyExifFNumber: 2.8,
            kCGImagePropertyExifExposureTime: 0.004,
            kCGImagePropertyExifISOSpeedRatings: [100],
            kCGImagePropertyExifFocalLength: 35,
        ])
        let summary = ExifSummary(url: url)
        #expect(summary.aperture == "ƒ2.8")
        #expect(summary.shutter == "1/250 s")
        #expect(summary.iso == "ISO 100")
        #expect(summary.focalLength == "35 mm")
        #expect(summary.exposure == ["ISO 100", "35 mm", "ƒ2.8", "1/250 s"])
    }
}
