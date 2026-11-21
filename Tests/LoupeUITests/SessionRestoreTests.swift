import Foundation
import LoupeCore
import LoupeFeatures
import Testing
@testable import LoupeUI

private final class MemoryPreferences: PreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}

@MainActor @Suite struct SessionRestoreTests {
    private func makeModel(_ preferences: MemoryPreferences, root: String = "/lib") -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-ui-\(UUID().uuidString)")
        return AppModel(preferences: preferences, rootOverride: root, supportDirectory: dir, cacheDirectory: dir)
    }

    @Test func whereTheUserWasIsSavedAndComesBackPerLibrary() {
        let preferences = MemoryPreferences()
        let first = makeModel(preferences)
        #expect(first.restoringSession == nil)  // nothing saved yet
        first.selectedItemID = "favorites"
        first.columns = 4
        first.noteTopPhoto(42)
        first.viewerPhotoID = 7

        let second = makeModel(preferences)
        #expect(second.selectedItemID == "favorites" && second.columns == 4)
        #expect(second.restoringSession == AppModel.Session(item: "favorites", columns: 4, topPhotoID: 42, viewerPhotoID: 7))
        #expect(!second.canGoBack)  // restoring is not navigation

        #expect(makeModel(preferences, root: "/other").selectedItemID == "library")
    }

    @Test func oneUnlockLastsTheSessionUntilLockedAgain() {
        let model = makeModel(MemoryPreferences())
        model.query.scope = .all
        #expect(!model.isLocked)
        for scope in [PhotoQuery.Scope.hidden, .recentlyDeleted] {
            model.query.scope = scope
            #expect(model.isLocked)
            model.isUnlocked = true  // what Touch ID does
            #expect(!model.isLocked)
            model.selectedItemID = "favorites-\(scope)"  // another item and back: still unlocked
            model.query.scope = scope
            #expect(!model.isLocked)
            model.viewerPhotoID = 4
            model.lock()  // the screen locked
            #expect(model.isLocked && model.viewerPhotoID == nil && !model.unlockDeclined)
            model.isUnlocked = true
            model.lock(byHand: true)  // the padlock: no prompt right away
            #expect(model.isLocked && model.unlockDeclined)
            model.selectedItemID = "other-\(scope)"  // opening a locked view later asks again
            #expect(!model.unlockDeclined)
        }
    }

    @Test func anUnlockEndsAfterItsTime() async throws {
        let model = makeModel(MemoryPreferences())
        model.unlockDuration = .milliseconds(50)
        model.query.scope = .hidden
        model.isUnlocked = true
        #expect(!model.isLocked && model.unlockExpiry != nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.isLocked && model.unlockExpiry == nil)
    }

    @Test func nothingIsOverwrittenUntilTheRestoreIsDoneOrTheUserMovesOn() {
        let preferences = MemoryPreferences()
        let first = makeModel(preferences)
        first.selectedItemID = "favorites"
        first.noteTopPhoto(42)

        let launching = makeModel(preferences)
        launching.noteTopPhoto(1)  // the grid at the top before the photos are in
        launching.viewerPhotoID = nil
        #expect(makeModel(preferences).restoringSession?.topPhotoID == 42)

        launching.selectedItemID = "recent"  // the user picked something else: the restore is dropped
        #expect(launching.restoringSession == nil)
        #expect(makeModel(preferences).selectedItemID == "recent")
    }
}
