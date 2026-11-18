import Foundation

public struct ScriptItem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case executable, shortcut }
    public var url: URL
    public var title: String
    public var kind: Kind

    public init(url: URL, title: String, kind: Kind) {
        self.url = url
        self.title = title
        self.kind = kind
    }
}

/// Lists the scripts in a folder: executable regular files and `.shortcut` files.
public struct ScriptCatalog: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func scripts() -> [ScriptItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var items: [ScriptItem] = []
        for url in urls {
            guard (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let title = url.deletingPathExtension().lastPathComponent
            if url.pathExtension.lowercased() == "shortcut" {
                items.append(ScriptItem(url: url, title: title, kind: .shortcut))
            } else if fm.isExecutableFile(atPath: url.path) {
                items.append(ScriptItem(url: url, title: title, kind: .executable))
            }
        }
        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
