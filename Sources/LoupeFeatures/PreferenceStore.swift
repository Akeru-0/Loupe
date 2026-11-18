import Foundation

/// Minimal key-value storage for feature preferences, so tests never touch the real defaults domain.
public protocol PreferenceStore: Sendable {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool?
    func set(_ value: String?, forKey key: String)
    func set(_ value: Bool, forKey key: String)
}

public struct UserDefaultsStore: PreferenceStore {
    nonisolated(unsafe) private let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static let standard = UserDefaultsStore()

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func bool(forKey key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
    public func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}
