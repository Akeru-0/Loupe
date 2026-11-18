import Foundation
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

/// Only the viewer closing itself hands the photo back to the grid (select, reveal, take the keyboard);
/// resets by the app (another sidebar item, a reopened library) do not.
@MainActor @Suite struct ViewerHandoffTests {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-ui-\(UUID().uuidString)")
        return AppModel(preferences: MemoryPreferences(), rootOverride: nil, supportDirectory: dir, cacheDirectory: dir)
    }

    @Test func closingTheViewerHandsThePhotoBackOnce() {
        let model = makeModel()
        model.viewerPhotoID = 5
        model.closeViewer()
        #expect(model.viewerPhotoID == nil)
        #expect(model.takeClosedViewerPhoto() == 5)
        #expect(model.takeClosedViewerPhoto() == nil)
    }

    @Test func programmaticResetHandsNothingBack() {
        let model = makeModel()
        model.viewerPhotoID = 6
        model.viewerPhotoID = nil  // what selectedItemChanged() and openLibrary() do
        #expect(model.takeClosedViewerPhoto() == nil)
    }

    @Test func reopeningForgetsAnUnconsumedHandoff() {
        let model = makeModel()
        model.viewerPhotoID = 7
        model.closeViewer()
        model.viewerPhotoID = 8
        model.viewerPhotoID = nil
        #expect(model.takeClosedViewerPhoto() == nil)
    }

    @Test func closingWithoutAViewerDoesNothing() {
        let model = makeModel()
        model.closeViewer()
        #expect(model.takeClosedViewerPhoto() == nil)
    }
}
