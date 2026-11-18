import Testing
import LoupeCore
@testable import LoupeXMP

@Suite struct StaleRevertGuardTests {
    typealias P = StaleRevertGuard.Pending

    @Test func staleRatingIsRestored() {
        let p = P(field: "rating", value: "4", previous: "0")
        let r = StaleRevertGuard.evaluate([p], current: PhotoMetadata(rating: 0))
        #expect(r.corrections == [.setRating(4)])
        #expect(r.resolved.isEmpty)
    }

    @Test func caughtUpIsResolved() {
        let p = P(field: "rating", value: "4", previous: "0")
        let r = StaleRevertGuard.evaluate([p], current: PhotoMetadata(rating: 4))
        #expect(r.corrections.isEmpty)
        #expect(r.resolved == [p])
    }

    @Test func differentValueWins() {
        let p = P(field: "rating", value: "4", previous: "0")
        let r = StaleRevertGuard.evaluate([p], current: PhotoMetadata(rating: 2))
        #expect(r.corrections.isEmpty)
        #expect(r.resolved == [p])
    }

    @Test func droppedKeywordsRestored() {
        let ps = [P(field: "tag:Iceland", value: "present", previous: "absent"),
                  P(field: "album:Trip", value: "present", previous: "absent")]
        let r = StaleRevertGuard.evaluate(ps, current: PhotoMetadata())
        #expect(Set(r.corrections) == [.addTag("Iceland"), .addToAlbum("Trip")])
        #expect(r.resolved.isEmpty)
    }

    @Test func removedKeywordsAndFavoriteRestored() {
        let ps = [P(field: "tag:Old", value: "absent", previous: "present"),
                  P(field: "favorite", value: "present", previous: "absent")]
        let r = StaleRevertGuard.evaluate(ps, current: PhotoMetadata(tags: ["Old"]))
        #expect(Set(r.corrections) == [.removeTag("Old"), .setFavorite(true)])
    }

    @Test func keywordCaseAndNormalisationDoNotLoop() {
        let ps = [P(field: "tag:Škoda", value: "present", previous: "absent")]
        // decomposed + different case still counts as present
        let r = StaleRevertGuard.evaluate(ps, current: PhotoMetadata(tags: ["s\u{030C}koda"]))
        #expect(r.corrections.isEmpty)
        #expect(r.resolved == ps)
    }

    @Test func pendingRecordsOnlyRealChanges() {
        let before = PhotoMetadata(rating: 2, tags: ["a"])
        let ps = StaleRevertGuard.pending(
            for: [.setRating(2), .setRating(4), .addTag("a"), .addTag("b"), .removeTag("a")], before: before)
        #expect(Set(ps) == [P(field: "rating", value: "4", previous: "2"),
                            P(field: "tag:b", value: "present", previous: "absent"),
                            P(field: "tag:a", value: "absent", previous: "present")])
    }

    @Test func secondEditKeepsFirstPrevious() {
        let first = StaleRevertGuard.pending(for: [.setRating(4)], before: PhotoMetadata(rating: 0))
        let second = StaleRevertGuard.pending(for: [.setRating(2)], before: PhotoMetadata(rating: 4))
        #expect(StaleRevertGuard.merge(first, with: second) == [P(field: "rating", value: "2", previous: "0")])
    }

    @Test func editsThatCancelOutLeaveNothing() {
        let first = StaleRevertGuard.pending(for: [.setRating(4)], before: PhotoMetadata(rating: 0))
        let second = StaleRevertGuard.pending(for: [.setRating(0)], before: PhotoMetadata(rating: 4))
        #expect(StaleRevertGuard.merge(first, with: second).isEmpty)
    }
}
