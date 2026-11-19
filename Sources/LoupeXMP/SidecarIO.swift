import Foundation
import LoupeCore

/// Reads and writes `<stem>.xmp` sidecars. Never touches image or video files.
public enum SidecarIO {
    /// The sidecar that exists on disk for this group, if any.
    private static func existingSidecar(_ group: PhotoGroup) -> URL? {
        if let s = group.sidecar { return s }
        let candidate = group.sidecarURLForWriting
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Sidecar, then the first readable legacy sidecar, then the display version's embedded XMP.
    public static func read(_ group: PhotoGroup) throws -> PhotoMetadata {
        if let sidecar = existingSidecar(group) {
            return try XMPDocument(data: Data(contentsOf: sidecar)).metadata
        }
        for legacy in group.legacySidecars {
            if let data = try? Data(contentsOf: legacy), let doc = try? XMPDocument(data: data) { return doc.metadata }
        }
        var embedded = EmbeddedMetadataReader.metadata(in: group.displayVersion.file.url) ?? PhotoMetadata()
        // A file's own XMP describes the file itself; only a sidecar overrides its orientation.
        embedded.orientation = nil
        return embedded
    }

    @discardableResult
    public static func write(_ changes: [MetadataChange], to group: PhotoGroup) throws -> PhotoMetadata {
        // Only read (never written): what the file the sidecar describes says by itself, for turning from it.
        let embedded = changes.contains { if case .rotate = $0 { true } else { false } }
            ? EmbeddedMetadataReader.orientation(in: group.orientationBase.file.url) : nil
        if let url = existingSidecar(group) {
            return try update(existing: url, changes, embeddedOrientation: embedded)
        }
        return try create(group, changes, embeddedOrientation: embedded)
    }

    /// The photo's rotation (the extra turn for every version) for a sidecar `tiff:Orientation` of `override`:
    /// read against the file the sidecar describes. Reads that file's orientation only when there is an override.
    public static func rotation(of group: PhotoGroup, override: Int?) -> Orientation? {
        guard override != nil else { return nil }
        let base = EmbeddedMetadataReader.orientation(in: group.orientationBase.file.url)
        return Orientation.rotation(override: override, baseEmbedded: base)
    }

    // MARK: -

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func update(
        existing url: URL, _ changes: [MetadataChange], embeddedOrientation: Int?
    ) throws -> PhotoMetadata {
        var retried = false
        while true {
            let stamp = modificationDate(url)
            var doc = try XMPDocument(data: Data(contentsOf: url))
            guard doc.hasRDF else { throw XMPError.malformed("no rdf:RDF element") }
            let before = doc.serialized()
            doc.apply(changes, embeddedOrientation: embeddedOrientation)
            let after = doc.serialized()
            if after == before { return doc.metadata }
            // Someone (LightCraft, Finder) may have rewritten it since we read; redo once on the fresh bytes.
            if !retried, modificationDate(url) != stamp {
                retried = true
                continue
            }
            _ = try XMPDocument(data: after)  // never write bytes we cannot parse back
            try after.write(to: url, options: .atomic)
            return doc.metadata
        }
    }

    private static func create(
        _ group: PhotoGroup, _ changes: [MetadataChange], embeddedOrientation: Int?
    ) throws -> PhotoMetadata {
        let seed = try read(group)
        var doc = XMPDocument.empty()
        var seeding: [MetadataChange] = []
        if seed.rating > 0 { seeding.append(.setRating(seed.rating)) }
        seeding += seed.tags.map { .addTag($0) }
        seeding += seed.albums.map { .addToAlbum($0) }
        if seed.isFavorite { seeding.append(.setFavorite(true)) }
        doc.apply(seeding)
        if let orientation = seed.orientation { doc.setOrientation(orientation) }  // from a legacy sidecar
        doc.apply(changes, embeddedOrientation: embeddedOrientation)

        var result = doc.metadata
        result.hasLightCraftEdits = seed.hasLightCraftEdits
        // Nothing the user can see changed: do not create a sidecar.
        if result == seed { return seed }

        let out = doc.serialized()
        _ = try XMPDocument(data: out)
        try out.write(to: group.sidecarURLForWriting, options: .atomic)
        return result
    }
}
