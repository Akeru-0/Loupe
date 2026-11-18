import CryptoKit
import Foundation
import ImageIO
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeXMP

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "xmp"))
    return try Data(contentsOf: url)
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func apply(_ changes: [MetadataChange], to data: Data) throws -> Data {
    var doc = try XMPDocument(data: data)
    doc.apply(changes)
    return doc.serialized()
}

private func group(in dir: URL, stem: String = "IMG_1", sidecar: URL? = nil, jpeg: Bool = true) -> PhotoGroup {
    let file = MediaFile(url: dir.appendingPathComponent(stem + ".jpg"), size: 0, modified: .now, created: .now)
    return PhotoGroup(
        folder: dir, stem: stem, stemKey: stem.lowercased(),
        versions: [GroupedVersion(file: file, kind: .jpeg)], sidecar: sidecar, legacySidecars: [])
}

private func listItems(_ data: Data, _ uri: String, _ local: String) throws -> [String] {
    let doc = try XMLDocument(data: data, options: [.nodePreserveAll])
    var out: [String] = []
    func walk(_ e: XMLElement, inside: Bool) {
        for case let c as XMLElement in e.children ?? [] {
            if c.uri == uri && c.localName == local {
                out += (c.children ?? []).flatMap { ($0 as? XMLElement)?.children ?? [] }.compactMap { $0.stringValue }
            }
            walk(c, inside: inside)
        }
    }
    if let r = doc.rootElement() { walk(r, inside: false) }
    return out
}

private func lcSettings(_ data: Data) throws -> String? {
    let doc = try XMLDocument(data: data, options: [.nodePreserveAll])
    return try doc.nodes(forXPath: "//*[local-name()='settings']").first?.stringValue
}

