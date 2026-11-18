import Foundation
import LoupeCore

extension XMPDocument {
    private static let emptyPacket = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Loupe">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

    public static func empty() -> XMPDocument {
        // The literal above is known-good; failure here is a programmer error.
        try! XMPDocument(data: Data(emptyPacket.utf8))
    }

    /// True when the tree contains an `rdf:RDF` element; anything else is not an XMP document.
    var hasRDF: Bool {
        guard let root = document.rootElement() else { return false }
        return Self.isElement(root, XMPNamespaces.rdf, "RDF")
            || Self.descendants(of: root).contains { Self.isElement($0, XMPNamespaces.rdf, "RDF") }
    }

    public func serialized() -> Data {
        var data = document.xmlData(options: [.nodePreserveAll])
        // Foundation adds an XML declaration; an xpacket sidecar should start with its packet header.
        let declaration = Data("<?xml version=\"1.0\"?>".utf8)
        if data.starts(with: declaration), data.dropFirst(declaration.count).starts(with: Data("<?xpacket".utf8)) {
            data.removeFirst(declaration.count)
        }
        return data
    }

    /// Applies the changes to the parsed tree, touching only `xmp:Rating`, `dc:subject` and
    /// `lr:hierarchicalSubject`. Everything else in the tree is left as it was.
    public mutating func apply(_ changes: [MetadataChange]) {
        // XMLDocument is a reference type; never mutate a tree another copy of this value shares.
        document = document.copy() as? XMLDocument ?? document
        var editor = Editor(document: document)
        for change in changes { editor.apply(change) }
        if let fresh = try? XMPDocument(data: serialized()) { metadata = fresh.metadata }
    }
}

private struct Editor {
    let document: XMLDocument
    let dc = XMPNamespaces.dc, lr = XMPNamespaces.lr

    var descriptions: [XMLElement] {
        guard let root = document.rootElement() else { return [] }
        return XMPDocument.descendants(of: root).filter { XMPDocument.isElement($0, XMPNamespaces.rdf, "Description") }
    }

    mutating func apply(_ change: MetadataChange) {
        switch change {
        case .setRating(let n): setRating(min(max(n, 0), 5))
        case .setFavorite(let on):
            if on { add(Keywords.favorite, dc, "subject") } else { remove({ $0 == Keywords.favorite }, dc, "subject") }
        case .addTag(let t): add(t, dc, "subject")
        case .removeTag(let t): remove({ $0 == t }, dc, "subject")
        case .addToAlbum(let a):
            add(Keywords.albumPrefix + a, dc, "subject")
            add(Keywords.albumPrefix + a, lr, "hierarchicalSubject")
        case .removeFromAlbum(let a): removeAlbum(a)
        }
    }

    // MARK: Rating

