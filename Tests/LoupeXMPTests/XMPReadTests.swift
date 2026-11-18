import Foundation
import Testing
import LoupeCore
import LoupeTestSupport
@testable import LoupeXMP

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "xmp"))
    return try Data(contentsOf: url)
}

private func xmp(description body: String) -> Data {
    Data("""
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:lr="http://ns.adobe.com/lightroom/1.0/">\(body)</rdf:Description>
    </rdf:RDF></x:xmpmeta>
    """.utf8)
}

private func bag(_ tag: String, _ items: [String]) -> String {
    "<\(tag)><rdf:Bag>" + items.map { "<rdf:li>\($0)</rdf:li>" }.joined() + "</rdf:Bag></\(tag)>"
}

@Suite struct XMPReadTests {
    @Test func readsLightCraftTwoDescriptions() throws {
        let doc = try XMPDocument(data: fixture("lightcraft-two-descriptions"))
        #expect(doc.metadata == PhotoMetadata(rating: 0, tags: [], albums: [], isFavorite: false, hasLightCraftEdits: true))
        #expect(doc.writerToolkit == "LightCraft")
    }

    @Test func readsLightCraftSingleDescription() throws {
        let doc = try XMPDocument(data: fixture("lightcraft-single"))
        #expect(doc.metadata == PhotoMetadata(rating: 0, tags: [], albums: [], isFavorite: false, hasLightCraftEdits: true))
    }

    @Test func readsAttributeFormAndOtherPrefixes() throws {
        let m = try XMPDocument(data: fixture("attribute-form")).metadata
        #expect(m.rating == 3)
        #expect(m.tags == ["Iceland"])
        #expect(m.albums == ["Trip"])
        #expect(m.isFavorite)
    }

    @Test func readsOsxphotosSidecars() throws {
        // Synthetic fixtures (Task 3 deferred); people live in PersonInImage and must not become tags.
        let fav = try XMPDocument(data: fixture("osxphotos-album-favorite"))
        #expect(fav.metadata == PhotoMetadata(rating: 5, tags: ["glacier"], albums: ["Iceland 2026"], isFavorite: true))
        #expect(fav.writerToolkit == "XMP Core 6.0.0")

        let edited = try XMPDocument(data: fixture("osxphotos-edited")).metadata
        #expect(edited == PhotoMetadata(rating: 2, tags: ["edited"], albums: ["Family"], isFavorite: false))

        let faces = try XMPDocument(data: fixture("osxphotos-faces")).metadata
        #expect(faces == PhotoMetadata(rating: 0, tags: ["birthday"], albums: [], isFavorite: false))
    }

    @Test func ignoresPlaceholderAlbumNames() throws {
        let m = try XMPDocument(data: xmp(description: bag("dc:subject", ["Albums|", "Albums|_", "Albums|Real"]))).metadata
        #expect(m.albums == ["Real"])
        #expect(m.tags == [])
    }

    @Test func unionsHierarchicalAlbums() throws {
        let body = bag("lr:hierarchicalSubject", ["Albums|A", "Places|Iceland"]) + bag("dc:subject", ["Albums|B"])
        let m = try XMPDocument(data: xmp(description: body)).metadata
        #expect(m.albums == ["B", "A"])
        #expect(m.tags == [])
    }

    @Test func ignoresLightCraftSplitAlbumComponents() throws {
        let m = try XMPDocument(data: fixture("lightcraft-probe-after-edit")).metadata
        #expect(m == PhotoMetadata(rating: 4, tags: ["loupe-probe"], albums: ["Loupe Probe"], isFavorite: false, hasLightCraftEdits: true))
    }

    @Test func rejectsMalformed() throws {
        let data = try fixture("malformed")
        #expect(throws: XMPError.self) { try XMPDocument(data: data) }
    }

    @Test func readsEmbeddedXMP() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestImages.makeJPEG(at: url, width: 16, height: 16, embeddedXMP: (rating: 2, subjects: ["Embedded"]))
        let m = try #require(EmbeddedMetadataReader.metadata(in: url))
        #expect(m.rating == 2)
        #expect(m.tags == ["Embedded"])
    }
}
