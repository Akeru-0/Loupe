import Foundation

public enum SharePreferences {
    static let key = "share.removeLocation"

    /// Defaults to `true` when never set.
    public static var removeLocation: Bool {
        get { removeLocation(in: .standard) }
        set { setRemoveLocation(newValue, in: .standard) }
    }

    static func removeLocation(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func setRemoveLocation(_ value: Bool, in defaults: UserDefaults) {
        defaults.set(value, forKey: key)
    }

    /// `$TMPDIR/Loupe-Share/`
    public static var defaultOutputDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Loupe-Share", isDirectory: true)
    }

    /// Removes everything in the share folder. The app calls this once at launch.
    public static func clearOutputDirectory(_ directory: URL = defaultOutputDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
