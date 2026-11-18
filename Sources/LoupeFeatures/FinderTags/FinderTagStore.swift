import Foundation
import LoupeCore

/// Mirrors tags, Favorite and `★n` to Finder tags (extended attributes) on every version file.
///
/// Semantics:
/// - Mirror set = tags ∪ {Favorite if favorite} ∪ {★rating if rating > 0}.
/// - Matching is case-insensitive and Unicode-normalization-insensitive (Finder may return NFD);
///   the stored state is the pushed set, and comparisons use `key(_:)`.
/// - Push replaces tags Loupe previously mirrored (in `lastState`) and any `★*` tag, but keeps
///   other Finder tags already on a file (user-added, not yet pulled) so they are never deleted.
/// - `★*` tags are one-way (Loupe → Finder); they never flow back. Albums are not mirrored.
public struct FinderTagStore: MetadataStore {
    public let id = "finder-tags"
    public init() {}

    private static let star = "\u{2605}"

    static func key(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// Exactly the tags Loupe writes: ★ followed by one digit 1-5. "★★★" or "★ best" are ordinary tags.
    private static func isStar(_ s: String) -> Bool {
        let chars = Array(s)
        return chars.count == 2 && String(chars[0]) == star && ("1"..."5").contains(chars[1])
    }
    private static func isAlbum(_ s: String) -> Bool { s.hasPrefix(Keywords.albumPrefix) }

    static func mirrorSet(_ m: PhotoMetadata) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        var all = m.tags
        if m.isFavorite { all.append(Keywords.favorite) }
        if m.rating > 0 { all.append("\(star)\(m.rating)") }
        for t in all where seen.insert(key(t)).inserted { out.append(t) }
        return out.sorted()
    }

    private static func read(_ file: URL) throws -> [String] {
        var url = file
        url.removeAllCachedResourceValues()
        return try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    /// State: the pushed set plus the names (NFC) of the version files it was pushed to.
    /// Only those files may cause removals on pull; a file not listed (new export, copy, an app's
    /// atomic save that dropped xattrs) contributes additions only. An old-format state (a plain
    /// array of tags) decodes with `files == nil`, meaning "all current files were pushed".
    private struct State: Codable {
        var tags: [String]
        var files: [String]?
        /// NFC file name -> inode at push time. Absent in older states: then names alone decide.
        var inodes: [String: UInt64]?
    }

    /// File identity is the inode (`.systemFileNumber`). Writing Finder tags (an xattr) keeps it;
    /// an atomic replace/re-export at the same path gives a new one (and no tags).
    private static func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.flatMap { $0 }?.uint64Value
    }

    private static func fileName(_ url: URL) -> String { url.lastPathComponent.precomposedStringWithCanonicalMapping }

    private static func decode(_ data: Data?) -> State? {
        guard let data else { return nil }
        if let st = try? JSONDecoder().decode(State.self, from: data) { return st }
        if let tags = try? JSONDecoder().decode([String].self, from: data) { return State(tags: tags, files: nil) }
        return nil
    }

    /// Identical tags are never rewritten (an identical xattr write still emits an FSEvent, which
    /// would loop through the watcher). Sets differing only in case/normalisation are also left alone.
    /// Every file is attempted; the first error is rethrown afterwards.
    public func push(_ metadata: PhotoMetadata, files: [URL], lastState: Data?) throws -> Data {
        let set = Self.mirrorSet(metadata)
        let setKeys = Set(set.map(Self.key))
        let lastKeys = Set((Self.decode(lastState)?.tags ?? []).map(Self.key))
        var firstError: (any Error)?
        for file in files {
            do {
                let current = try Self.read(file)
                var result = set
                for t in current {
                    let k = Self.key(t)
                    if setKeys.contains(k) || lastKeys.contains(k) || Self.isStar(t) { continue }
                    result.append(t)  // user's own Finder tag, not managed by Loupe
                }
                if Set(current.map(Self.key)) == Set(result.map(Self.key)) { continue }
                try (file as NSURL).setResourceValue(result.sorted(), forKey: .tagNamesKey)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return try JSONEncoder().encode(State(
            tags: set, files: files.map(Self.fileName).sorted(),
            inodes: Dictionary(files.compactMap { f in Self.inode(f).map { (Self.fileName(f), $0) } },
                               uniquingKeysWith: { a, _ in a })))
    }

    public func pull(files: [URL], lastState: Data?) throws -> [MetadataChange] {
        let last = Self.decode(lastState)
        let pushed = last?.files.map(Set.init)
        let perFile = try files.map { file in
            Dictionary(
                try Self.read(file).filter { !Self.isStar($0) && !Self.isAlbum($0) }
                    .map { (Self.key($0), $0.precomposedStringWithCanonicalMapping) },
                uniquingKeysWith: { a, _ in a })
        }
        let lastByKey = Dictionary(
            (last?.tags ?? []).filter { !Self.isStar($0) }.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })

        var added: [String: String] = [:]
        for tags in perFile {
            for (k, name) in tags where lastByKey[k] == nil { added[k] = name }
        }
        // Only files that were part of the last push may vote for removal.
        // A file votes only if its name and (when recorded) inode match the last push, so a file
        // replaced at the same path without its tags contributes additions only.
        let voters = zip(files, perFile).filter { file, _ in
            let name = Self.fileName(file)
            guard pushed?.contains(name) ?? true else { return false }
            guard let recorded = last?.inodes?[name] else { return true }
            return Self.inode(file) == recorded
        }.map(\.1)
        var removed: [String: String] = [:]
        for (k, name) in lastByKey where voters.contains(where: { $0[k] == nil }) { removed[k] = name }

        let fav = Self.key(Keywords.favorite)
        var changes: [MetadataChange] = []
        for k in added.keys.sorted() {
            changes.append(k == fav ? .setFavorite(true) : .addTag(added[k]!))
        }
        for k in removed.keys.sorted() {
            changes.append(k == fav ? .setFavorite(false) : .removeTag(removed[k]!))
        }
        return changes
    }
}
