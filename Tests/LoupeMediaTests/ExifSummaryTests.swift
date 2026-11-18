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
        let values = ExifSummary.lines(for: url).map(\.value)
        #expect(values.contains("ƒ/2.8"))
        #expect(values.contains("1/250 s"))
        #expect(values.contains("ISO 100"))
        #expect(values.contains("35 mm"))
    }
}
