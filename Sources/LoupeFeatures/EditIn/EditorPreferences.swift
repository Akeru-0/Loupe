import Foundation

public enum EditorPreferences {
    static let key = "editor.defaultAppPath"

    public static var defaultEditor: URL? {
        get { defaultEditor(in: UserDefaultsStore.standard) }
        set { setDefaultEditor(newValue, in: UserDefaultsStore.standard) }
    }

    static func defaultEditor(in store: any PreferenceStore) -> URL? {
        store.string(forKey: key).map { URL(fileURLWithPath: $0) }
    }

    static func setDefaultEditor(_ url: URL?, in store: any PreferenceStore) {
        store.set(url?.path, forKey: key)
    }
}
