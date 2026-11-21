import Foundation

/// Import from Apple Photos, done by `osxphotos export` (it reads the Photos library directly; Photos itself is never
/// changed). Its output follows Loupe's conventions: dated `YYYY/YYYY-MM-DD` folders, originals with their RAW and
/// `-edited` versions, `<stem>.xmp` sidecars with keywords, `Favorite`, `Hidden`, albums as `Albums|<name>`, the title
/// and caption, and the people named in each photo with where their faces are (People takes those names). `--update` makes a second run copy only what's new or changed.
public enum ApplePhotosExport {
    /// The Photos library macOS creates.
    public static var defaultLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photos Library.photoslibrary", isDirectory: true)
    }

    /// Where a Python 3 for osxphotos may be (Homebrew on Apple silicon and Intel, then the Command Line Tools').
    public static let pythonCandidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]

    /// The `osxphotos export` arguments. `exportDB`: osxphotos' record of what it exported (for `--update`), kept
    /// out of the library.
    public static func arguments(library: URL, destination: URL, exportDB: URL) -> [String] {
        [
            "export", destination.path, "--library", library.path,
            "--directory", "{created.year}/{created.strftime,%Y-%m-%d}",
            "--sidecar", "xmp", "--sidecar-drop-ext",
            "--edited-suffix", "-edited",
            "--keyword-template", "{favorite?Favorite,}",
            "--keyword-template", "{photo.hidden?Hidden,}",
            "--keyword-template", "Albums|{album,}",
            "--update", "--touch-file", "--exportdb", exportDB.path, "--retry", "3",
            "--no-progress", "--verbose",
        ]
    }

    public struct Progress: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var name: String
    }

    /// "Exporting IMG_9001.JPG (5C7D…jpeg) (1/2517)" → 1 of 2517, IMG_9001.JPG.
    public static func progress(in line: String) -> Progress? {
        guard line.hasPrefix("Exporting "), line.hasSuffix(")"),
            let open = line.range(of: " (", options: .backwards)
        else { return nil }
        let counts = line[open.upperBound..<line.index(before: line.endIndex)].split(separator: "/")
        guard counts.count == 2, let done = Int(counts[0]), let total = Int(counts[1]) else { return nil }
        let name = line.dropFirst("Exporting ".count).prefix { $0 != " " && $0 != "(" }
        return Progress(done: done, total: total, name: String(name))
    }

    public struct Summary: Equatable, Sendable {
        public var processed = 0
        public var exported = 0
        public var updated = 0
        public var skipped = 0
        /// In the library but not on this Mac (only in iCloud): not copied.
        public var missing = 0
        public var errors = 0

        public init() {}
    }

    /// The closing "Processed: 2517 photos, exported: 2, updated: 0, skipped: 5, missing: 1, error: 0" line.
    public static func summary(in line: String) -> Summary? {
        guard line.hasPrefix("Processed: ") else { return nil }
        var summary = Summary()
        for part in line.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let value = Int(pair[1].split(separator: " ").first ?? "") else { continue }
            switch pair[0].lowercased() {
            case "processed": summary.processed = value
            case "exported": summary.exported = value
            case "updated": summary.updated = value
            case "skipped": summary.skipped = value
            case "missing": summary.missing = value
            case "error", "errors": summary.errors = value
            default: break
            }
        }
        return summary
    }

    /// osxphotos couldn't read the library because Loupe lacks Full Disk Access.
    public static func isPermissionError(_ output: String) -> Bool {
        output.contains("Operation not permitted") || output.contains("PermissionError")
            || output.contains("Full Disk Access")
    }
}
