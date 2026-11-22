import Foundation
import LoupeCore
import LoupeFeatures
import LoupeIndex
import Testing
@testable import LoupeUI

private func set() -> DuplicateSet {
    // 1 and 2 are the same JPEG; 2 also has its own edit.
    DuplicateSet(
        id: 1,
        members: [
            .init(photoId: 1, versionPath: "a/IMG_1.jpg", kind: .jpeg, folder: "a", size: 10, sha256: "x"),
            .init(photoId: 2, versionPath: "Trip:2024/IMG_1.jpg", kind: .jpeg, folder: "Trip:2024", size: 10, sha256: "x"),
        ],
        copies: [
            .init(photoId: 1, folder: "a", stem: "IMG_1", captureDate: nil, bytes: 10, mediaFileCount: 1, redundant: true),
            .init(photoId: 2, folder: "Trip:2024", stem: "IMG_1", captureDate: nil, bytes: 30, mediaFileCount: 2,
                  redundant: false),
        ])
}

private final class Prefs: PreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}

@MainActor @Suite struct DuplicatesModelTests {
    @Test func copyStatusFollowsTheKeptPhoto() {
        let s = set()
        // Nothing kept yet: only a copy with files of its own is marked.
        #expect(DuplicatesModel.status(of: s.copies[0], in: s, kept: nil) == .undecided)
        #expect(DuplicatesModel.status(of: s.copies[1], in: s, kept: nil) == .notRemovable)
        #expect(DuplicatesModel.status(of: s.copies[1], in: s, kept: 2) == .kept)
        #expect(DuplicatesModel.status(of: s.copies[0], in: s, kept: 2) == .removable)
        #expect(DuplicatesModel.status(of: s.copies[1], in: s, kept: 1) == .notRemovable)
    }

    @Test func aRuleChoosesTheCopyToKeepInEverySet() {
        let s = set()
        // Most complete: 2 has the JPEG and its edit; keeping it lets 1 go.
        #expect(DuplicatesModel.keeper(for: s, rule: .mostComplete) == 2)
        #expect(DuplicatesModel.keeper(for: s, rule: .folder("a")) == 1)
        #expect(DuplicatesModel.keeper(for: s, rule: .folder("Elsewhere")) == nil)  // left as it is

        // In an album: over the Photos folder and the top of the library, whatever is more complete.
        let photos = DuplicateSet(
            id: 2,
            members: [
                .init(photoId: 5, versionPath: "Photos/2024/IMG_5.jpg", kind: .jpeg, folder: "Photos/2024", size: 10, sha256: "y"),
                .init(photoId: 6, versionPath: "Iceland/IMG_5.jpg", kind: .jpeg, folder: "Iceland", size: 10, sha256: "y"),
                .init(photoId: 7, versionPath: "IMG_5.jpg", kind: .jpeg, folder: "", size: 10, sha256: "y"),
            ],
            copies: [
                .init(photoId: 5, folder: "Photos/2024", stem: "IMG_5", captureDate: nil, bytes: 99, mediaFileCount: 1, redundant: true),
                .init(photoId: 6, folder: "Iceland", stem: "IMG_5", captureDate: nil, bytes: 10, mediaFileCount: 1, redundant: true),
                .init(photoId: 7, folder: "", stem: "IMG_5", captureDate: nil, bytes: 10, mediaFileCount: 1, redundant: true),
            ])
        #expect(DuplicatesModel.keeper(for: photos, rule: .inAlbum) == 6)
        #expect(DuplicatesModel.keeper(for: photos, rule: .mostComplete) == 5)  // the biggest when all are equal
        #expect(DuplicatesModel.selectedTrashDetail(sets: 2)
            == "They're identical copies of the photos kept in 2 sets, which stay. You can put them back from the Trash in Finder.")
    }

    @Test func texts() {
        #expect(DuplicatesModel.summary(sets: 1, reclaimable: 0).hasPrefix("1 duplicate set, "))
        #expect(DuplicatesModel.summary(sets: 3, reclaimable: 5_000_000).hasPrefix("3 duplicate sets, "))
        #expect(DuplicatesModel.summary(sets: 3, reclaimable: 5_000_000).hasSuffix(" reclaimable"))
        #expect(DuplicatesModel.folderName("") == "Library")
        #expect(DuplicatesModel.folderName("Trip:2024/Day 1") == "Trip/2024 ▸ Day 1")
        let kept = set().copies[1]
        #expect(DuplicatesModel.trashQuestion(count: 1) == "Move 1 photo to Trash?")
        #expect(DuplicatesModel.trashQuestion(count: 2) == "Move 2 photos to Trash?")
        #expect(DuplicatesModel.trashDetail(kept: kept, count: 2)
            == "They're identical copies of “IMG_1” in Trip/2024, which stays. You can put them back from the Trash in Finder.")
        #expect(DuplicatesModel.trashDetail(kept: set().copies[0], count: 1)
            == "It's an identical copy of “IMG_1” in a, which stays. You can put it back from the Trash in Finder.")
    }

    @Test func tickingASetPicksItsCopyToKeepUnlessOneWasChosen() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-dup-\(UUID().uuidString)")
        let model = DuplicatesModel(app: AppModel(
            preferences: Prefs(), rootOverride: nil, supportDirectory: dir, cacheDirectory: dir))
        let s = set()
        model.setSelected(s, true)
        #expect(model.selected == [1] && model.kept[1] == 2)  // the most complete
        model.setSelected(s, false)
        model.kept[1] = 1  // chosen by hand
        model.setSelected(s, true)
        #expect(model.kept[1] == 1)  // kept as chosen
    }
}
