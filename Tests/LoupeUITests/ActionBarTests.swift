import Foundation
import LoupeCore
import LoupeFeatures
import LoupeIndex
import Testing
@testable import LoupeUI

/// The toolbar's action capsule: what it acts on, the favorite rule it shares with F, and when each button works.
private final class MemoryPreferences: PreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}

@MainActor @Suite struct ActionBarTests {
    private let sections = [
        PhotoSection(id: "a", title: "A", photoIDs: [30, 10]),
        PhotoSection(id: "b", title: "B", photoIDs: [20, 40]),
    ]

    private func flags(_ entries: [(Int64, Bool, VersionKind?)]) -> [Int64: ActionFlags] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.0, ActionFlags(isFavorite: $0.1, displayKind: $0.2)) })
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

    @Test func nothingIsTargetedBehindTheImportWindowOrTheTagEditor() {
        #expect(ActionBar.targets(viewerPhotoID: nil, selection: [30], sections: sections, showsImport: true).isEmpty)
        #expect(ActionBar.targets(viewerPhotoID: 20, selection: [], sections: sections, showsImport: true).isEmpty)
        #expect(ActionBar.targets(viewerPhotoID: nil, selection: [30], sections: sections, editsTags: true).isEmpty)
        #expect(ActionBar.targets(viewerPhotoID: 20, selection: [], sections: sections, editsTags: true).isEmpty)
    }

    @Test func theModelTargetsNothingWhileTheTagEditorIsOpen() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-ui-\(UUID().uuidString)")
        let model = AppModel(preferences: MemoryPreferences(), rootOverride: nil, supportDirectory: dir, cacheDirectory: dir)
        model.viewerPhotoID = 5
        #expect(model.actionTargetIDs == [5])
        model.tagEditorPhotoIDs = [5]
        #expect(model.actionTargetIDs.isEmpty)
        #expect(!model.actionBarState.canRotate && !model.actionBarState.canPlay)
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
        let state = ActionBarState(targets: [], flags: [:], viewHasPhotos: true)
        #expect(!state.canInfo && !state.canShare && !state.canFavorite && !state.canRotate)
        #expect(!state.isFavorite)
        #expect(state.canPlay)  // starts from the first photo of the view
        #expect(!ActionBarState(targets: [], flags: [:], viewHasPhotos: false).canPlay)
    }

    @Test func heartIsFilledOnlyWhenEveryTargetIsAFavorite() {
        let loaded = flags([(1, true, .jpeg), (2, false, .jpeg)])
        let some = ActionBarState(targets: [1, 2], flags: loaded, viewHasPhotos: true)
        #expect(some.canInfo && some.canShare && some.canFavorite && some.canPlay)
        #expect(!some.isFavorite)
        #expect(ActionBarState(targets: [1], flags: loaded, viewHasPhotos: true).isFavorite)
        // Not loaded yet (the selection just changed): not shown as a favorite.
        #expect(!ActionBarState(targets: [1, 3], flags: loaded, viewHasPhotos: true).isFavorite)
    }

    @Test func videosCannotBeRotated() {
        let loaded = flags([
            (1, false, .video),
            (2, false, .live),  // a Live Photo's motion file with no still
            (3, false, .heic),  // a Live Photo's still (or any still) rotates
            (4, false, .jpeg),
            (5, false, nil),  // no versions left
        ])
        func canRotate(_ ids: [Int64]) -> Bool {
            ActionBarState(targets: ids, flags: loaded, viewHasPhotos: true).canRotate
        }
        #expect(!canRotate([1]))
        #expect(!canRotate([1, 2, 5]))
        #expect(canRotate([3]))
        #expect(canRotate([1, 4]))
        // Not loaded yet: not known to be a video, so the button stays usable (the action re-checks).
        #expect(canRotate([1, 9]))
        #expect(ActionBar.rotatable([1, 2, 3, 4, 5, 9], flags: loaded) == [3, 4])
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
