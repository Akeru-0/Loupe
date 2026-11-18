import Foundation

/// A temporary photo tree of generated JPEGs, fake RAW bytes and sidecars. Paths are relative to `root`.
public final class TestLibrary: @unchecked Sendable {
    public let root: URL

    public init() throws {
        // Resolve symlinks (/var -> /private/var) so paths compare equal to what the file system reports.
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("loupe-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func url(_ relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    @discardableResult
    public func addFile(_ relativePath: String, bytes: Data = Data()) throws -> URL {
        let u = url(relativePath)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: u)
        return u
    }

    @discardableResult
    public func addJPEG(
        _ relativePath: String, width: Int = 40, height: Int = 30,
        exif: [CFString: Any] = [:], tiff: [CFString: Any] = [:], creatorTool: String? = nil
    ) throws -> URL {
        let u = url(relativePath)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestImages.makeJPEG(at: u, width: width, height: height, exif: exif, tiff: tiff, creatorTool: creatorTool)
        return u
    }

    /// Bytes no decoder will accept, standing in for a RAW file.
    @discardableResult
    public func addFakeRaw(_ relativePath: String) throws -> URL {
        try addFile(relativePath, bytes: Data("FAKE-RAW-\(relativePath)".utf8))
    }

    @discardableResult
    public func addSidecar(
        _ relativePath: String, rating: Int = 0, tags: [String] = [], albums: [String] = []
    ) throws -> URL {
        let subjects = (tags + albums.map { "Albums|" + $0 }).map { "<rdf:li>\($0)</rdf:li>" }.joined()
        let xml = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
            xmp:Rating="\(rating)"><dc:subject><rdf:Bag>\(subjects)</rdf:Bag></dc:subject></rdf:Description>\
            </rdf:RDF></x:xmpmeta>
            """
        return try addFile(relativePath, bytes: Data(xml.utf8))
    }

    public func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url(relativePath))
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    deinit { cleanup() }
}
