import Foundation

public struct LibrarySettings: Codable, Equatable, Sendable {
    public var rootPath: String
    public var editMarkers: [String] = ["-", "_edited", " (edited"]
    public var excludedFolderNames: [String] = ["LightCraft Library"]
    public var recentlyAddedDays: Int = 30

    public init(
        rootPath: String, editMarkers: [String] = ["-", "_edited", " (edited"],
        excludedFolderNames: [String] = ["LightCraft Library"], recentlyAddedDays: Int = 30
    ) {
        self.rootPath = rootPath
        self.editMarkers = editMarkers
        self.excludedFolderNames = excludedFolderNames
        self.recentlyAddedDays = recentlyAddedDays
    }

    public static func standard() -> LibrarySettings {
        LibrarySettings(rootPath: (NSHomeDirectory() as NSString).appendingPathComponent("Pictures"))
    }
}
