import Foundation
import LoupeCore

/// The photos on a card. Read-only: it lists `DCIM/**` and never opens a file for writing.
public enum CardListing {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ]

    /// Groups each folder under `DCIM` with `PhotoGrouper` (hidden files skipped) and returns all groups sorted by
    /// stem, then folder. Throws if any folder cannot be read, so a card is never shown half-listed.
    public static func groups(on card: Card, editMarkers: [String]) throws -> [PhotoGroup] {
        var firstError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: card.dcimURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                if firstError == nil { firstError = error }
                return true
            })
        else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: card.dcimURL]) }

        var files: [URL: [MediaFile]] = [:]
        var sidecars: [URL: [URL]] = [:]
        for case let url as URL in enumerator {
            let v = try url.resourceValues(forKeys: Set(keys))
            guard v.isRegularFile == true else { continue }
            let folder = url.deletingLastPathComponent()
            if url.pathExtension.lowercased() == "xmp" {
                sidecars[folder, default: []].append(url)
            } else {
                let modified = v.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                files[folder, default: []].append(MediaFile(
                    url: url, size: Int64(v.fileSize ?? 0), modified: modified, created: v.creationDate ?? modified))
            }
        }
        if let firstError { throw firstError }

        let grouper = PhotoGrouper(editMarkers: editMarkers)
        let folders = Set(files.keys).union(sidecars.keys)
        return folders.flatMap { grouper.group(files[$0] ?? [], sidecars: sidecars[$0] ?? [], in: $0) }
            .sorted { ($0.stemKey, $0.folder.path) < ($1.stemKey, $1.folder.path) }
    }
}
