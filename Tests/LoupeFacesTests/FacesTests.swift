import CoreGraphics
import Foundation
import GRDB
import LoupeCore
import Testing
@testable import LoupeFaces
@testable import LoupeIndex

private func makeIndex() throws -> LibraryIndex {
    try LibraryIndex(databaseURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("loupe-faces-\(UUID().uuidString).sqlite"))
}

/// A unit vector pointing mostly along `axis`, nudged by `jitter` along the next one.
private func vector(_ axis: Int, jitter: Float = 0, dimensions: Int = 128) -> [Float] {
    var v = [Float](repeating: 0, count: dimensions)
    v[axis] = 1
    v[(axis + 1) % dimensions] = jitter
    return Vectors.normalized(v)
}

/// One person's face in photo `k`: mostly the shared direction, plus something of that photo's own (another shot of
/// the same face is ~0.74 alike); `noise`: the same shot, scanned again.
private func look(_ k: Int, noise: Float = 0) -> [Float] {
    var v = [Float](repeating: 0, count: 128)
    v[0] = 1
    v[k] = 0.6
    v[127] = noise
    return Vectors.normalized(v)
}

@Suite struct FacesTests {
    @Test func alignmentTakesTheLandmarksOntoSFacesReferencePoints() {
        // The reference points turned 30°, doubled and moved: the fit undoes exactly that.
        let angle = Double.pi / 6
        let source = FaceAlignment.reference.map { p in
            CGPoint(x: 2 * (p.x * cos(angle) - p.y * sin(angle)) + 300, y: 2 * (p.x * sin(angle) + p.y * cos(angle)) + 120)
        }
        let fit = FaceAlignment.similarity(from: source, to: FaceAlignment.reference)
        for (s, r) in zip(source, FaceAlignment.reference) {
            let mapped = fit.apply(s)
            #expect(abs(mapped.x - r.x) < 1e-6 && abs(mapped.y - r.y) < 1e-6)
            let back = fit.inverse(r)
            #expect(abs(back.x - s.x) < 1e-6 && abs(back.y - s.y) < 1e-6)
        }
    }

    @Test func facesOfOnePersonGroupTogetherAndPetsApart() {
        let faces = [
            FaceGrouping.Face(id: 5, kind: "person", vector: vector(0, jitter: 0.2), size: 0.02),
            FaceGrouping.Face(id: 3, kind: "person", vector: vector(0), size: 0.05),
            FaceGrouping.Face(id: 9, kind: "person", vector: vector(0, jitter: 0.4), size: 0.01),
            FaceGrouping.Face(id: 4, kind: "person", vector: vector(10), size: 0.03),  // someone else
            FaceGrouping.Face(id: 7, kind: "cat", vector: vector(0), size: 0.2),  // same vector, but a cat
        ]
        let groups = FaceGrouping.group(faces)
        #expect(groups[3] == 3 && groups[5] == 3 && groups[9] == 3)  // a group is named after its lowest face id
        #expect(groups[4] == 4)
        #expect(groups[7] == 7)
    }

    @Test func onlyNewChangedOrTurnedPhotosAreScannedAndGroupsAreCounted() async throws {
        let index = try makeIndex()
        try await index.dbPool.write { db in
            for (id, folder) in [(1, ""), (2, ""), (3, "Recently Deleted"), (4, "")] as [(Int64, String)] {
                var p = PhotoRecord(id: id, locationId: "L", folderPath: folder, stem: "p\(id)", stemKey: "p\(id)",
                                    addedDate: Date())
                try p.insert(db)
                try db.execute(
                    sql: "INSERT INTO version(photoId, path, kind, size, modified, isDisplay) VALUES (?, ?, ?, 1, 10, 1)",
                    arguments: [id, "p\(id).jpg", id == 4 ? "video" : "jpeg"])
            }
            // Photo 1 was scanned from this very file; photo 2 from an older one.
            try db.execute(sql: "INSERT INTO face_scan VALUES (1, 'p1.jpg', 10, NULL, 0), (2, 'p2.jpg', 9, NULL, 0)")
            for (faceID, photo, axis) in [(1, 1, 0), (2, 2, 0), (3, 2, 5)] as [(Int64, Int64, Int)] {
                try db.execute(
                    sql: "INSERT INTO face(id, photoId, kind, x, y, w, h, embedding) VALUES (?, ?, 'person', 0, 0, 0.1, 0.1, ?)",
                    arguments: [faceID, photo, Vectors.data(vector(axis))])
            }
        }
        #expect(try FaceScanner.pendingPhotos(in: index).map(\.id) == [2])  // not 1 (unchanged), 3 (deleted), 4 (video)

        #expect(try await FaceScanner.regroup(in: index, root: FileManager.default.temporaryDirectory.appendingPathComponent("loupe-faces-root-\(UUID().uuidString)")) == 2)
        #expect(try index.faceGroups(minPhotos: 1).map(\.id).sorted() == [1, 3])
        #expect(try index.faceGroups(minPhotos: 2).map(\.photoCount) == [2])  // one person seen in two photos
        let shown = try index.sections(for: PhotoQuery(scope: .faceGroup(1))).flatMap(\.photoIDs)
        #expect(Set(shown) == [1, 2])
    }

