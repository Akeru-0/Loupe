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

    /// The folder at the top of the library that imports go to by default. It holds the library's photos rather than
    /// being an album, so it is not listed under Albums; its photos show in Library.
    public static let photosFolderName = "Photos"
    /// Where deleted photos wait (30 days) before they go to the system Trash. Not an album; shown only in Recently
    /// Deleted.
    public static let recentlyDeletedFolderName = "Recently Deleted"
    public static let recentlyDeletedDays = 30
    /// A copy of every favorite photo, kept by Loupe (`FavoritesFolder`) so editors can open them all. Never
    /// indexed (the copies would be photos twice), not an album. Only this folder at the top of the library.
    public static let favoritesFolderName = "Favorites"

    public static func standard() -> LibrarySettings {
        LibrarySettings(rootPath: (NSHomeDirectory() as NSString).appendingPathComponent("Pictures"))
    }
}
