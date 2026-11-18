import Foundation

public enum EditorPreferences {
    static let key = "editor.defaultAppPath"

    public static var defaultEditor: URL? {
        get { defaultEditor(in: .standard) }
        set { setDefaultEditor(newValue, in: .standard) }
    }

    static func defaultEditor(in defaults: UserDefaults) -> URL? {
        defaults.string(forKey: key).map { URL(fileURLWithPath: $0) }
    }

    static func setDefaultEditor(_ url: URL?, in defaults: UserDefaults) {
        if let url { defaults.set(url.path, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
