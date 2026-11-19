import Foundation
import GRDB
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeIndex

private let lightCraftSidecar = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
    <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:lc="http://ns.lightcraft.app/lc/1.0/">\
    <xmp:Rating>0</xmp:Rating><lc:settings>{"version":1}</lc:settings></rdf:Description></rdf:RDF></x:xmpmeta>
    """

private func setModified(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func close(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) < 0.01 } ?? false }

@Suite struct RecentlyEditedTests {
    @Test func lastEditedAtComesFromEditsAndLightCraftSidecars() async throws {
        let lib = try TestLibrary()
        let index = try LibraryIndex(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-edit-\(UUID().uuidString).sqlite"))
        let scanner = LoupeIndex.Scanner(
            index: index, location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path))
        let t1 = Date(timeIntervalSince1970: 1_700_000_000), t2 = t1.addingTimeInterval(3600)

        try lib.addJPEG("a/Plain.jpg")
        try lib.addSidecar("a/Plain.xmp", rating: 4)  // a sidecar without LightCraft edits is no edit
        try setModified(lib.addJPEG("a/Edit.jpg"), t2)
        try setModified(lib.addJPEG("a/Edit-edited.jpg"), t1)
        try lib.addJPEG("a/LC.jpg")
        try setModified(lib.addFile("a/LC.xmp", bytes: Data(lightCraftSidecar.utf8)), t2)
        // Both: the larger wins, whichever source it comes from.
        try setModified(lib.addJPEG("a/Both.jpg"), t1)
        try setModified(lib.addJPEG("a/Both-edited.jpg"), t2)
        try setModified(lib.addFile("a/Both.xmp", bytes: Data(lightCraftSidecar.utf8)), t1)
        try lib.addJPEG("a/Both2.jpg")
        try setModified(lib.addJPEG("a/Both2-edited.jpg"), t1)
        try setModified(lib.addFile("a/Both2.xmp", bytes: Data(lightCraftSidecar.utf8)), t2)
        _ = try await scanner.fullScan()

        func edited(_ key: String) throws -> Date? { try #require(try index.photo(key: key)).lastEditedAt }
        #expect(try edited("a/Plain") == nil)
        #expect(close(try edited("a/Edit"), t1))  // the edit's time, not the original's
        #expect(close(try edited("a/LC"), t2))
        #expect(close(try edited("a/Both"), t2))
        #expect(close(try edited("a/Both2"), t2))

        // A newer edit is picked up by the next scan.
        let t3 = t2.addingTimeInterval(3600)
        try setModified(lib.addJPEG("a/Edit_edited.jpg"), t3)
        _ = try await scanner.fullScan()
        #expect(close(try edited("a/Edit"), t3))
    }

    @Test func recentlyEditedWindowAndSort() throws {
        let index = try LibraryIndex(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-edit-\(UUID().uuidString).sqlite"))
        let now = Date(timeIntervalSince1970: 100 * 86400)
        func insert(_ stem: String, edited: Double?, capture: Double) throws -> Int64 {
            try index.dbPool.write { db in
                var p = PhotoRecord(
                    locationId: "L", folderPath: "", stem: stem, stemKey: stem.lowercased(),
                    captureDate: Date(timeIntervalSince1970: capture * 86400), addedDate: now,
                    lastEditedAt: edited.map { now.addingTimeInterval(-$0 * 86400) })
                try p.insert(db)
                return p.id!
            }
        }
        let older = try insert("older", edited: 20, capture: 3)
        let newest = try insert("newest", edited: 1, capture: 1)
        _ = try insert("tooOld", edited: 40, capture: 2)
        _ = try insert("never", edited: nil, capture: 4)

        var q = PhotoQuery()
        q.select(.recentlyEdited(days: 30))
        #expect(q.sort == .edited && !q.ascending)
        #expect(try index.sections(for: q, now: now).flatMap(\.photoIDs) == [newest, older])
        q.ascending = true
        #expect(try index.sections(for: q, now: now).flatMap(\.photoIDs) == [older, newest])
    }

    @Test func migrationV6FillsLastEditedAtForExistingPhotos() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-v6-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: url.path)
        try Schema.migrator().migrate(pool, upTo: "v5")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO photo (id, locationId, folderPath, stem, stemKey, addedDate, hasLightCraftEdits, sidecarModified)
                VALUES (1, 'L', '', 'plain', 'plain', 0, 0, 500),
                       (2, 'L', '', 'edit', 'edit', 0, 0, NULL),
                       (3, 'L', '', 'lc', 'lc', 0, 1, 700),
                       (4, 'L', '', 'both', 'both', 0, 1, 300);
                INSERT INTO version (photoId, path, kind, size, modified) VALUES
                    (1, 'plain.jpg', 'jpeg', 1, 900),
                    (2, 'edit.jpg', 'jpeg', 1, 900), (2, 'edit-edited.jpg', 'edit', 1, 200),
                    (2, 'edit-edited2.jpg', 'edit', 1, 250),
                    (3, 'lc.jpg', 'jpeg', 1, 900),
                    (4, 'both.jpg', 'jpeg', 1, 900), (4, 'both-edited.jpg', 'edit', 1, 400);
                """)
        }
        try Schema.migrator().migrate(pool)
        let values = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, lastEditedAt FROM photo ORDER BY id").map { $0["lastEditedAt"] as Double? }
        }
        #expect(values == [nil, 250, 700, 400])
        #expect(try pool.read { try $0.tableExists("duplicate_member") })
    }
}
