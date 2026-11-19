import Foundation

public struct GroupedVersion: Hashable, Sendable {
    public var file: MediaFile
    public var kind: VersionKind

    public init(file: MediaFile, kind: VersionKind) {
        self.file = file
        self.kind = kind
    }
}

public struct PhotoGroup: Hashable, Sendable {
    public var folder: URL
    public var stem: String
    public var stemKey: String
    public var versions: [GroupedVersion]
    public var sidecar: URL?
    public var legacySidecars: [URL]

    public init(folder: URL, stem: String, stemKey: String, versions: [GroupedVersion],
                sidecar: URL?, legacySidecars: [URL]) {
        self.folder = folder
        self.stem = stem
        self.stemKey = stemKey
        self.versions = versions
        self.sidecar = sidecar
        self.legacySidecars = legacySidecars
    }

    /// Newest edit, else first jpeg/heic/image, else raw, else live/video.
    public var displayVersion: GroupedVersion {
        if let edit = versions.last(where: { $0.kind == .edit }) { return edit }
        for kind in [VersionKind.jpeg, .heic, .image, .raw] {
            if let v = versions.first(where: { $0.kind == kind }) { return v }
        }
        return versions[0]
    }

    /// The file the sidecar describes, whose own orientation a sidecar `tiff:Orientation` is read against:
    /// the RAW if there is one (it owns `<stem>.xmp`, also for LightCraft), else the display version.
    public var orientationBase: GroupedVersion {
        versions.first { $0.kind == .raw } ?? displayVersion
    }

    public var sidecarURLForWriting: URL {
        sidecar ?? folder.appendingPathComponent(stem + ".xmp")
    }

    public var allFiles: [URL] {
        versions.map(\.file.url) + (sidecar.map { [$0] } ?? []) + legacySidecars
    }
}
