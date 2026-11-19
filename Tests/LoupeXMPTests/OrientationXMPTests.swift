import CryptoKit
import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeXMP

private let tiffNS = "http://ns.adobe.com/tiff/1.0/"

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "xmp"))
    return try Data(contentsOf: url)
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-orient-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func canonical(_ data: Data) throws -> String {
    try XMLDocument(data: data, options: [.nodePreserveAll]).canonicalXMLStringPreservingComments(false)
}

/// `tiff:Orientation` elements (any prefix), with the index of the `rdf:Description` holding each.
private func orientationElements(_ data: Data) throws -> [(description: Int, value: String)] {
    let doc = try XMLDocument(data: data, options: [.nodePreserveAll])
    let descriptions = try doc.nodes(forXPath: "//*[local-name()='Description']").compactMap { $0 as? XMLElement }
    var out: [(Int, String)] = []
    for (i, d) in descriptions.enumerated() {
        for case let c as XMLElement in d.children ?? [] where c.uri == tiffNS && c.localName == "Orientation" {
            out.append((i, c.stringValue ?? ""))
        }
    }
    return out
}

private func group(_ jpeg: URL, sidecar: URL? = nil) -> PhotoGroup {
    let file = MediaFile(url: jpeg, size: 0, modified: .now, created: .now)
    let stem = jpeg.deletingPathExtension().lastPathComponent
    return PhotoGroup(
        folder: jpeg.deletingLastPathComponent(), stem: stem, stemKey: stem.lowercased(),
        versions: [GroupedVersion(file: file, kind: .jpeg)], sidecar: sidecar, legacySidecars: [])
}

@Suite struct OrientationXMPTests {
    @Test func rotateWritesTiffOrientation() throws {
        let input = try fixtureData("lightcraft-two-descriptions")
        var doc = try XMPDocument(data: input)
        #expect(doc.metadata.orientation == nil)
        doc.apply([.rotate(clockwise: true)], embeddedOrientation: 1)
        let out = doc.serialized()
        #expect(doc.metadata.orientation == 6)
        let found = try orientationElements(out)
        #expect(found.count == 1)
        #expect(found.first?.description == 0)  // the first Description, like a new xmp:Rating
        #expect(found.first?.value == "6")
        // Everything else is as it was.
        let stripped = try XMLDocument(data: out, options: [.nodePreserveAll])
        for n in try stripped.nodes(forXPath: "//*[local-name()='Orientation']") { n.detach() }
        #expect(stripped.canonicalXMLStringPreservingComments(false) == (try canonical(input)))
    }

