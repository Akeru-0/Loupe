import Foundation
import GRDB
import Testing
import LoupeCore
@testable import LoupeIndex

private func makeIndex() throws -> LibraryIndex {
    try LibraryIndex(databaseURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("loupe-cell-\(UUID().uuidString).sqlite"))
}

private let root = URL(fileURLWithPath: "/tmp/loupe-root", isDirectory: true)

/// Inserts a photo with `versions` (path, kind, duration); the version at `display` is the display version.
@discardableResult
private func insert(
    _ index: LibraryIndex, _ stem: String, rating: Int = 0, fav: Bool = false, lc: Bool = false,
    _ versions: [(String, VersionKind, Double?)], display: Int = 0
) throws -> Int64 {
    try index.dbPool.write { db in
        var p = PhotoRecord(locationId: "L", folderPath: "a", stem: stem, stemKey: stem.lowercased(),
                            addedDate: Date(timeIntervalSince1970: 1000), rating: rating, isFavorite: fav,
                            hasLightCraftEdits: lc)
        try p.insert(db)
        for (i, v) in versions.enumerated() {
            var row = VersionRecord(photoId: p.id!, path: "a/" + v.0, kind: v.1, size: Int64(100 + i),
                                    modified: Date(timeIntervalSince1970: 2000), duration: v.2, isDisplay: i == display)
            try row.insert(db)
        }
        return p.id!
    }
}

@Suite struct CellInfoTests {
    @Test func badges() throws {
        let i = try makeIndex()
        let pair = try insert(i, "IMG_1", [("IMG_1.CR2", .raw, nil), ("IMG_1.JPG", .jpeg, nil)], display: 1)
        let live = try insert(i, "IMG_2", [("IMG_2.HEIC", .heic, nil), ("IMG_2.MOV", .live, 2.5)])
        let short = try insert(i, "clip", [("clip.mov", .video, 12)])
        let long = try insert(i, "film", [("film.mp4", .video, 3723)])
        let edited = try insert(i, "IMG_3", [("IMG_3.CR2", .raw, nil), ("IMG_3.JPG", .jpeg, nil), ("IMG_3-edited.jpg", .edit, nil)],
                                display: 2)
        let plain = try insert(i, "plain", [("plain.jpg", .jpeg, nil)])
        let info = try i.cellInfo(ids: [pair, live, short, long, edited, plain], root: root)
        #expect(info[pair]?.badges == ["RAW", "JPG"])
        #expect(info[live]?.badges == ["LIVE"])
        #expect(info[short]?.badges == ["0:12"])
        #expect(info[long]?.badges == ["1:02:03"])
        #expect(info[edited]?.badges == ["RAW", "JPG", "EDIT"])
        #expect(info[plain]?.badges == [])
    }

    @Test func actionFlagsCarryFavoriteAndDisplayKind() throws {
        let i = try makeIndex()
        let pair = try insert(i, "IMG_1", fav: true, [("IMG_1.CR2", .raw, nil), ("IMG_1.JPG", .jpeg, nil)], display: 1)
        let live = try insert(i, "IMG_2", [("IMG_2.MOV", .live, 2.5)])
        let clip = try insert(i, "clip", [("clip.mov", .video, 12)])
        let noDisplay = try insert(i, "odd", [("odd.CR2", .raw, nil)], display: -1)
        let flags = try i.actionFlags(ids: [pair, live, clip, noDisplay, 9999])
        #expect(flags[pair] == ActionFlags(isFavorite: true, displayKind: .jpeg))
        #expect(flags[live] == ActionFlags(isFavorite: false, displayKind: .live))
        #expect(flags[clip] == ActionFlags(isFavorite: false, displayKind: .video))
        #expect(flags[noDisplay] == ActionFlags(isFavorite: false, displayKind: .raw))  // first version, as cells do
        #expect(flags[9999] == nil)
        #expect(try i.actionFlags(ids: []).isEmpty)
    }

    @Test func carriesDisplayVersionAndMetadata() throws {
        let i = try makeIndex()
        let id = try insert(i, "IMG_1", rating: 4, fav: true, lc: true,
                            [("IMG_1.CR2", .raw, nil), ("IMG_1.JPG", .jpeg, nil)], display: 1)
        let other = try insert(i, "x", [("x.jpg", .jpeg, nil)])
        let info = try i.cellInfo(ids: [id, 9999], root: root)
        #expect(info.count == 1)  // unknown ids and ids not asked for are left out
        #expect(info[other] == nil)
        let cell = try #require(info[id])
        #expect(cell.id == id)
        #expect(cell.displayFile.url == root.appendingPathComponent("a").appendingPathComponent("IMG_1.JPG"))
        #expect(cell.displayFile.size == 101)
        #expect(cell.displayFile.modified == Date(timeIntervalSince1970: 2000))
        #expect(cell.displayKind == .jpeg)
        #expect(cell.rating == 4 && cell.isFavorite && cell.hasLightCraftEdits)
        #expect(try i.cellInfo(ids: [], root: root).isEmpty)
    }

    @Test func manyIdsInOneCall() throws {
        let i = try makeIndex()
        var ids: [Int64] = []
        for n in 0..<1200 { ids.append(try insert(i, "p\(n)", [("p\(n).jpg", .jpeg, nil)])) }
        #expect(try i.cellInfo(ids: ids, root: root).count == 1200)
    }

    @Test func actionSelectionKeepsOrderAndVersions() throws {
        let i = try makeIndex()
        let a = try insert(i, "a", [("a.CR2", .raw, nil), ("a.JPG", .jpeg, nil)], display: 1)
        let b = try insert(i, "b", [("b.jpg", .jpeg, nil)])
        let sel = try i.actionSelection(ids: [b, a, 4242], root: root)
        #expect(sel.photos.map(\.id) == [b, a])
        #expect(sel.versions[a]?.map(\.path) == ["a/a.CR2", "a/a.JPG"])
        #expect(sel.versions[b]?.count == 1)
        #expect(sel.root == root)
        #expect(sel.targetFiles().map(\.lastPathComponent) == ["b.jpg", "a.JPG"])
    }
}
