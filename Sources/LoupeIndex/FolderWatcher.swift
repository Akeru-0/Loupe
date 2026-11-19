import CoreServices
import Foundation

/// Reports folders whose contents changed, via FSEvents.
public final class FolderWatcher: @unchecked Sendable {
    /// One batch of events.
    public struct Changes: Equatable, Sendable {
        /// Folders whose direct contents changed.
        public var folders: Set<URL>
        /// Directories that were created, removed or renamed, and paths FSEvents asks to rescan below
        /// (`MustScanSubDirs`): the tree below them may have changed.
        public var directories: Set<URL>
        /// Events were dropped or the root changed: only a full scan is safe.
        public var rescanAll: Bool

        public init(folders: Set<URL> = [], directories: Set<URL> = [], rescanAll: Bool = false) {
            self.folders = folders
            self.directories = directories
            self.rescanAll = rescanAll
        }
    }

    public typealias Handler = @Sendable (_ changes: Changes) -> Void

    private let root: URL
    private let latency: TimeInterval
    private let sinceWhen: FSEventStreamEventId?
    private let onChange: Handler
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "loupe.folderwatcher")

    /// `sinceWhen` replays events from that FSEvents id (see `FSEventsGetCurrentEventId()`); nil means from now.
    public init(
        root: URL, latency: TimeInterval = 0.3, sinceWhen: FSEventStreamEventId? = nil, onChange: @escaping Handler
    ) {
        self.root = root
        self.sinceWhen = sinceWhen
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    /// Returns false if FSEvents refused to create the stream (nothing is watched then).
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(self).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<FolderWatcher>.fromOpaque(info).release() } },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            watcher.handle(paths: Array(list.prefix(count)), flags: (0..<count).map { eventFlags[$0] })
        }
        let resolved = realpath(root.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? root.path
        guard let s = FSEventStreamCreate(
            nil, callback, &context, [resolved] as CFArray, sinceWhen ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags)
        else {
            Unmanaged<FolderWatcher>.fromOpaque(context.info!).release()
            return false
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)  // releases the retained self
            return false
        }
        stream = s
        return true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)  // releases the retained self through the context's release callback
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        onChange(Self.classify(paths: paths, flags: flags))
    }

    static func classify(paths: [String], flags: [FSEventStreamEventFlags]) -> Changes {
        let dropped = FSEventStreamEventFlags(
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let dirChange = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        let isDir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        var changes = Changes()
        for (path, flag) in zip(paths, flags) {
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            let url = URL(fileURLWithPath: trimmed)
            if flag & dropped != 0 { changes.rescanAll = true }
            if flag & mustScan != 0 || (flag & isDir != 0 && flag & dirChange != 0) { changes.directories.insert(url) }
            changes.folders.insert(url.deletingLastPathComponent())
        }
        return changes
    }
}
