import Foundation
import LoupeIndex

public enum ScriptsFeature: LoupeFeature {
    public static let scriptsDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Loupe/Scripts", isDirectory: true)

    public static func register(in registry: inout FeatureRegistry) {
        registry.actions.append(ScriptsAction(directory: scriptsDirectory))
    }
}