private func canonicalWithoutKeywords(_ data: Data) throws -> String {
    let doc = try XMLDocument(data: data, options: [.nodePreserveAll])
    for name in ["subject", "hierarchicalSubject"] {
        for n in try doc.nodes(forXPath: "//*[local-name()='\(name)']") { n.detach() }
    }
    return doc.canonicalXMLStringPreservingComments(false)
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func tagStrings(_ tag: CGImageMetadataTag) -> [String] {
    (CGImageMetadataTagCopyValue(tag) as? [AnyObject] ?? []).compactMap { v in
        if CFGetTypeID(v) == CGImageMetadataTagGetTypeID() {
            return CGImageMetadataTagCopyValue(v as! CGImageMetadataTag) as? String
        }
        return v as? String
    }
}

@Suite struct XMPWriteTests {
    @Test func ratingChangeTouchesOnlyRating() throws {
        let input = try fixtureData("lightcraft-two-descriptions")
        let out = try apply([.setRating(4)], to: input)
        let expected = String(decoding: input, as: UTF8.self)
            .replacingOccurrences(of: "<xmp:Rating>0</xmp:Rating>", with: "<xmp:Rating>4</xmp:Rating>")
        // XMLDocument drops the newlines between top-level nodes, so compare canonical XML, not raw bytes.
        func canonical(_ d: Data) throws -> String {
            try XMLDocument(data: d, options: [.nodePreserveAll]).canonicalXMLStringPreservingComments(false)
        }
        #expect(try canonical(out) == canonical(Data(expected.utf8)))
        #expect(String(decoding: out, as: UTF8.self).hasPrefix("<?xpacket"))
    }

    @Test func keywordChangesPreserveForeignContent() throws {
        let input = try fixtureData("lightcraft-two-descriptions")
        let out = try apply([.addTag("Iceland"), .addToAlbum("Trip"), .setFavorite(true)], to: input)
        let m = try XMPDocument(data: out).metadata
        #expect(m == PhotoMetadata(rating: 0, tags: ["Iceland"], albums: ["Trip"], isFavorite: true, hasLightCraftEdits: true))
        #expect(try lcSettings(out) == lcSettings(input))
        #expect(try canonicalWithoutKeywords(out) == canonicalWithoutKeywords(input))
    }

    @Test func appleParserAgrees() throws {
        let input = try fixtureData("lightcraft-two-descriptions")
        let out = try apply([.setRating(4), .addTag("Iceland"), .addToAlbum("Trip"), .setFavorite(true)], to: input)
        let md = try #require(CGImageMetadataCreateFromXMPData(out as CFData))
        let rating = try #require(CGImageMetadataCopyTagWithPath(md, nil, "xmp:Rating" as CFString))
        #expect(CGImageMetadataTagCopyValue(rating) as? String == "4")
        let subject = try #require(CGImageMetadataCopyTagWithPath(md, nil, "dc:subject" as CFString))
        let items = tagStrings(subject)
        #expect(Set(items).isSuperset(of: ["Iceland", "Favorite", "Albums|Trip"]))
        let hier = try #require(CGImageMetadataCopyTagWithPath(md, nil, "lr:hierarchicalSubject" as CFString))
        let hitems = tagStrings(hier)
        #expect(Set(hitems).isSuperset(of: ["Albums|Trip"]))
    }

    @Test func attributeRatingUpdatedInPlace() throws {
        let out = try apply([.setRating(5)], to: fixtureData("attribute-form"))
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("xap:Rating=\"5\""))
        #expect(!text.contains("<xap:Rating"))
        #expect(!text.contains("<xmp:Rating"))
        #expect(try XMPDocument(data: out).metadata.rating == 5)
    }

    @Test func removingLastTagRemovesProperty() throws {
        var doc = XMPDocument.empty()
        doc.apply([.addTag("Iceland")])
        var again = try XMPDocument(data: doc.serialized())
        #expect(again.metadata.tags == ["Iceland"])
        again.apply([.removeTag("Iceland")])
        let text = String(decoding: again.serialized(), as: UTF8.self)
        #expect(!text.contains("subject"))
        #expect(try XMPDocument(data: again.serialized()).metadata.tags == [])
    }

    @Test func removeAlbumCleansLightCraftSplitItems() throws {
        let input = try fixtureData("lightcraft-probe-after-edit")
        let out = try apply([.removeFromAlbum("Loupe Probe")], to: input)
        let m = try XMPDocument(data: out).metadata
        #expect(m.albums == [])
        #expect(m.tags == ["loupe-probe"])
        #expect(try listItems(out, "http://purl.org/dc/elements/1.1/", "subject") == ["loupe-probe"])
        #expect(try listItems(out, "http://ns.adobe.com/lightroom/1.0/", "hierarchicalSubject") == ["loupe-probe"])
        #expect(try lcSettings(out) == lcSettings(input))
    }

    @Test func malformedSidecarIsNeverOverwritten() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, data) in [
            ("malformed", try fixtureData("malformed")),
            ("notxmp", Data("<?xml version=\"1.0\"?><foo/>".utf8)),
        ] {
            let sidecar = dir.appendingPathComponent("\(name).xmp")
            try data.write(to: sidecar)
            let g = group(in: dir, stem: name, sidecar: sidecar)
            #expect(throws: XMPError.self) { try SidecarIO.write([.setRating(3)], to: g) }
            #expect(try Data(contentsOf: sidecar) == data)
        }
    }

    @Test func newSidecarIsSeededFromEmbedded() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try TestImages.makeJPEG(at: jpeg, width: 20, height: 20, embeddedXMP: (rating: 2, subjects: ["Embedded"]))
        let before = try sha256(jpeg)
        let g = group(in: dir)
        let result = try SidecarIO.write([.addTag("New")], to: g)
        #expect(result.rating == 2)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_1.xmp").path))
        let m = try XMPDocument(data: Data(contentsOf: dir.appendingPathComponent("IMG_1.xmp"))).metadata
        #expect(m.rating == 2)
        #expect(m.tags == ["Embedded", "New"])
        let read = try SidecarIO.read(group(in: dir, sidecar: dir.appendingPathComponent("IMG_1.xmp")))
        #expect(read.tags == ["Embedded", "New"])
        #expect(try sha256(jpeg) == before)
    }

    @Test func noOpWriteLeavesFileUntouched() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var doc = XMPDocument.empty()
        doc.apply([.addTag("Iceland")])
        let sidecar = dir.appendingPathComponent("IMG_1.xmp")
        try doc.serialized().write(to: sidecar)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: sidecar.path)
        let bytes = try Data(contentsOf: sidecar)
        try SidecarIO.write([.addTag("iceland"), .setRating(0)], to: group(in: dir, sidecar: sidecar))
        let date = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date
        #expect(date == old)
        #expect(try Data(contentsOf: sidecar) == bytes)
    }

    @Test func noOpWithoutSidecarCreatesNothing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SidecarIO.write([.removeTag("nothing")], to: group(in: dir))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("IMG_1.xmp").path))
    }

    @Test func emptyDocumentIsLoupePacket() throws {
        let doc = XMPDocument.empty()
        #expect(doc.writerToolkit == "Loupe")
        #expect(String(decoding: doc.serialized(), as: UTF8.self).contains("<?xpacket"))
    }
}
