import Foundation
import Testing
import LoupeCore
@testable import LoupeFeatures

@Suite struct FinderTagStoreTests {
    let dir: URL
    let jpg: URL
    let raw: URL
    let store = FinderTagStore()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-ft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        jpg = dir.appendingPathComponent("a.jpg")
        raw = dir.appendingPathComponent("a.cr2")
        try Data([1]).write(to: jpg)
        try Data([2]).write(to: raw)
    }

    func tags(_ url: URL) throws -> Set<String> {
        var u = url
        u.removeAllCachedResourceValues()
        return Set(try u.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    func set(_ url: URL, _ names: [String]) throws {
        try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }

    var meta: PhotoMetadata { PhotoMetadata(rating: 3, tags: ["Iceland"], isFavorite: true) }

    @Test func pushWritesMirrorSetToAllVersions() throws {
        _ = try store.push(meta, files: [jpg, raw], lastState: nil)
        let expected: Set<String> = ["Iceland", "Favorite", "\u{2605}3"]
        #expect(try tags(jpg) == expected)
        #expect(try tags(raw) == expected)
    }

    @Test func pushThenPullIsNoOp() throws {
        let state = try store.push(meta, files: [jpg, raw], lastState: nil)
        #expect(try store.pull(files: [jpg, raw], lastState: state).isEmpty)
    }

    @Test func pushThenPullIsNoOpForMixedCaseAndNFD() throws {
        let m = PhotoMetadata(tags: ["iCeLand", "Žluť"])
        let state = try store.push(m, files: [jpg], lastState: nil)
        #expect(try store.pull(files: [jpg], lastState: state).isEmpty)
        // Finder handing back the NFD form of the same name is not a change.
        try set(jpg, ["ICELAND", "Žluť".decomposedStringWithCanonicalMapping])
        #expect(try store.pull(files: [jpg], lastState: state).isEmpty)
    }

    @Test func finderAddedTagBecomesKeyword() throws {
        let state = try store.push(meta, files: [jpg, raw], lastState: nil)
        try set(jpg, try tags(jpg).union(["Trip"]).sorted())
        #expect(try store.pull(files: [jpg, raw], lastState: state) == [.addTag("Trip")])
    }

    @Test func finderRemovedTagFromOneFile() throws {
        let state = try store.push(meta, files: [jpg, raw], lastState: nil)
        try set(raw, try tags(raw).subtracting(["Iceland"]).sorted())
        #expect(try store.pull(files: [jpg, raw], lastState: state) == [.removeTag("Iceland")])
    }

    @Test func favoriteTagMapsToFavorite() throws {
        let state = try store.push(meta, files: [jpg], lastState: nil)
        try set(jpg, ["Iceland", "\u{2605}3"])
        #expect(try store.pull(files: [jpg], lastState: state) == [.setFavorite(false)])
        try set(jpg, ["Iceland", "\u{2605}3", "Favorite"])
        let s2 = try store.push(PhotoMetadata(rating: 3, tags: ["Iceland"]), files: [jpg], lastState: state)
        try set(jpg, ["Iceland", "\u{2605}3", "Favorite"])
        #expect(try store.pull(files: [jpg], lastState: s2) == [.setFavorite(true)])
    }

    @Test func starTagsAreOneWay() throws {
        let state = try store.push(meta, files: [jpg], lastState: nil)
        try set(jpg, try tags(jpg).union(["\u{2605}5"]).sorted())
        #expect(try store.pull(files: [jpg], lastState: state).isEmpty)
        try set(jpg, ["Iceland", "Favorite"])  // ★3 removed in Finder: also ignored
        #expect(try store.pull(files: [jpg], lastState: state).isEmpty)
    }

    @Test func firstSyncImportsExistingTags() throws {
        try set(jpg, ["Red", "\u{2605}2"])
        #expect(try store.pull(files: [jpg], lastState: nil) == [.addTag("Red")])
    }

    @Test func pushKeepsUnmanagedFinderTagsAndDropsStaleStars() throws {
        try set(jpg, ["Red", "\u{2605}1"])
        let state = try store.push(PhotoMetadata(rating: 4, tags: ["Iceland"]), files: [jpg], lastState: nil)
        #expect(try tags(jpg) == ["Red", "Iceland", "\u{2605}4"])
        // Tag Loupe removed is dropped; unmanaged Red stays.
        _ = try store.push(PhotoMetadata(rating: 4), files: [jpg], lastState: state)
        #expect(try tags(jpg) == ["Red", "\u{2605}4"])
    }

    @Test func pullNeverProducesAlbumChanges() throws {
        try set(jpg, ["Albums|Trip", "Iceland"])
        #expect(try store.pull(files: [jpg], lastState: nil) == [.addTag("Iceland")])
    }

    @Test func identicalRepushDoesNotWrite() throws {
        let state = try store.push(meta, files: [jpg, raw], lastState: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: raw.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: raw.path) }
        _ = try store.push(meta, files: [jpg, raw], lastState: state)  // would throw if it wrote the read-only file
    }

    @Test func pushAttemptsEveryVersionBeforeRethrowing() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: raw.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: raw.path) }
        #expect(throws: (any Error).self) { try store.push(meta, files: [raw, jpg], lastState: nil) }
        #expect(try tags(jpg) == ["Iceland", "Favorite", "\u{2605}3"])
    }

    @Test func neverPushedFileCannotRemoveTags() throws {
        let state = try store.push(meta, files: [raw], lastState: nil)
        let newJPG = dir.appendingPathComponent("a-edited.jpg")
        try Data([3]).write(to: newJPG)
        #expect(try store.pull(files: [raw, newJPG], lastState: state).isEmpty)
        try set(raw, ["Favorite", "\u{2605}3"])
        #expect(try store.pull(files: [raw, newJPG], lastState: state) == [.removeTag("Iceland")])
    }

    @Test func oldFormatStateTreatsAllFilesAsPushed() throws {
        let old = try JSONEncoder().encode(["Iceland"])
        try set(jpg, [])
        #expect(try store.pull(files: [jpg], lastState: old) == [.removeTag("Iceland")])
    }

    @Test func onlyExactStarTagsAreManaged() throws {
        try set(jpg, ["\u{2605}\u{2605}\u{2605}", "\u{2605} best", "\u{2605}6", "\u{2605}2"])
        #expect(try store.pull(files: [jpg], lastState: nil)
            == [.addTag("\u{2605} best"), .addTag("\u{2605}6"), .addTag("\u{2605}\u{2605}\u{2605}")])
        _ = try store.push(PhotoMetadata(rating: 4), files: [jpg], lastState: nil)
        #expect(try tags(jpg) == ["\u{2605}\u{2605}\u{2605}", "\u{2605} best", "\u{2605}6", "\u{2605}4"])
    }
}
