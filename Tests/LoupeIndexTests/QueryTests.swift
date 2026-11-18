import Foundation
import GRDB
import Testing
import LoupeCore
@testable import LoupeIndex

private func makeIndex() throws -> LibraryIndex {
    try LibraryIndex(databaseURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("loupe-q-\(UUID().uuidString).sqlite"))
}

@discardableResult
private func insert(
    _ index: LibraryIndex, _ folder: String = "", _ stem: String, capture: Date? = nil, added: Date = Date(timeIntervalSince1970: 1000),
    rating: Int = 0, fav: Bool = false, lc: Bool = false, camera: String? = nil, lens: String? = nil,
    raw: Bool = false, video: Bool = false, tags: [String] = [], albums: [String] = []
) throws -> Int64 {
    try index.dbPool.write { db in
        var p = PhotoRecord(locationId: "L", folderPath: folder, stem: stem, stemKey: stem.lowercased(),
                            captureDate: capture, addedDate: added, rating: rating, isFavorite: fav,
                            hasLightCraftEdits: lc, cameraModel: camera, lensModel: lens, hasRaw: raw, hasVideo: video)
        try p.insert(db)
        for t in tags { try db.execute(sql: "INSERT INTO photo_tag VALUES (?, ?)", arguments: [p.id, t]) }
        for a in albums { try db.execute(sql: "INSERT INTO photo_album VALUES (?, ?)", arguments: [p.id, a]) }
        return p.id!
    }
}

private func ids(_ index: LibraryIndex, _ q: PhotoQuery) throws -> [Int64] {
    try index.sections(for: q).flatMap(\.photoIDs)
}

private func utc() -> (Calendar, Locale) {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return (c, Locale(identifier: "en_US"))
}

@Suite struct QueryTests {
    @Test func scopesSelectTheRightPhotos() throws {
        let i = try makeIndex()
        let now = Date(timeIntervalSince1970: 100 * 86400)
        let fav = try insert(i, "a", "f", fav: true)
        let trip = try insert(i, "b", "t", albums: ["Trip"])
        let ice = try insert(i, "b", "i", tags: ["Iceland"])
        let sub = try insert(i, "a/sub", "s")
        let old = try insert(i, "", "old", added: now.addingTimeInterval(-40 * 86400))
        let new = try insert(i, "", "new", added: now.addingTimeInterval(-5 * 86400))
        func run(_ s: PhotoQuery.Scope) throws -> Set<Int64> {
            Set(try i.sections(for: PhotoQuery(scope: s), now: now).flatMap(\.photoIDs))
        }
        #expect(try run(.favorites) == [fav])
        #expect(try run(.album("Trip")) == [trip])
        #expect(try run(.tag("Iceland")) == [ice])
        #expect(try run(.folder("a")) == [fav])
        #expect(try run(.folder("a/sub")) == [sub])
        #expect(try run(.recentlyAdded(days: 30)) == [new])
        #expect(try run(.all).count == 6)
        _ = old
    }

    @Test func searchMatchesNamesTagsAlbumsCameraLens() throws {
        let i = try makeIndex()
        let byStem = try insert(i, "", "IMG_1")
        let byTag = try insert(i, "", "x", tags: ["Iceland"])
        let byAlbum = try insert(i, "", "y", albums: ["Summer"])
        let byCam = try insert(i, "", "z", camera: "Canon EOS 600D")
        let byLens = try insert(i, "", "w", lens: "EF 50mm")
        func search(_ s: String) throws -> Set<Int64> {
            var q = PhotoQuery(); q.searchText = s
            return Set(try ids(i, q))
        }
        #expect(try search("ice") == [byTag])
        #expect(try search("600d") == [byCam])
        #expect(try search("IMG_1") == [byStem])
        #expect(try search("summ") == [byAlbum])
        #expect(try search("50MM") == [byLens])
        // LIKE wildcards are literal; quotes are harmless.
        #expect(try search("%").isEmpty)
        #expect(try search("IMG_1").count == 1 && search("IMG\\_1").isEmpty)
        #expect(try search("'; DROP TABLE photo; --").isEmpty)
        #expect(try i.allPhotos().count == 5)
    }

