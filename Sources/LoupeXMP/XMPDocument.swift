import Foundation
import LoupeCore

public enum XMPError: Error, Equatable {
    case malformed(String)
}

/// A tolerant reader for XMP packets and sidecars. Matches on namespace URI, never prefix,
/// and merges every `rdf:Description` (LightCraft writes two).
public struct XMPDocument {
    public internal(set) var metadata: PhotoMetadata
    /// The parsed tree, kept so writes can edit it in place and leave foreign content untouched.
    var document: XMLDocument
    /// The `x:xmptk` value of the packet, if any.
    public let writerToolkit: String?
    /// Whether any description carries properties in the LightCraft `lc:` namespace (Loupe never writes those).
    public let hasLightCraftData: Bool

    public init(data: Data) throws {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [.nodePreserveAll])
        } catch {
            throw XMPError.malformed(error.localizedDescription)
        }
        guard let root = doc.rootElement() else { throw XMPError.malformed("no root element") }
        document = doc

        writerToolkit = Self.toolkit(of: root)
        let descriptions = Self.descendants(of: root).filter { Self.isElement($0, XMPNamespaces.rdf, "Description") }

        var rating: Int?
        var orientation: Int?
        var subjects: [String] = []
        var hierarchical: [String] = []
        var persons: [String] = []
        var hasEdits = false
        var hasLC = false

        for d in descriptions {
            if (d.attributes ?? []).contains(where: { $0.uri == XMPNamespaces.lc }) { hasLC = true }
            if rating == nil, let text = Self.property(d, XMPNamespaces.xmp, "Rating") {
                rating = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if orientation == nil, let text = Self.property(d, XMPNamespaces.tiff, "Orientation") {
                orientation = Self.orientationValue(text)
            }
            for child in d.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                if child.uri == XMPNamespaces.lc { hasLC = true }
                if Self.isElement(child, XMPNamespaces.dc, "subject") {
                    subjects += Self.listItems(child)
                } else if Self.isElement(child, XMPNamespaces.lr, "hierarchicalSubject") {
                    hierarchical += Self.listItems(child)
                } else if Self.isElement(child, XMPNamespaces.iptcExt, "PersonInImage") {
                    persons += Self.listItems(child)
                } else if Self.isElement(child, XMPNamespaces.lc, "settings"),
                    !(child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    hasEdits = true
                }
            }
        }

        hasLightCraftData = hasLC
        var albums: [String] = []
        var isFavorite = false
        var isHidden = false
        for item in subjects + hierarchical {
            guard item.hasPrefix(Keywords.albumPrefix) else { continue }
            let name = String(item.dropFirst(Keywords.albumPrefix.count))
            if name.isEmpty || name == "_" { continue }
            albums.append(name)
        }
        albums = Self.unique(albums)

        // LightCraft splits `Albums|X` into the flat dc:subject items `Albums` and `X`; those are not tags. Nor are the
        // people named in the photo, which osxphotos also lists in dc:subject (they would flood Tags; Faces reads
        // them from PersonInImage).
        let albumKeys = Set(albums.map(Self.key)).union([Self.key("Albums")]).union(persons.map(Self.key))
        var tags: [String] = []
        for item in subjects {
            if item == Keywords.favorite { isFavorite = true; continue }
            if item == Keywords.hidden { isHidden = true; continue }
            if item.hasPrefix(Keywords.albumPrefix) || albumKeys.contains(Self.key(item)) { continue }
            tags.append(item)
        }

        let valid = rating.flatMap { (1...5).contains($0) ? $0 : nil } ?? 0
        metadata = PhotoMetadata(
            rating: valid, tags: Self.unique(tags), albums: albums,
            isFavorite: isFavorite, isHidden: isHidden, hasLightCraftEdits: hasEdits, orientation: orientation)
    }

    // MARK: - Helpers

    /// An EXIF orientation 1…8, or nil for anything else.
    static func orientationValue(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { (1...8).contains($0) ? $0 : nil }
    }

    static func key(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    static func isElement(_ node: XMLNode, _ uri: String, _ local: String) -> Bool {
        node.kind == .element && node.uri == uri && node.localName == local
    }

    static func descendants(of element: XMLElement) -> [XMLElement] {
        var out: [XMLElement] = []
        for case let child as XMLElement in element.children ?? [] {
            out.append(child)
            out += descendants(of: child)
        }
        return out
    }

    private static func toolkit(of root: XMLElement) -> String? {
        for attr in root.attributes ?? []
        where attr.uri == XMPNamespaces.x && attr.localName == "xmptk" {
            return attr.stringValue
        }
        return nil
    }

    /// A simple property given either as an attribute on the description or as a child element.
    private static func property(_ d: XMLElement, _ uri: String, _ local: String) -> String? {
        for attr in d.attributes ?? [] where attr.uri == uri && attr.localName == local {
            return attr.stringValue
        }
        for case let child as XMLElement in d.children ?? [] where isElement(child, uri, local) {
            return child.stringValue
        }
        return nil
    }

    /// The `rdf:li` texts of a Bag/Seq/Alt property, in order.
    private static func listItems(_ property: XMLElement) -> [String] {
        descendants(of: property)
            .filter { isElement($0, XMPNamespaces.rdf, "li") }
            .compactMap { $0.stringValue }
    }
}
