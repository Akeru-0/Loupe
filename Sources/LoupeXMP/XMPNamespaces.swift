/// Namespace URIs Loupe matches on. XMP prefixes are arbitrary, so never compare prefixes.
enum XMPNamespaces {
    static let x = "adobe:ns:meta/"
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let lr = "http://ns.adobe.com/lightroom/1.0/"
    static let lc = "http://ns.lightcraft.app/lc/1.0/"
    static let tiff = "http://ns.adobe.com/tiff/1.0/"
    /// IPTC Extension: `PersonInImage` (people named in the photo, as osxphotos and Photos exports write them).
    static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
}