    @Test func rotateCreatesSidecarForFileWithoutOne() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try TestImages.makeJPEG(at: jpeg, width: 40, height: 30)
        let m = try SidecarIO.write([.rotate(clockwise: true)], to: group(jpeg))
        #expect(m.orientation == 6)
        let sidecar = dir.appendingPathComponent("IMG_1.xmp")
        #expect(try orientationElements(Data(contentsOf: sidecar)).map(\.value) == ["6"])
        #expect(try SidecarIO.read(group(jpeg, sidecar: sidecar)).orientation == 6)
    }

    @Test func rotateBackToEmbeddedRemovesProperty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try TestImages.makeJPEG(at: jpeg, width: 40, height: 30, orientation: 6)
        let sidecar = dir.appendingPathComponent("IMG_1.xmp")
        let original = try fixtureData("lightcraft-two-descriptions")
        try original.write(to: sidecar)

        var seen: [Int?] = []
        for _ in 0..<4 {
            seen.append(try SidecarIO.write([.rotate(clockwise: true)], to: group(jpeg, sidecar: sidecar)).orientation)
        }
        // Relative to the file's own 6: 3, 8, 1, then back to 6, which the file already says.
        #expect(seen == [3, 8, 1, nil])
        let after = try Data(contentsOf: sidecar)
        #expect(try orientationElements(after).isEmpty)
        #expect(!String(decoding: after, as: UTF8.self).contains("Orientation"))
        #expect(try canonical(after) == canonical(original))
    }

    /// RAW (shown turned by its own 6) + a LightCraft edit with the turn baked in (1): the sidecar is the RAW's,
    /// so a clockwise turn is computed from the RAW's 6, not from the edit the grid displays.
    @Test func rotationBaseIsTheRaw() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("IMG_1.dng"), edit = dir.appendingPathComponent("IMG_1-edited.tif")
        try TestImages.makeQuadrantTIFF(at: raw, width: 40, height: 30, orientation: 6)
        try TestImages.makeQuadrantTIFF(at: edit, width: 30, height: 40, orientation: 1)
        func version(_ url: URL, _ kind: VersionKind) -> GroupedVersion {
            GroupedVersion(file: MediaFile(url: url, size: 0, modified: .now, created: .now), kind: kind)
        }
        let sidecar = dir.appendingPathComponent("IMG_1.xmp")
        func g() -> PhotoGroup {
            PhotoGroup(folder: dir, stem: "IMG_1", stemKey: "img_1", versions: [version(raw, .raw), version(edit, .edit)],
                       sidecar: FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil, legacySidecars: [])
        }
        #expect(g().displayVersion.kind == .edit)
        #expect(g().orientationBase.kind == .raw)
        #expect(try SidecarIO.write([.rotate(clockwise: true)], to: g()).orientation == 3)
        #expect(try SidecarIO.write([.rotate(clockwise: false)], to: g()).orientation == nil)  // back to the RAW's own 6
    }

    @Test func noOpRotationLeavesSidecarUntouched() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try TestImages.makeJPEG(at: jpeg, width: 40, height: 30)
        let sidecar = dir.appendingPathComponent("IMG_1.xmp")
        try fixtureData("lightcraft-two-descriptions").write(to: sidecar)
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: sidecar.path)
        let before = try Data(contentsOf: sidecar)

        let turns = [MetadataChange](repeating: .rotate(clockwise: false), count: 4)
        let m = try SidecarIO.write(turns, to: group(jpeg, sidecar: sidecar))
        #expect(m.orientation == nil)
        #expect(try Data(contentsOf: sidecar) == before)
        let stamp = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date
        #expect(stamp == past)
    }

    @Test func attributeFormUpdatedInPlace() throws {
        let input = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" tiff:Orientation="3"/>\
            </rdf:RDF></x:xmpmeta>
            """
        var doc = try XMPDocument(data: Data(input.utf8))
        #expect(doc.metadata.orientation == 3)
        doc.apply([.rotate(clockwise: true)], embeddedOrientation: 1)
        let text = String(decoding: doc.serialized(), as: UTF8.self)
        #expect(text.contains("tiff:Orientation=\"8\""))
        #expect(!text.contains("<tiff:Orientation"))
        #expect(doc.metadata.orientation == 8)
    }

    @Test func elementFormUpdatedInPlace() throws {
        var doc = try XMPDocument(data: fixtureData("orientation-element"))
        doc.apply([.rotate(clockwise: false)], embeddedOrientation: 1)
        let found = try orientationElements(doc.serialized())
        #expect(found.count == 1)
        #expect(found.first?.description == 1)  // stays in the Description that had it
        #expect(found.first?.value == "3")
    }

    @Test func readerReportsOrientation() throws {
        let doc = try XMPDocument(data: fixtureData("orientation-element"))
        #expect(doc.metadata.orientation == 8)
        #expect(doc.metadata.rating == 2)
        #expect(try XMPDocument(data: fixtureData("lightcraft-two-descriptions")).metadata.orientation == nil)
    }

    @Test func embeddedXMPOrientationIsNotAnOverride() throws {
        // A file's own XMP describes the file; only a sidecar can override it.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try TestImages.makeJPEG(at: jpeg, width: 40, height: 30, orientation: 6, embeddedXMP: (rating: 2, subjects: []))
        let m = try SidecarIO.read(group(jpeg))
        #expect(m.rating == 2)
        #expect(m.orientation == nil)
    }

    @Test func legacySidecarOrientationCarriesIntoNewSidecar() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try TestImages.makeJPEG(at: jpeg, width: 40, height: 30)
        let legacy = dir.appendingPathComponent("IMG_1.jpg.xmp")
        try fixtureData("orientation-element").write(to: legacy)
        let file = MediaFile(url: jpeg, size: 0, modified: .now, created: .now)
        let g = PhotoGroup(folder: dir, stem: "IMG_1", stemKey: "img_1", versions: [GroupedVersion(file: file, kind: .jpeg)],
                           sidecar: nil, legacySidecars: [legacy])
        #expect(try SidecarIO.read(g).orientation == 8)
        let m = try SidecarIO.write([.setRating(4)], to: g)
        #expect(m.orientation == 8)
        let created = dir.appendingPathComponent("IMG_1.xmp")
        #expect(try orientationElements(Data(contentsOf: created)).map(\.value) == ["8"])
    }

    @Test func imageBytesNeverChange() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try TestImages.makeJPEG(at: jpeg, width: 40, height: 30, orientation: 3, embeddedXMP: (rating: 1, subjects: ["a"]))
        let before = try sha256(jpeg)
        try SidecarIO.write([.rotate(clockwise: true)], to: group(jpeg))
        let sidecar = dir.appendingPathComponent("IMG_1.xmp")
        for clockwise in [true, false, false, true, true] {
            try SidecarIO.write([.rotate(clockwise: clockwise)], to: group(jpeg, sidecar: sidecar))
        }
        #expect(try sha256(jpeg) == before)
    }

    @Test func rotationIsNotGuardedAgainstStaleRevert() {
        let pending = StaleRevertGuard.pending(for: [.rotate(clockwise: true), .setRating(3)], before: PhotoMetadata())
        #expect(pending.map(\.field) == ["rating"])
    }
}
