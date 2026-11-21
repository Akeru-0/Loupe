import Foundation

/// `.loupe-deleted.json` in the Recently Deleted folder: for each deleted photo (by stem key), the album it was
/// deleted from and when. On disk next to the files, so it survives a rebuilt index; a dot file, so never indexed.
struct DeletedCatalog: Codable {
    struct Entry: Codable {
        /// Root-relative folder the photo was in; `""` is Unsorted.
        var folder: String
        var deletedAt: Date
    }

    static let fileName = ".loupe-deleted.json"
    var entries: [String: Entry] = [:]

    static func load(in folder: URL) -> DeletedCatalog {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
            let catalog = try? JSONDecoder().decode(DeletedCatalog.self, from: data)
        else { return DeletedCatalog() }
        return catalog
    }

    func save(in folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path),
            let data = try? JSONEncoder().encode(self)
        else { return }
        try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