    @Test func namesStickToTheirFacesMergePeopleAndCanBeRemoved() async throws {
        let index = try makeIndex()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-faces-root-\(UUID().uuidString)")
        try await index.dbPool.write { db in
            for id in Int64(1)...4 {
                var p = PhotoRecord(id: id, locationId: "L", folderPath: "", stem: "p\(id)", stemKey: "p\(id)", addedDate: Date())
                try p.insert(db)
            }
            // Two looks of one woman that the grouping keeps apart (axes 0 and 40), each in two photos.
            for (faceID, photo, axis) in [(1, 1, 0), (2, 2, 0), (3, 3, 40), (4, 4, 40)] as [(Int64, Int64, Int)] {
                try db.execute(
                    sql: "INSERT INTO face(id, photoId, kind, x, y, w, h, embedding) VALUES (?, ?, 'person', 0, 0, 0.1, 0.1, ?)",
                    arguments: [faceID, photo, Vectors.data(vector(axis))])
            }
        }
        try await FaceScanner.regroup(in: index, root: root)
        #expect(try index.faceGroups().map(\.id).sorted() == [1, 3])

        try await FaceScanner.rename(group: 1, to: "Anna", index: index, root: root)
        #expect(try index.faceGroups().first { $0.id == 1 }?.name == "Anna")
        #expect(PeopleNames.load(root: root).people.map(\.name) == ["Anna"])  // kept with the library

        // The other look gets the same name: one Anna, in all four photos.
        try await FaceScanner.rename(group: 3, to: "Anna", index: index, root: root)
        let anna = try index.faceGroups()
        #expect(anna.count == 1 && anna[0].name == "Anna" && anna[0].photoCount == 4)

        // A rescan's new faces of her are named on sight.
        try await index.dbPool.write { db in
            try db.execute(sql: "DELETE FROM face WHERE id = 2")
            try db.execute(
                sql: "INSERT INTO face(id, photoId, kind, x, y, w, h, embedding) VALUES (12, 2, 'person', 0, 0, 0.1, 0.1, ?)",
                arguments: [Vectors.data(vector(0, jitter: 0.1))])
        }
        try await FaceScanner.regroup(in: index, root: root)
        #expect(try index.faceGroups().map(\.name) == ["Anna"])

        try await FaceScanner.rename(group: anna[0].id, to: nil, index: index, root: root)
        #expect(try index.faceGroups().allSatisfy { $0.name == nil })
        #expect(PeopleNames.load(root: root).people.isEmpty)
    }

