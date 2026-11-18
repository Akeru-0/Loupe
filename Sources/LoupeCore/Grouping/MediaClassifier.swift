import UniformTypeIdentifiers

public enum MediaClassifier {
    public static func baseKind(forExtension ext: String) -> VersionKind? {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return nil }
        if type.conforms(to: .rawImage) { return .raw }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return nil
    }
}
