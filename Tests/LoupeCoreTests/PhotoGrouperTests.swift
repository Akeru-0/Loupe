import Foundation
import Testing
@testable import LoupeCore

@Suite struct PhotoGrouperTests {
    let folder = URL(fileURLWithPath: "/fake/folder", isDirectory: true)
    let grouper = PhotoGrouper(editMarkers: ["-", "_edited", " (edited"])

    func file(_ name: String, modified: TimeInterval = 0) -> MediaFile {
        MediaFile(url: folder.appendingPathComponent(name), size: 1,
                  modified: Date(timeIntervalSince1970: modified),
                  created: Date(timeIntervalSince1970: 0))
    }

    func group(_ names: [String], sidecars: [String] = []) -> [PhotoGroup] {
        grouper.group(names.map { file($0) },
                      sidecars: sidecars.map { folder.appendingPathComponent($0) },
                      in: folder)
    }

    @Test func groupsRawAndJpegPair() {
        let groups = group(["IMG_1.CR2", "IMG_1.JPG"])
        #expect(groups.count == 1)
        #expect(groups[0].versions.map(\.kind) == [.raw, .jpeg])
        #expect(groups[0].displayVersion.kind == .jpeg)
    }

    @Test func attachesEditByMarker() {
        let groups = group(["IMG_1.CR2", "IMG_1-edited.jpeg"])
        #expect(groups.count == 1)
        #expect(groups[0].versions.map(\.kind) == [.raw, .edit])
        #expect(groups[0].displayVersion.kind == .edit)
    }

    @Test func attachesParenthesisedEdit() {
        #expect(group(["IMG_1.JPG", "IMG_1 (edited).jpg"]).count == 1)
    }

    @Test func chainsEdits() {
        let groups = grouper.group([
            file("IMG_1.JPG"),
            file("IMG_1-edit.jpg", modified: 10),
            file("IMG_1-edit-2.jpg", modified: 20),
        ], sidecars: [], in: folder)
        #expect(groups.count == 1)
        #expect(groups[0].versions.filter { $0.kind == .edit }.count == 2)
        #expect(groups[0].displayVersion.file.url.lastPathComponent == "IMG_1-edit-2.jpg")
    }

    @Test func keepsUnrelatedDashedNames() {
        let groups = group([
            "Screenshot 2026-10-12 at 10.23.07 AM.png",
            "Screenshot 2026-10-12 at 10.23.07 AM (2).png",
            "mendel identity and access - edited.png",
            "mendel identity and access 1.png",
        ])
        #expect(groups.count == 4)
    }

    @Test func neverMergesRawIntoAnother() {
        #expect(group(["IMG_1.JPG", "IMG_1-2.CR2"]).count == 2)
    }

    @Test func livePhotoVideoIsLive() {
        let groups = group(["IMG_1.HEIC", "IMG_1.MOV"])
        #expect(groups.count == 1)
        #expect(groups[0].versions.map(\.kind) == [.heic, .live])
        #expect(groups[0].displayVersion.kind == .heic)
    }

    @Test func loneVideoIsVideo() {
        #expect(group(["vid1.mov"])[0].versions.map(\.kind) == [.video])
    }

    @Test func stemsAreCaseInsensitive() {
        #expect(group(["IMG_1.CR2", "img_1.jpg"]).count == 1)
    }

    @Test func stemsAreNormalisationInsensitive() {
        #expect(group(["Z\u{30C}lut\u{30C}.JPG", "Žluť.CR2"]).count == 1)
    }

    @Test func attachesSidecars() {
        let groups = group(["IMG_1.CR2"], sidecars: ["IMG_1.XMP", "IMG_1.CR2.xmp"])
        #expect(groups[0].sidecar?.lastPathComponent == "IMG_1.XMP")
        #expect(groups[0].legacySidecars.map(\.lastPathComponent) == ["IMG_1.CR2.xmp"])
        #expect(groups[0].allFiles.count == 3)

        let bare = group(["IMG_1.CR2"])
        #expect(bare[0].sidecar == nil)
        #expect(bare[0].sidecarURLForWriting == folder.appendingPathComponent("IMG_1.xmp"))
    }

    @Test func classifierIgnoresNonMedia() {
        #expect(MediaClassifier.baseKind(forExtension: "txt") == nil)
        #expect(MediaClassifier.baseKind(forExtension: "xmp") == nil)
        #expect(MediaClassifier.baseKind(forExtension: "DS_Store") == nil)
    }
}
