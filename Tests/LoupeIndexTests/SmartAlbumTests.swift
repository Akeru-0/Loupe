import Foundation
import GRDB
import Testing
import LoupeCore
@testable import LoupeIndex

@Suite struct SmartAlbumTests {
    private let day = 86400.0

    private func makeIndex() throws -> LibraryIndex {
        try LibraryIndex(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-smart-\(UUID().uuidString).sqlite"))
    }

    @discardableResult
    private func insert(
        _ index: LibraryIndex, _ folder: String = "", _ stem: String, capture: Double, rating: Int = 0, fav: Bool = false,
        hidden: Bool = false, camera: String? = nil, raw: Bool = false, edited: Bool = false, tags: [String] = [],
        albums: [String] = [], person: String? = nil
    ) throws -> Int64 {
        try index.dbPool.write { db in
            var p = PhotoRecord(locationId: "L", folderPath: folder, stem: stem, stemKey: stem.lowercased(),
                                captureDate: Date(timeIntervalSince1970: capture * day), addedDate: Date(), rating: rating,
                                isFavorite: fav, isHidden: hidden, cameraModel: camera, hasRaw: raw)
            try p.insert(db)
            if edited { try db.execute(sql: "UPDATE photo SET lastEditedAt = 1 WHERE id = ?", arguments: [p.id]) }
            for t in tags { try db.execute(sql: "INSERT INTO photo_tag VALUES (?, ?)", arguments: [p.id, t]) }
            for a in albums { try db.execute(sql: "INSERT INTO photo_album VALUES (?, ?)", arguments: [p.id, a]) }
            if let person {
                try db.execute(
                    sql: "INSERT INTO face(photoId, kind, x, y, w, h, embedding, groupId) VALUES (?, 'person', 0, 0, 0.1, 0.1, x'00', 900)",
                    arguments: [p.id])
                let face = db.lastInsertedRowID
                try db.execute(
                    sql: "INSERT OR IGNORE INTO face_group(id, kind, photoCount, coverFaceId, name) VALUES (900, 'person', 1, ?, ?)",
                    arguments: [face, person])
            }
            return p.id!
        }
    }

    private func run(_ index: LibraryIndex, _ rules: [SmartRule], matchAll: Bool = true, now: Double = 100) throws -> Set<Int64> {
        let album = SmartAlbum(name: "Test", matchAll: matchAll, rules: rules)
        return Set(try index.sections(for: PhotoQuery(scope: .smartAlbum(album)), now: Date(timeIntervalSince1970: now * day))
            .flatMap(\.photoIDs))
    }

    @Test func rulesSelectThePhotosLikePhotosSmartAlbums() throws {
        let i = try makeIndex()
        let iceland = try insert(i, "Trips/Iceland", "ice", capture: 10, rating: 5, fav: true, camera: "Canon EOS R5",
                                 raw: true, tags: ["landscape"])
        let paris = try insert(i, "Trips/Paris", "IMG_2041", capture: 50, rating: 3, camera: "iPhone 15 Pro",
                               albums: ["Holidays"], person: "Anna")
        let home = try insert(i, "", "home", capture: 95, rating: 1, camera: nil, edited: true, tags: ["family"])
        _ = try insert(i, "", "secret", capture: 96, fav: true, hidden: true)  // hidden photos stay out

        #expect(try run(i, [SmartRule(field: .photo, op: .is, value: "favorite")]) == [iceland])
        #expect(try run(i, [SmartRule(field: .photo, op: .isNot, value: "favorite")]) == [paris, home])
        #expect(try run(i, [SmartRule(field: .photo, op: .is, value: "raw")]) == [iceland])
        #expect(try run(i, [SmartRule(field: .photo, op: .is, value: "edited")]) == [home])
        // An album: a folder with its subfolders, or an album named in sidecars.
        #expect(try run(i, [SmartRule(field: .album, op: .is, value: "Trips")]) == [iceland, paris])
        #expect(try run(i, [SmartRule(field: .album, op: .is, value: "Holidays")]) == [paris])
        #expect(try run(i, [SmartRule(field: .album, op: .isNot, value: "Trips/Iceland")]) == [paris, home])
        #expect(try run(i, [SmartRule(field: .keyword, op: .is, value: "family")]) == [home])
        #expect(try run(i, [SmartRule(field: .person, op: .is, value: "Anna")]) == [paris])
        #expect(try run(i, [SmartRule(field: .person, op: .isNot, value: "Anna")]) == [iceland, home])
        #expect(try run(i, [SmartRule(field: .rating, op: .isAtLeast, value: "3")]) == [iceland, paris])
        #expect(try run(i, [SmartRule(field: .rating, op: .isAtMost, value: "1")]) == [home])
        #expect(try run(i, [SmartRule(field: .camera, op: .contains, value: "iphone")]) == [paris])
        #expect(try run(i, [SmartRule(field: .camera, op: .is, value: "canon eos r5")]) == [iceland])
        #expect(try run(i, [SmartRule(field: .camera, op: .isNot, value: "Canon EOS R5")]) == [paris, home])  // none too
        #expect(try run(i, [SmartRule(field: .filename, op: .contains, value: "IMG_")]) == [paris])
        #expect(try run(i, [SmartRule(field: .filename, op: .doesNotContain, value: "img")]) == [iceland, home])
        // Dates: in the last 10 days of day 100; before or after a day (that day itself is neither).
        #expect(try run(i, [SmartRule(field: .date, op: .isInTheLast, value: "10")]) == [home])
        let utc = Calendar(identifier: .gregorian).with(timeZone: TimeZone(identifier: "UTC")!)
        let day50 = SmartRule.dayString(Date(timeIntervalSince1970: 50 * day), calendar: utc)
        #expect(day50 == "1970-02-20")
        let before = SmartAlbum(name: "B", rules: [SmartRule(field: .date, op: .isBefore, value: day50)])
        let after = SmartAlbum(name: "A", rules: [SmartRule(field: .date, op: .isAfter, value: day50)])
        #expect(LibraryIndex.smartAlbumSQL(before, now: .now, calendar: utc).arguments.first as? Double == 50 * day)
        #expect(LibraryIndex.smartAlbumSQL(after, now: .now, calendar: utc).arguments.first as? Double == 51 * day)

        // All or any.
        let favoriteOrFamily = [SmartRule(field: .photo, op: .is, value: "favorite"),
                                SmartRule(field: .keyword, op: .is, value: "family")]
        #expect(try run(i, favoriteOrFamily, matchAll: true).isEmpty)
        #expect(try run(i, favoriteOrFamily, matchAll: false) == [iceland, home])
        // Incomplete rules are left out; with none left, nothing matches.
        #expect(try run(i, [SmartRule(field: .keyword, op: .is, value: " ")]).isEmpty)
        #expect(try run(i, [SmartRule(field: .keyword, op: .is, value: ""), SmartRule(field: .rating, op: .is, value: "5")]) == [iceland])
    }

    @Test func smartAlbumsAreKeptWithTheLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-smart-root-\(UUID().uuidString)")
        #expect(try SmartAlbumStore.load(root: root).isEmpty)
        var album = SmartAlbum(name: "Best", rules: [SmartRule(field: .rating, op: .isAtLeast, value: "4")])
        try SmartAlbumStore.upsert(album, root: root)
        try SmartAlbumStore.upsert(SmartAlbum(name: "Anna", matchAll: false, rules: [.starting(.person)]), root: root)
        album.name = "Best of"
        try SmartAlbumStore.upsert(album, root: root)  // replaced in place
        #expect(try SmartAlbumStore.load(root: root).map(\.name) == ["Best of", "Anna"])
        try SmartAlbumStore.delete(id: album.id, root: root)
        #expect(try SmartAlbumStore.load(root: root).map(\.name) == ["Anna"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".loupe/smart-albums.json").path))
    }

    @Test func ruleChoicesListAlbumsAndNamedPeople() throws {
        let i = try makeIndex()
        try insert(i, "Trips/Iceland", "a", capture: 1, albums: ["Holidays"], person: "Anna")
        try insert(i, "Recently Deleted", "b", capture: 1)
        #expect(try i.albumRuleChoices() == ["Holidays", "Trips", "Trips/Iceland"])
        #expect(try i.personNames() == ["Anna"])
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar { var c = self; c.timeZone = timeZone; return c }
}
