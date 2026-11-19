import Foundation
import LoupeFeatures
import Testing
@testable import LoupeUI

/// The slideshow's order and position: which photos play, where it starts, advancing, wrapping and pausing.
@Suite struct SlideshowModelTests {
    private let order: [Int64] = [10, 20, 30, 40]

    // MARK: - Photos and start

    @Test func oneTargetPlaysTheWholeQueryStartingThere() throws {
        let show = try #require(SlideshowModel(targets: [30], order: order))
        #expect(show.photoIDs == order)
        #expect(show.index == 2)
        #expect(show.currentID == 30)
    }

    @Test func twoOrMoreTargetsPlayOnlyThemFromTheFirst() throws {
        let show = try #require(SlideshowModel(targets: [40, 20], order: order))
        #expect(show.photoIDs == [40, 20])
        #expect(show.index == 0)
    }

    @Test func noTargetStartsAtTheQuerysFirstPhoto() throws {
        let show = try #require(SlideshowModel(targets: [], order: order))
        #expect(show.photoIDs == order)
        #expect(show.index == 0)
    }

    @Test func aViewedPhotoOutsideTheQueryStartsTheQueryFromTheTop() throws {
        let show = try #require(SlideshowModel(targets: [77], order: order))
        #expect(show.photoIDs == order)
        #expect(show.index == 0)
        // An empty query still shows the viewed photo.
        #expect(SlideshowModel(targets: [77], order: [])?.photoIDs == [77])
    }

    @Test func nothingToShowIsNoSlideshow() {
        #expect(SlideshowModel(targets: [], order: []) == nil)
    }

    @Test func startsPlayingEveryThreeSeconds() throws {
        let show = try #require(SlideshowModel(targets: [], order: order))
        #expect(show.isPlaying)
        #expect(show.interval == 3)
    }

    // MARK: - Advancing

    @Test func tickAdvancesAndWrapsToTheStart() throws {
        var show = try #require(SlideshowModel(targets: [30], order: order))
        show.tick()
        #expect(show.currentID == 40)
        #expect(show.nextID == 10)
        show.tick()
        #expect(show.currentID == 10)
        #expect(show.index == 0)
    }

    @Test func nextAndPreviousStepAndWrap() throws {
        var show = try #require(SlideshowModel(targets: [], order: order))
        show.previous()
        #expect(show.index == 3)
        #expect(show.currentID == 40)
        show.next()
        #expect(show.index == 0)
        show.next()
        #expect(show.currentID == 20)
    }

    @Test func pauseStopsTickButNotStepping() throws {
        var show = try #require(SlideshowModel(targets: [], order: order))
        show.togglePlay()
        #expect(!show.isPlaying)
        show.tick()
        #expect(show.index == 0)
        show.next()
        #expect(show.index == 1)
        show.togglePlay()
        #expect(show.isPlaying)
        show.tick()
        #expect(show.index == 2)
    }

    @Test func aSinglePhotoStaysPut() throws {
        var show = try #require(SlideshowModel(targets: [20], order: [20]))
        #expect(show.nextID == nil)
        show.tick()
        show.next()
        show.previous()
        #expect(show.index == 0)
        #expect(show.currentID == 20)
    }
}

private final class MemoryPreferences: PreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}

/// Ending the slideshow hands its last photo back like the viewer closing: the grid selects and reveals it, or the
/// open viewer shows it. A reset hands nothing back.
@MainActor @Suite struct SlideshowHandoffTests {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-ui-\(UUID().uuidString)")
        return AppModel(preferences: MemoryPreferences(), rootOverride: nil, supportDirectory: dir, cacheDirectory: dir)
    }

    @Test func endingHandsTheLastPhotoToTheGridOnce() {
        let model = makeModel()
        model.slideshowEnded(on: 7)
        #expect(model.viewerPhotoID == nil)
        #expect(model.takeClosedViewerPhoto() == 7)
        #expect(model.takeClosedViewerPhoto() == nil)
    }

    @Test func endingOverTheViewerShowsTheLastPhotoThere() {
        let model = makeModel()
        model.viewerPhotoID = 5
        model.slideshowEnded(on: 9)
        #expect(model.viewerPhotoID == 9)
        #expect(model.takeClosedViewerPhoto() == nil)
    }

    @Test func aResetHandsNothingBack() {
        let model = makeModel()
        model.slideshowEnded(on: nil)
        #expect(model.takeClosedViewerPhoto() == nil)
    }
}
