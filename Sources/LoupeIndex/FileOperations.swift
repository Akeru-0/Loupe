import Foundation
import LoupeCore

public enum FileOperationError: Error {
    case destinationMissing(URL)
    case fileNameMismatch(String)
    case noFreeName(String)
    /// An operation failed and putting the files back failed too; `stranded` still sit at their new location.
    case rollbackFailed(underlying: any Error, stranded: [URL])
}

/// Moves and trashes whole photo groups all-or-nothing. Never overwrites, never touches file contents.
public enum FileOperations {
    /// The group with every sidecar that belongs to it, found by listing the group's folder (real names, real case).
    /// Beyond what the grouper attaches this picks up `<edit stem>.xmp` and case variants of the sidecar name.
    public static func completing(_ g: PhotoGroup) throws -> PhotoGroup {
        let wanted = Set(
            [PhotoGrouper.stemKey(g.stem)]
                + g.versions.map { PhotoGrouper.stemKey($0.file.url.lastPathComponent) }
                + g.versions.filter { $0.kind == .edit }
                .map { PhotoGrouper.stemKey($0.file.url.deletingPathExtension().lastPathComponent) })
        let names = try FileManager.default.contentsOfDirectory(atPath: g.folder.path)
        let sidecars = names.sorted()
            .filter { $0.lowercased().hasSuffix(".xmp") }
            .filter { wanted.contains(PhotoGrouper.stemKey(String($0.dropLast(4)))) }
            .map { g.folder.appendingPathComponent($0) }
        var result = g
        let primary = sidecars.first { PhotoGrouper.stemKey(String($0.deletingPathExtension().lastPathComponent)) == g.stemKey }
        result.sidecar = primary
        result.legacySidecars = sidecars.filter { $0 != primary }
        return result
    }

    @discardableResult
    public static func moveGroup(_ group: PhotoGroup, to destination: URL) throws -> PhotoGroup {
        let g = try completing(group)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw FileOperationError.destinationMissing(destination)
        }
        if sameDirectory(g.folder, destination) { return g }

        let existing = Set(try fm.contentsOfDirectory(atPath: destination.path).map(PhotoGrouper.stemKey))
        let files = g.allFiles
        var newStem = g.stem
        var targets: [(from: URL, to: URL)] = []
        var n = 0
        while true {
            newStem = n == 0 ? g.stem : "\(g.stem) (\(n))"
            targets = try files.map { url in
                let name = n == 0
                    ? url.lastPathComponent
                    : try replacingLeadingStem(in: url.lastPathComponent, key: g.stemKey, with: newStem)
                return (url, destination.appendingPathComponent(name))
            }
            if !targets.contains(where: { existing.contains(PhotoGrouper.stemKey($0.to.lastPathComponent)) }) { break }
            n += 1
            if n > 10_000 { throw FileOperationError.noFreeName(g.stem) }
        }

        var moved: [(from: URL, to: URL)] = []
        do {
            for t in targets {
                try fm.moveItem(at: t.from, to: t.to)  // fails if the destination exists; never replaces
                moved.append(t)
            }
        } catch {
            var stranded: [URL] = []
            for t in moved.reversed() {
                do { try fm.moveItem(at: t.to, to: t.from) } catch { stranded.append(t.to) }
            }
            if stranded.isEmpty { throw error }
            throw FileOperationError.rollbackFailed(underlying: error, stranded: stranded)
        }

        let map = Dictionary(uniqueKeysWithValues: targets.map { ($0.from, $0.to) })
        var result = g
        result.folder = destination
        result.stem = newStem
        result.stemKey = PhotoGrouper.stemKey(newStem)
        result.versions = g.versions.map { v in
            var v = v
            v.file.url = map[v.file.url]!
            return v
        }
        result.sidecar = g.sidecar.flatMap { map[$0] }
        result.legacySidecars = g.legacySidecars.compactMap { map[$0] }
        return result
    }

    /// Moves every file to the Trash; returns the resulting Trash URLs. On failure the files already trashed are put back.
    public static func trashGroup(_ group: PhotoGroup) throws -> [URL] {
        let g = try completing(group)
        let fm = FileManager.default
        var done: [(original: URL, trashed: URL)] = []
        do {
            for url in g.allFiles {
                var result: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &result)
                done.append((url, (result as URL?) ?? url))
            }
        } catch {
            var stranded: [URL] = []
            for d in done.reversed() {
                do { try fm.moveItem(at: d.trashed, to: d.original) } catch { stranded.append(d.trashed) }
            }
            if stranded.isEmpty { throw error }
            throw FileOperationError.rollbackFailed(underlying: error, stranded: stranded)
        }
        return done.map(\.trashed)
    }

    // MARK: - Helpers

    /// Replaces the leading part of `name` whose normalized, case-folded form is `key`.
    private static func replacingLeadingStem(in name: String, key: String, with newStem: String) throws -> String {
        for idx in name.indices {
            let end = name.index(after: idx)
            if PhotoGrouper.stemKey(String(name[..<end])) == key { return newStem + name[end...] }
        }
        throw FileOperationError.fileNameMismatch(name)
    }

    /// Same directory by identity, so case or Unicode spelling differences do not matter.
    static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }
}
