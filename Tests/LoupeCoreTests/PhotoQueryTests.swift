import Testing
@testable import LoupeCore

@Suite struct PhotoQueryTests {
    @Test func recentlyEditedSortsNewestEditFirstByDefault() {
        var q = PhotoQuery()
        q.sort = .rating
        q.ascending = false
        q.select(.favorites)
        #expect(q.scope == .favorites && q.sort == .rating && !q.ascending)  // the user's sort is kept

        q.select(.recentlyEdited(days: 30))
        #expect(q.sort == .edited && !q.ascending)
        q.ascending = true
        q.select(.recentlyEdited(days: 7))  // same kind of scope: the user's order stays
        #expect(q.sort == .edited && q.ascending)

        q.select(.all)  // edit time means nothing elsewhere: back to the default
        #expect(q.scope == .all && q.sort == .captureDate && q.ascending)
    }
}
