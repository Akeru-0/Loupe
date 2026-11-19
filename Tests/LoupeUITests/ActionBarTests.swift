import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

/// The toolbar's action capsule: what it acts on, the favorite rule it shares with F, and when each button works.
@MainActor @Suite struct ActionBarTests {
    private let sections = [
        PhotoSection(id: "a", title: "A", photoIDs: [30, 10]),
        PhotoSection(id: "b", title: "B", photoIDs: [20, 40]),
    ]
    private let root = URL(fileURLWithPath: "/tmp/lib", isDirectory: true)

    private func photo(_ id: Int64, favorite: Bool = false) -> PhotoRecord {
        PhotoRecord(id: id, locationId: "l", folderPath: "", stem: "p\(id)", stemKey: "p\(id)",
                    addedDate: Date(timeIntervalSince1970: 0), isFavorite: favorite)
    }

    private func version(_ photo: Int64, _ n: Int, _ kind: VersionKind, display: Bool) -> VersionRecord {
        VersionRecord(id: photo * 10 + Int64(n), photoId: photo, path: "p\(photo).\(kind)",
                      kind: kind, size: 1, modified: Date(timeIntervalSince1970: 0), isDisplay: display)
    }

    /// A loaded selection: each photo with its versions as (kind, isDisplay).
    private func selection(_ photos: [(PhotoRecord, [(VersionKind, Bool)])]) -> ActionSelection {
        var versions: [Int64: [VersionRecord]] = [:]
        for (p, vs) in photos { versions[p.id!] = vs.enumerated().map { version(p.id!, $0.offset, $0.element.0, display: $0.element.1) } }
        return ActionSelection(photos: photos.map(\.0), versions: versions, root: root)
    }

    // MARK: - Targets

    @Test func selectionIsTargetedInQueryOrder() {
        #expect(ActionBar.targets(viewerPhotoID: nil, selection: [40, 10, 30], sections: sections) == [30, 10, 40])
        // Ids the view no longer shows are left out.
        #expect(ActionBar.targets(viewerPhotoID: nil, selection: [99, 20], sections: sections) == [20])
        #expect(ActionBar.targets(viewerPhotoID: nil, selection: [], sections: sections).isEmpty)
    }

    @Test func viewerPhotoWinsOverTheSelection() {
        #expect(ActionBar.targets(viewerPhotoID: 20, selection: [30, 40], sections: sections) == [20])
        // Even when it has left the query (e.g. it was just un-favorited in Favorites).
        #expect(ActionBar.targets(viewerPhotoID: 77, selection: [30], sections: sections) == [77])
    }

    // MARK: - Favorite rule (shared with the F key)

    @Test func favoriteSetsAllUnlessAllAreFavorites() {
        #expect(ActionBar.favoriteValue(after: [false, false]) == true)
        #expect(ActionBar.favoriteValue(after: [true, false]) == true)
        #expect(ActionBar.favoriteValue(after: [true, true]) == false)
        #expect(ActionBar.favoriteValue(after: [true]) == false)
    }

    // MARK: - Enabled states

    @Test func nothingTargetedDisablesAllButPlay() {
        let state = ActionBarState(targets: [], loaded: nil, viewHasPhotos: true)
        #expect(!state.canInfo && !state.canShare && !state.canFavorite && !state.canRotate)
        #expect(!state.isFavorite)
        #expect(state.canPlay)  // starts from the first photo of the view
        #expect(!ActionBarState(targets: [], loaded: nil, viewHasPhotos: false).canPlay)
    }

    @Test func heartIsFilledOnlyWhenEveryTargetIsAFavorite() {
        let loaded = selection([(photo(1, favorite: true), [(.jpeg, true)]), (photo(2), [(.jpeg, true)])])
        let some = ActionBarState(targets: [1, 2], loaded: loaded, viewHasPhotos: true)
        #expect(some.canInfo && some.canShare && some.canFavorite && some.canPlay)
        #expect(!some.isFavorite)
        #expect(ActionBarState(targets: [1], loaded: loaded, viewHasPhotos: true).isFavorite)
        // Not loaded yet (the selection just changed): not shown as a favorite.
        #expect(!ActionBarState(targets: [1, 3], loaded: loaded, viewHasPhotos: true).isFavorite)
    }

    @Test func videosCannotBeRotated() {
        let loaded = selection([
            (photo(1), [(.video, true)]),
            (photo(2), [(.live, true)]),  // a Live Photo's motion file with no still
            (photo(3), [(.heic, true), (.live, false)]),  // a Live Photo: its still rotates
            (photo(4), [(.raw, false), (.jpeg, true)]),
        ])
        func canRotate(_ ids: [Int64]) -> Bool {
            ActionBarState(targets: ids, loaded: loaded, viewHasPhotos: true).canRotate
        }
        #expect(!canRotate([1]))
        #expect(!canRotate([1, 2]))
        #expect(canRotate([3]))
        #expect(canRotate([1, 4]))
        // Not loaded yet: not known to be a video, so the button stays usable (the action re-checks).
        #expect(canRotate([1, 9]))
        #expect(ActionBar.rotatable(in: loaded) == [3, 4])
    }

    // MARK: - Info

    @Test func infoForSeveralPhotosSummarisesWhatTheyShare() {
        let same = InfoSummary(metadata: [
            PhotoMetadata(rating: 3, tags: ["Iceland", "Beach"]),
            PhotoMetadata(rating: 3, tags: ["Iceland"]),
        ])
        #expect(same.count == 2)
        #expect(same.rating == 3)
        #expect(same.sharedTags == ["Iceland"])
        let mixed = InfoSummary(metadata: [PhotoMetadata(rating: 1), PhotoMetadata(rating: 4, tags: ["Zoo"])])
        #expect(mixed.rating == nil)
        #expect(mixed.sharedTags.isEmpty)
    }
}
