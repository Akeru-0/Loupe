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

    private static func isStar(_ s: String) -> Bool { s.hasPrefix(star) }
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

    private static func decode(_ data: Data?) -> [String]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    public func push(_ metadata: PhotoMetadata, files: [URL], lastState: Data?) throws -> Data {
        let set = Self.mirrorSet(metadata)
        let setKeys = Set(set.map(Self.key))
        let lastKeys = Set((Self.decode(lastState) ?? []).map(Self.key))
        for file in files {
            var result = set
            for t in try Self.read(file) {
                let k = Self.key(t)
                if setKeys.contains(k) || lastKeys.contains(k) || Self.isStar(t) { continue }
                result.append(t)  // user's own Finder tag, not managed by Loupe
            }
            try (file as NSURL).setResourceValue(result.sorted(), forKey: .tagNamesKey)
        }
        return try JSONEncoder().encode(set)
    }

    public func pull(files: [URL], lastState: Data?) throws -> [MetadataChange] {
        let last = Self.decode(lastState)
        let perFile = try files.map { file in
            Dictionary(
                try Self.read(file).filter { !Self.isStar($0) && !Self.isAlbum($0) }
                    .map { (Self.key($0), $0.precomposedStringWithCanonicalMapping) },
                uniquingKeysWith: { a, _ in a })
        }
        let lastByKey = Dictionary(
            (last ?? []).filter { !Self.isStar($0) }.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })

        var added: [String: String] = [:]
        for tags in perFile {
            for (k, name) in tags where lastByKey[k] == nil { added[k] = name }
        }
        var removed: [String: String] = [:]
        for (k, name) in lastByKey where perFile.contains(where: { $0[k] == nil }) { removed[k] = name }

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
