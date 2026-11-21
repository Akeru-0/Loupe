import Foundation

/// A mounted drive the user can eject that isn't a camera card (no `DCIM`): a USB stick, an external disk, a disk
/// image. Listed under Devices so it can be ejected from Loupe.
public struct ExternalDrive: Hashable, Sendable {
    public var volumeURL: URL
    public var name: String

    public init(volumeURL: URL, name: String) {
        self.volumeURL = volumeURL
        self.name = name
    }
}

public enum ExternalDrives {
    /// The ejectable, removable or external local volumes, minus the camera `cards` (listed as cards); never the
    /// startup disk, its system volumes or network shares. Reads volume properties only: call off the main thread.
    public static func current(excluding cards: [Card]) -> [ExternalDrive] {
        let keys: [URLResourceKey] = [
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
            .volumeIsLocalKey, .volumeLocalizedNameKey,
        ]
        let cardPaths = Set(cards.map(\.volumeURL.standardizedFileURL.path))
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url -> ExternalDrive? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true,
                v.volumeIsLocal != false,
                v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsInternal == false,
                !cardPaths.contains(url.standardizedFileURL.path)
            else { return nil }
            return ExternalDrive(volumeURL: url, name: v.volumeLocalizedName ?? url.lastPathComponent)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