    @Test func wrongMatchesCanBeTakenOutOrMovedAndStaySoAfterARescan() async throws {
        let index = try makeIndex()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-faces-root-\(UUID().uuidString)")
        try await index.dbPool.write { db in
            for id in Int64(1)...4 {
                var p = PhotoRecord(id: id, locationId: "L", folderPath: "", stem: "p\(id)", stemKey: "p\(id)", addedDate: Date())
                try p.insert(db)
            }
            // One "person" of four photos: three shots of her (~0.74 alike) and, smaller, a stranger who is just
            // alike enough (~0.45) to be grouped with her. Photo 1 turns out to be someone else too.
            var stranger = [Float](repeating: 0, count: 128)
            (stranger[0], stranger[100]) = (0.525, 0.851)
            for (faceID, photo, v, side) in [(1, 1, look(1), 0.1), (2, 2, Vectors.normalized(stranger), 0.05),
                                             (3, 3, look(3), 0.1), (4, 4, look(4), 0.1)] as [(Int64, Int64, [Float], Double)] {
                try db.execute(
                    sql: "INSERT INTO face(id, photoId, kind, x, y, w, h, embedding) VALUES (?, ?, 'person', 0, 0, ?, ?, ?)",
                    arguments: [faceID, photo, side, side, Vectors.data(v)])
            }
        }
        try await FaceScanner.regroup(in: index, root: root)
        #expect(try index.faceGroups().map(\.photoCount) == [4])

        // "Not Person 1" for photo 1: the group loses its first face but is followed to its new id.
        let after = try await FaceScanner.move(photos: [1], from: 1, to: .nobody, index: index, root: root)
        #expect(after == 2)
        #expect(try index.faceGroups().map(\.photoCount) == [3])
        // …and photo 1 really is out of her photos (it used to keep its old group).
        #expect(Set(try index.sections(for: PhotoQuery(scope: .faceGroup(2))).flatMap(\.photoIDs)) == [2, 3, 4])
        #expect(try index.sections(for: PhotoQuery(scope: .faceGroup(1))).isEmpty)
        // Photo 2's face goes to a new person, Bob (one photo: not listed until he's in two).
        _ = try await FaceScanner.move(photos: [2], from: 2, to: .name("Bob"), index: index, root: root)
        #expect(try index.faceGroups(minPhotos: 1).compactMap(\.name) == ["Bob"])
        #expect(Set(try index.sections(for: PhotoQuery(scope: .faceGroup(3))).flatMap(\.photoIDs)) == [3, 4])

        // Photo 1 is scanned again: its face, all but identical, is still nobody's.
        try await index.dbPool.write { db in
            try db.execute(sql: "DELETE FROM face WHERE id = 1")
            try db.execute(
                sql: "INSERT INTO face(id, photoId, kind, x, y, w, h, embedding) VALUES (11, 1, 'person', 0, 0, 0.1, 0.1, ?)",
                arguments: [Vectors.data(look(1, noise: 0.01))])
        }
        try await FaceScanner.regroup(in: index, root: root)
        let groupOf = try await index.dbPool.read { try Int64.fetchOne($0, sql: "SELECT groupId FROM face WHERE id = 11") }
        #expect(groupOf == nil)

        // Moving Bob's photo to the unnamed group (3, 4) works too: it gets a hidden name, never shown.
        let bob = try #require(try index.faceGroups(minPhotos: 1).first { $0.name == "Bob" })
        _ = try await FaceScanner.move(photos: [2], from: bob.id, to: .group(3), index: index, root: root)
        let her = try #require(try index.faceGroups(minPhotos: 1).first { $0.photoCount == 3 })
        #expect(her.name.map { !PeopleNames.isShown($0) } == true)
        #expect(Set(try index.sections(for: PhotoQuery(scope: .faceGroup(her.id))).flatMap(\.photoIDs)) == [2, 3, 4])
    }

    /// Runs the real model when it and ONNX Runtime are on this Mac (they are downloaded, not in the repo).
    @Test(.enabled(if: FaceScanner.runtimeInstalled && FileManager.default.fileExists(atPath: SFaceModel.path)))
    func theRealModelGivesUnitVectorsThatTellFacesApart() throws {
        let sface = try SFace(model: URL(fileURLWithPath: SFaceModel.path))
        let plane = FaceAlignment.side * FaceAlignment.side
        let gray = [Float](repeating: 128, count: 3 * plane)
        var shaded = gray
        for i in 0..<plane { shaded[i] = Float(i % FaceAlignment.side) * 2 }  // a red ramp
        let a = try sface.vector(gray), b = try sface.vector(shaded)
        #expect(a.count == 128 && abs(Vectors.dot(a, a) - 1) < 1e-4)
        #expect(abs(Vectors.dot(a, try sface.vector(gray)) - 1) < 1e-4)  // deterministic
        #expect(Vectors.dot(a, b) < 0.99)
    }
}

enum SFaceModel {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Loupe/Models/sface.onnx").path
}
