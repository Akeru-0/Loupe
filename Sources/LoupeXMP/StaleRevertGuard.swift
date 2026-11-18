import Foundation
import LoupeCore

/// LightCraft rewrites the fields it owns (rating, keywords) from its own catalog on every save, and does not
/// notice external sidecar edits. Loupe remembers its edits as `Pending` entries and restores them when a
/// LightCraft write put the old values back. Pure logic; `Library` stores the entries and applies corrections.
public enum StaleRevertGuard {
    /// `field` is `"rating"`, `"favorite"`, `"tag:<t>"` or `"album:<a>"`.
    /// `value`/`previous` are the rating number, `"present"` or `"absent"`.
    /// `previous` is what the sidecar held before Loupe's first still-unresolved edit of the field,
    /// i.e. what a stale LightCraft write would put back.
    public struct Pending: Hashable, Codable, Sendable {
        public var field: String
        public var value: String
        public var previous: String

        public init(field: String, value: String, previous: String) {
            self.field = field
            self.value = value
            self.previous = previous
        }
    }

    static let present = "present", absent = "absent"

    // MARK: - Recording

    /// Entries for the fields `changes` actually change, relative to `before`.
    public static func pending(for changes: [MetadataChange], before: PhotoMetadata) -> [Pending] {
        var state = before
        var result: [Pending] = []
        for change in changes {
            var entry: Pending?
            switch change {
            case .setRating(let n):
                entry = Pending(field: "rating", value: String(n), previous: String(state.rating))
                state.rating = n
            case .setFavorite(let on):
                entry = Pending(field: "favorite", value: flag(on), previous: flag(state.isFavorite))
                state.isFavorite = on
            case .addTag(let t):
                entry = Pending(field: "tag:" + t, value: present, previous: flag(contains(state.tags, t)))
                if !contains(state.tags, t) { state.tags.append(t) }
            case .removeTag(let t):
                entry = Pending(field: "tag:" + t, value: absent, previous: flag(contains(state.tags, t)))
                state.tags.removeAll { key($0) == key(t) }
            case .addToAlbum(let a):
                entry = Pending(field: "album:" + a, value: present, previous: flag(contains(state.albums, a)))
                if !contains(state.albums, a) { state.albums.append(a) }
            case .removeFromAlbum(let a):
                entry = Pending(field: "album:" + a, value: absent, previous: flag(contains(state.albums, a)))
                state.albums.removeAll { key($0) == key(a) }
            }
            if let entry, entry.value != entry.previous { result = merge(result, with: [entry]) }
        }
        return result
    }

    /// Folds newer entries into older ones. A second edit of the same field replaces the value but keeps the
    /// first `previous` (that is what LightCraft's catalog still holds). If the edits cancel out, the entry goes.
    public static func merge(_ existing: [Pending], with new: [Pending]) -> [Pending] {
        var result = existing
        for n in new {
            if let i = result.firstIndex(where: { sameField($0.field, n.field) }) {
                var merged = result[i]
                merged.value = n.value
                if merged.value == merged.previous { result.remove(at: i) } else { result[i] = merged }
            } else if n.value != n.previous {
                result.append(n)
            }
        }
        return result
    }

    // MARK: - Evaluating

    /// - `corrections`: changes that restore values a stale write reverted (current still equals `previous`).
    /// - `resolved`: entries to forget: LightCraft caught up (current == value), or something else set a
    ///   different value (the user changed it elsewhere on purpose, so it wins).
    /// Entries needing a correction are neither: LightCraft may revert them again on its next save.
    public static func evaluate(
        _ pending: [Pending], current: PhotoMetadata
    ) -> (corrections: [MetadataChange], resolved: [Pending]) {
        var corrections: [MetadataChange] = []
        var resolved: [Pending] = []
        for p in pending {
            let now = currentValue(of: p.field, in: current)
            if now == p.value {
                resolved.append(p)
            } else if now == p.previous, let change = change(for: p) {
                corrections.append(change)
            } else {
                resolved.append(p)
            }
        }
        return (corrections, resolved)
    }

    // MARK: - Helpers

    private static func flag(_ on: Bool) -> String { on ? present : absent }

    /// Tags and albums compare NFC-normalised and case-insensitively, so a LightCraft spelling change
    /// does not look like a lost keyword (which would restore it forever).
    private static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
    private static func contains(_ list: [String], _ s: String) -> Bool { list.contains { key($0) == key(s) } }

    private static func sameField(_ a: String, _ b: String) -> Bool {
        a == b || (a.hasPrefix("tag:") && b.hasPrefix("tag:") && key(a) == key(b))
            || (a.hasPrefix("album:") && b.hasPrefix("album:") && key(a) == key(b))
    }

    private static func currentValue(of field: String, in m: PhotoMetadata) -> String {
        if field == "rating" { return String(m.rating) }
        if field == "favorite" { return flag(m.isFavorite) }
        if let t = field.dropPrefix("tag:") { return flag(contains(m.tags, t)) }
        if let a = field.dropPrefix("album:") { return flag(contains(m.albums, a)) }
        return ""
    }

    private static func change(for p: Pending) -> MetadataChange? {
        let on = p.value == present
        if p.field == "rating" { return Int(p.value).map { .setRating($0) } }
        if p.field == "favorite" { return .setFavorite(on) }
        if let t = p.field.dropPrefix("tag:") { return on ? .addTag(t) : .removeTag(t) }
        if let a = p.field.dropPrefix("album:") { return on ? .addToAlbum(a) : .removeFromAlbum(a) }
        return nil
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}
