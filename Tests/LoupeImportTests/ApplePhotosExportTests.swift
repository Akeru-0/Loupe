import Foundation
import Testing
@testable import LoupeImport

@Suite struct ApplePhotosExportTests {
    @Test func theExportFollowsLoupesConventions() {
        let args = ApplePhotosExport.arguments(
            library: URL(fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary"),
            destination: URL(fileURLWithPath: "/Users/me/Pictures/Photos"),
            exportDB: URL(fileURLWithPath: "/support/apple-photos-export.db"))
        func value(_ flag: String) -> [String] {
            args.indices.filter { args[$0] == flag }.map { args[$0 + 1] }
        }
        #expect(Array(args.prefix(2)) == ["export", "/Users/me/Pictures/Photos"])
        #expect(value("--library") == ["/Users/me/Pictures/Photos Library.photoslibrary"])
        #expect(value("--directory") == ["{created.year}/{created.strftime,%Y-%m-%d}"])  // YYYY/YYYY-MM-DD
        #expect(value("--sidecar") == ["xmp"] && args.contains("--sidecar-drop-ext"))  // <stem>.xmp
        #expect(value("--edited-suffix") == ["-edited"])
        #expect(value("--keyword-template") == ["{favorite?Favorite,}", "{photo.hidden?Hidden,}", "Albums|{album,}"])
        #expect(args.contains("--update"))  // a second run copies only what's new
        #expect(value("--exportdb") == ["/support/apple-photos-export.db"])  // kept out of the library
    }

    @Test func progressAndSummaryAreReadFromItsOutput() {
        let p = ApplePhotosExport.progress(
            in: "Exporting IMG_9001.JPG (5C7D7977-573E-4008-8DAF-257124E545DA.jpeg) (12/2517)")
        #expect(p == ApplePhotosExport.Progress(done: 12, total: 2517, name: "IMG_9001.JPG"))
        #expect(ApplePhotosExport.progress(in: "Exporting 2517 photos to /x...") == nil)
        #expect(ApplePhotosExport.progress(in: "Exported IMG_9001.JPG to /x/2019/IMG_9001.JPG") == nil)

        var first = ApplePhotosExport.Summary()
        (first.processed, first.exported) = (2517, 2)
        #expect(ApplePhotosExport.summary(in: "Processed: 2517 photos, exported: 2, missing: 0, error: 0, limit: 2/2 exported")
                == first)
        var update = ApplePhotosExport.Summary()
        (update.processed, update.exported, update.updated, update.skipped, update.missing, update.errors) =
            (2517, 10, 3, 2400, 104, 1)
        #expect(ApplePhotosExport.summary(
            in: "Processed: 2517 photos, exported: 10, updated: 3, skipped: 2400, updated EXIF data: 0, missing: 104, error: 1")
                == update)
        #expect(ApplePhotosExport.summary(in: "Exporting 2517 photos") == nil)
    }

    @Test func aMissingPermissionIsRecognised() {
        #expect(ApplePhotosExport.isPermissionError("PermissionError: [Errno 1] Operation not permitted: '/Users/me/Pictures/Photos Library.photoslibrary/database/Photos.sqlite'"))
        #expect(!ApplePhotosExport.isPermissionError("Processed: 1 photos, exported: 1, missing: 0, error: 0"))
    }
}