    private mutating func setRating(_ n: Int) {
        let text = String(n)
        var found = false
        for d in descriptions {
            for attr in d.attributes ?? [] where attr.uri == XMPNamespaces.xmp && attr.localName == "Rating" {
                found = true
                if attr.stringValue != text { attr.stringValue = text }
            }
            for case let child as XMLElement in d.children ?? []
            where XMPDocument.isElement(child, XMPNamespaces.xmp, "Rating") {
                found = true
                if (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != text {
                    child.stringValue = text
                }
            }
        }
        // Absent and 0 mean the same thing; don't write a rating just to say "none".
        guard !found, n > 0, let d = firstDescription() else { return }
        let el = XMLElement(name: qualifiedName(XMPNamespaces.xmp, "xmp", "Rating", in: d), uri: XMPNamespaces.xmp)
        el.stringValue = text
        d.addChild(el)
    }

    // MARK: Keyword lists

    private func firstDescription() -> XMLElement? {
        if let d = descriptions.first { return d }
        guard let root = document.rootElement() else { return nil }
        let rdf = [root] + XMPDocument.descendants(of: root)
        guard let container = rdf.first(where: { XMPDocument.isElement($0, XMPNamespaces.rdf, "RDF") }) else { return nil }
        let d = XMLElement(name: qualifiedName(XMPNamespaces.rdf, "rdf", "Description", in: container), uri: XMPNamespaces.rdf)
        d.addAttribute(XMLNode.attribute(
            withName: qualifiedName(XMPNamespaces.rdf, "rdf", "about", in: container), uri: XMPNamespaces.rdf, stringValue: "") as! XMLNode)
        container.addChild(d)
        return d
    }

    private func properties(_ uri: String, _ local: String) -> [XMLElement] {
        descriptions.flatMap { d in
            (d.children ?? []).compactMap { $0 as? XMLElement }.filter { XMPDocument.isElement($0, uri, local) }
        }
    }

    /// The Bag/Seq/Alt inside a property, if it has the expected shape.
    private func container(of property: XMLElement) -> XMLElement? {
        (property.children ?? []).compactMap { $0 as? XMLElement }.first {
            ["Bag", "Seq", "Alt"].contains($0.localName ?? "") && $0.uri == XMPNamespaces.rdf
        }
    }

    private func items(of container: XMLElement) -> [XMLElement] {
        (container.children ?? []).compactMap { $0 as? XMLElement }.filter { XMPDocument.isElement($0, XMPNamespaces.rdf, "li") }
    }

    private func add(_ item: String, _ uri: String, _ local: String) {
        let props = properties(uri, local)
        let wanted = XMPDocument.key(item)
        for p in props {
            if let c = container(of: p), items(of: c).contains(where: { XMPDocument.key($0.stringValue ?? "") == wanted }) { return }
        }
        let target: XMLElement
        if let usable = props.compactMap({ container(of: $0) }).first {
            target = usable
        } else if props.isEmpty, let d = firstDescription() {
            let prop = XMLElement(name: qualifiedName(uri, uri == dc ? "dc" : "lr", local, in: d), uri: uri)
            let bag = XMLElement(name: qualifiedName(XMPNamespaces.rdf, "rdf", "Bag", in: d), uri: XMPNamespaces.rdf)
            prop.addChild(bag)
            d.addChild(prop)
            target = bag
        } else {
            return  // an existing property of unknown shape: leave it alone
        }
        let li = XMLElement(name: qualifiedName(XMPNamespaces.rdf, "rdf", "li", in: target), uri: XMPNamespaces.rdf)
        li.stringValue = item
        target.addChild(li)
    }

    /// Removes matching items; a property whose list becomes empty because of this is removed too.
    private func remove(_ matches: (String) -> Bool, _ uri: String, _ local: String) {
        for p in properties(uri, local) {
            guard let c = container(of: p) else { continue }
            var removed = false
            for li in items(of: c) where matches(li.stringValue ?? "") {
                detach(li)
                removed = true
            }
            if removed && items(of: c).isEmpty { detach(p) }
        }
    }

    private func removeAlbum(_ name: String) {
        let key = XMPDocument.key(name)
        let path = Keywords.albumPrefix.lowercased()
        remove({ XMPDocument.key($0) == XMPDocument.key(Keywords.albumPrefix + name) }, dc, "subject")
        remove({ XMPDocument.key($0) == XMPDocument.key(Keywords.albumPrefix + name) }, lr, "hierarchicalSubject")
        // LightCraft also writes the path split into flat items: `Albums` and `<name>`.
        remove({ XMPDocument.key($0) == key }, dc, "subject")
        let anyAlbumLeft = [(dc, "subject"), (lr, "hierarchicalSubject")].contains { uri, local in
            properties(uri, local).contains { p in
                container(of: p).map { items(of: $0).contains { XMPDocument.key($0.stringValue ?? "").hasPrefix(path) } } ?? false
            }
        }
        if !anyAlbumLeft { remove({ XMPDocument.key($0) == XMPDocument.key("Albums") }, dc, "subject") }
    }

    // MARK: Tree helpers

    /// Removes a node together with the indentation that preceded it.
    private func detach(_ node: XMLNode) {
        if let parent = node.parent as? XMLElement, node.index > 0,
            let prev = parent.child(at: node.index - 1), prev.kind == .text,
            (prev.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            prev.detach()
        }
        node.detach()
    }

    /// A prefixed name for `uri` valid at `element`, declaring the namespace on it when not in scope.
    private func qualifiedName(_ uri: String, _ preferred: String, _ local: String, in element: XMLElement) -> String {
        if let prefix = element.resolvePrefix(forNamespaceURI: uri) {
            return prefix.isEmpty ? local : "\(prefix):\(local)"
        }
        var prefix = preferred
        var n = 1
        while element.resolveNamespace(forName: prefix + ":x") != nil {
            n += 1
            prefix = "\(preferred)\(n)"
        }
        element.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
        return "\(prefix):\(local)"
    }
}
