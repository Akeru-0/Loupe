import CoreServices
import Foundation

/// Reports folders whose contents changed, via FSEvents. `rescanAll` is set when events were coalesced or
/// dropped, the root changed, or a directory was created, removed or renamed.
public final class FolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (_ folders: Set<URL>, _ rescanAll: Bool) -> Void

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

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }
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
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
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
        let scanAll = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let dirChange = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        let isDir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        var folders = Set<URL>()
        var rescanAll = false
        for (path, flag) in zip(paths, flags) {
            if flag & scanAll != 0 || (flag & isDir != 0 && flag & dirChange != 0) { rescanAll = true }
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            folders.insert(URL(fileURLWithPath: trimmed).deletingLastPathComponent())
        }
        onChange(folders, rescanAll)
    }
}
