import Foundation
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
}
