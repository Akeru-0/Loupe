import Foundation

public struct PhotoGrouper: Sendable {
    private let editMarkers: [String]

    public init(editMarkers: [String]) {
        self.editMarkers = editMarkers.map { Self.stemKey($0) }.filter { !$0.isEmpty }
    }

    public static func stemKey(_ stem: String) -> String {
        stem.precomposedStringWithCanonicalMapping.lowercased()
    }

    private struct Entry {
        var file: MediaFile
        var kind: VersionKind
    }

    private struct Bucket {
        var entries: [Entry] = []
        var edits: [MediaFile] = []
    }

    public func group(_ files: [MediaFile], sidecars: [URL], in folder: URL) -> [PhotoGroup] {
        var buckets: [String: Bucket] = [:]
        for file in files {
            guard let kind = MediaClassifier.baseKind(forExtension: file.url.pathExtension) else { continue }
            let key = Self.stemKey(file.url.deletingPathExtension().lastPathComponent)
            buckets[key, default: Bucket()].entries.append(Entry(file: file, kind: kind))
        }

        // Merge edit buckets into the bucket they derive from.
        var mergedInto: [String: String] = [:]
        func finalTarget(_ key: String) -> String {
            var k = key
            while let next = mergedInto[k] { k = next }
            return k
        }
        for key in buckets.keys.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            guard let bucket = buckets[key], !bucket.entries.contains(where: { $0.kind == .raw }) else { continue }
            if let target = editTarget(of: key, in: buckets) {
                let dest = finalTarget(target)
                buckets[dest]?.edits += bucket.entries.map(\.file) + bucket.edits
                buckets[key] = nil
                mergedInto[key] = dest
            }
        }

        // Sidecars.
        var primary: [String: URL] = [:]
        var legacy: [String: [URL]] = [:]
        var keyByFileName: [String: String] = [:]
        for (key, bucket) in buckets {
            for file in bucket.entries.map(\.file) + bucket.edits {
                keyByFileName[Self.stemKey(file.url.lastPathComponent)] = key
            }
        }
        for url in sidecars.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "xmp" {
            let base = url.deletingPathExtension().lastPathComponent
            let key = Self.stemKey(base)
            if buckets[key] != nil {
                if primary[key] == nil { primary[key] = url }
            } else if let owner = keyByFileName[key] {
                legacy[owner, default: []].append(url)
            }
        }

        let order: [VersionKind] = [.raw, .jpeg, .heic, .image, .live, .video]
        return buckets.keys.sorted().map { key in
            let bucket = buckets[key]!
            let hasImage = bucket.entries.contains { [.raw, .jpeg, .heic, .image].contains($0.kind) }
            var base = bucket.entries.map { entry -> GroupedVersion in
                let kind: VersionKind = (entry.kind == .video && hasImage) ? .live : entry.kind
                return GroupedVersion(file: entry.file, kind: kind)
            }
            base.sort {
                let a = order.firstIndex(of: $0.kind)!, b = order.firstIndex(of: $1.kind)!
                return a != b ? a < b : $0.file.url.lastPathComponent < $1.file.url.lastPathComponent
            }
            let edits = bucket.edits
                .sorted { ($0.modified, $0.url.lastPathComponent) < ($1.modified, $1.url.lastPathComponent) }
                .map { GroupedVersion(file: $0, kind: .edit) }
            let stem = base[0].file.url.deletingPathExtension().lastPathComponent
            return PhotoGroup(folder: folder, stem: stem, stemKey: key, versions: base + edits,
                              sidecar: primary[key], legacySidecars: legacy[key] ?? [])
        }
    }

    /// The key of another bucket this key is an edit of, if any.
    private func editTarget(of key: String, in buckets: [String: Bucket]) -> String? {
        for marker in editMarkers {
            var searchEnd = key.endIndex
            while let range = key.range(of: marker, options: .backwards, range: key.startIndex..<searchEnd) {
                let prefix = String(key[key.startIndex..<range.lowerBound])
                if !prefix.isEmpty, prefix != key, buckets[prefix] != nil { return prefix }
                searchEnd = range.lowerBound
            }
        }
        return nil
    }
}