    @Test func filtersApply() throws {
        let i = try makeIndex()
        let r4 = try insert(i, "", "a", rating: 4)
        _ = try insert(i, "", "b", rating: 2)
        let raw = try insert(i, "", "c", raw: true)
        let vid = try insert(i, "", "d", video: true)
        let lc = try insert(i, "", "e", lc: true, camera: "Cam", lens: "Len")
        func run(_ edit: (inout PhotoQuery) -> Void) throws -> Set<Int64> {
            var q = PhotoQuery(); edit(&q); return Set(try ids(i, q))
        }
        #expect(try run { $0.minRating = 3 } == [r4])
        #expect(try run { $0.kind = .hasRaw } == [raw])
        #expect(try run { $0.kind = .withoutRaw }.count == 4)
        #expect(try run { $0.kind = .videos } == [vid])
        #expect(try run { $0.kind = .lightCraftEdited } == [lc])
        #expect(try run { $0.camera = "Cam" } == [lc])
        #expect(try run { $0.lens = "Len" } == [lc])
    }

    @Test func sortsWithUndatedLast() throws {
        let i = try makeIndex()
        let a = try insert(i, "", "a", capture: Date(timeIntervalSince1970: 100))
        let u1 = try insert(i, "", "u1")
        let b = try insert(i, "", "b", capture: Date(timeIntervalSince1970: 200))
        let u2 = try insert(i, "", "u2")
        var q = PhotoQuery()
        #expect(try ids(i, q) == [a, b, u1, u2])
        q.ascending = false
        #expect(try ids(i, q) == [b, a, u1, u2])
        q.sort = .name; q.ascending = true
        #expect(try ids(i, q) == [a, b, u1, u2])
    }

    @Test func groupsIntoTitledSections() throws {
        let i = try makeIndex()
        let (cal, loc) = utc()
        let d1 = Date(timeIntervalSince1970: 1_788_700_000) // 2026-09-06 UTC
        let d2 = d1.addingTimeInterval(86400 * 40)
        let a = try insert(i, "", "a", capture: d1)
        let u = try insert(i, "", "u")
        let b = try insert(i, "", "b", capture: d2)
        func titles(_ g: PhotoQuery.Grouping) throws -> [String] {
            var q = PhotoQuery(); q.grouping = g
            return try i.sections(for: q, calendar: cal, locale: loc).map(\.title)
        }
        #expect(try titles(.day) == ["Sunday, September 6, 2026", "Friday, October 16, 2026", "Undated"])
        #expect(try titles(.month) == ["September 2026", "October 2026", "Undated"])
        #expect(try titles(.year) == ["2026", "Undated"])
        var q = PhotoQuery(); q.grouping = .year
        let s = try i.sections(for: q, calendar: cal, locale: loc)
        #expect(s.map(\.photoIDs) == [[a, b], [u]])
        #expect(s.map(\.id) == ["2026", "undated"])
    }

    @Test func observationEmitsAfterInsert() async throws {
        let i = try makeIndex()
        let first = try insert(i, "", "one")
        var it = i.observeSections(for: PhotoQuery()).makeAsyncIterator()
        let s1 = try await it.next()
        #expect(s1?.flatMap(\.photoIDs) == [first])
        let second = try insert(i, "", "two")
        let s2 = try await it.next()
        #expect(Set(s2?.flatMap(\.photoIDs) ?? []) == [first, second])
    }

    @Test func observationSkipsIdenticalEmissions() async throws {
        let i = try makeIndex()
        let first = try insert(i, "", "one")
        let stream = i.observeSections(for: PhotoQuery())
        let reader = Task { () -> [[Int64]] in
            var seen: [[Int64]] = []
            do {
                for try await s in stream {
                    seen.append(s.flatMap(\.photoIDs))
                    if seen.count == 2 { break }
                }
            } catch {}
            return seen
        }
        let watchdog = Task { try await Task.sleep(for: .seconds(5)); reader.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        // Writes that leave the result unchanged must not emit.
        try await i.dbPool.write { try $0.execute(sql: "INSERT INTO photo_tag VALUES (?, 'x')", arguments: [first]) }
        try await i.dbPool.write { try $0.execute(sql: "UPDATE photo SET captureDate = captureDate, addedDate = addedDate WHERE id = ?", arguments: [first]) }
        let second = try insert(i, "", "two")
        let seen = await reader.value
        watchdog.cancel()
        #expect(seen.count == 2)
        #expect(seen.first == [first])
        #expect(Set(seen.last ?? []) == [first, second])
    }
}
