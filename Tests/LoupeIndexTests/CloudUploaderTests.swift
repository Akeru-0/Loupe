import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeIndex

@Suite struct CloudUploaderTests {
    private struct Env {
        let lib: TestLibrary
        let library: Library
        let cloud: URL

        init() throws {
            lib = try TestLibrary()
            let support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
            library = try Library(
                location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path),
                registry: FeatureRegistry(), supportDirectory: support,
                cacheDirectory: support.appendingPathComponent("cache"))
            cloud = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-cloud-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        }

        func upload() async throws -> CloudUploadReport {
            try await CloudUploader(index: library.index, root: lib.root, destination: cloud).run()
        }

        /// Every file under the cloud folder, root-relative, hidden temp files included.
        func cloudFiles() -> [String] {
            ((FileManager.default.enumerator(atPath: cloud.path)?.allObjects as? [String]) ?? [])
                .filter { !$0.hasSuffix("/") && !isDirectory(cloud.appendingPathComponent($0)) }.sorted()
        }

        private func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    @Test func uploadsEverythingOnceThenOnlyWhatChanged() async throws {
        let e = try Env()
        try e.lib.addJPEG("Trip/IMG_1.jpg")
        try e.lib.addSidecar("Trip/IMG_1.xmp")
        try e.lib.addJPEG("IMG_2.jpg")
        try e.lib.addJPEG("Recently Deleted/IMG_3.jpg")  // deleted photos stay local
        _ = await e.library.initialSync()

        let first = try await e.upload()
        #expect(first.total == 3 && first.uploaded == 3 && first.failed == 0)
        #expect(e.cloudFiles() == ["IMG_2.jpg", "Trip/IMG_1.jpg", "Trip/IMG_1.xmp"])
        #expect(try Data(contentsOf: e.cloud.appendingPathComponent("Trip/IMG_1.jpg"))
                == Data(contentsOf: e.lib.url("Trip/IMG_1.jpg")))

        #expect(try await e.upload().uploaded == 0)  // nothing new

        try Data("changed".utf8).write(to: e.lib.url("Trip/IMG_1.xmp"))
        #expect(try await e.upload().uploaded == 1)
        #expect(try String(contentsOf: e.cloud.appendingPathComponent("Trip/IMG_1.xmp"), encoding: .utf8) == "changed")
    }

    @Test func failuresAreListedUntilARetrySucceeds() async throws {
        let e = try Env()
        try e.lib.addJPEG("Trip/IMG_1.jpg")
        try e.lib.addJPEG("IMG_2.jpg")
        _ = await e.library.initialSync()
        // A file where the Trip folder should be: IMG_1 can't be uploaded.
        try Data().write(to: e.cloud.appendingPathComponent("Trip"))

        let report = try await e.upload()
        #expect(report.uploaded == 1 && report.failed == 1 && report.firstFailure?.hasPrefix("IMG_1.jpg") == true)
        let failing = try e.library.index.sections(for: PhotoQuery(scope: .unableToUpload)).flatMap(\.photoIDs)
        #expect(try failing.compactMap { try e.library.index.photo(id: $0)?.key } == ["Trip/IMG_1"])
        #expect(try e.library.index.uploadFailurePhotoCount() == 1)

        try FileManager.default.removeItem(at: e.cloud.appendingPathComponent("Trip"))
        #expect(try await e.upload().uploaded == 1)  // retried: the failed file had no upload yet
        #expect(try e.library.index.uploadFailurePhotoCount() == 0)
        #expect(!e.cloudFiles().contains { $0.contains(".loupe-upload-") })  // no temp files left
    }

    @Test func aFolderInsideTheLibraryOrMissingIsRefused() async throws {
        let e = try Env()
        try e.lib.addJPEG("IMG_1.jpg")
        _ = await e.library.initialSync()
        let inside = e.lib.url("Backup")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        await #expect(throws: CloudUploadError.self) {
            try await CloudUploader(index: e.library.index, root: e.lib.root, destination: inside).run()
        }
        await #expect(throws: CloudUploadError.self) {
            try await CloudUploader(
                index: e.library.index, root: e.lib.root, destination: e.cloud.appendingPathComponent("missing")
            ).run()
        }
        #expect(try e.library.index.uploadFailurePhotoCount() == 0)  // nothing recorded per photo
    }
}
