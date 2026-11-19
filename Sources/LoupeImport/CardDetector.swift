import AppKit
import Foundation

/// A mounted volume with a `DCIM` folder (a camera card).
public struct Card: Hashable, Sendable {
    public var volumeURL: URL
    public var name: String
    public var dcimURL: URL

    public init(volumeURL: URL, name: String, dcimURL: URL) {
        self.volumeURL = volumeURL
        self.name = name
        self.dcimURL = dcimURL
    }
}

/// Finds camera cards under `volumesURL` and reports the current list whenever a volume mounts or unmounts.
/// Read-only: it only lists directories.
public final class CardDetector: @unchecked Sendable {
    private let volumesURL: URL
    private let center: NotificationCenter
    private let onChange: @Sendable ([Card]) -> Void
    private let lock = NSLock()
    private var observers: [any NSObjectProtocol] = []

    public init(
        volumesURL: URL = URL(fileURLWithPath: "/Volumes"),
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onChange: @escaping @Sendable ([Card]) -> Void
    ) {
        self.volumesURL = volumesURL
        self.center = notificationCenter
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts observing mounts and unmounts. `onChange` runs on the posting thread with the full current list.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard observers.isEmpty else { return }
        observers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.onChange(self.currentCards())
            }
        }
    }

    public func stop() {
        lock.lock()
        let current = observers
        observers = []
        lock.unlock()
        for o in current { center.removeObserver(o) }
    }

    /// Every non-hidden directory under `volumesURL` that has a `DCIM` subdirectory, sorted by name.
    public func currentCards() -> [Card] {
        let fm = FileManager.default
        let volumes = (try? fm.contentsOfDirectory(
            at: volumesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return volumes.compactMap { volume -> Card? in
            guard (try? volume.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let names = try? fm.contentsOfDirectory(atPath: volume.path),
                let dcimName = names.first(where: { $0.uppercased() == "DCIM" })
            else { return nil }
            let dcim = volume.appendingPathComponent(dcimName, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dcim.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return Card(volumeURL: volume, name: volume.lastPathComponent, dcimURL: dcim)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
