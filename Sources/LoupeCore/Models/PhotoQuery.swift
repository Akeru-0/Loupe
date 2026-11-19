import Foundation

/// A smart filter over the media itself, listed in the sidebar's Media Types section.
public enum MediaType: Hashable, Sendable, CaseIterable {
    case videos, panoramas, raw
}

/// What the grid shows: a scope, filters, a sort and a date grouping. Pure value; the index turns it into SQL.
public struct PhotoQuery: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case all
        case favorites
        case recentlyAdded(days: Int)
        case album(String)
        case tag(String)
        /// Non-recursive: photos whose folder path equals this one.
        case folder(String)
        /// Photos loose in the library root.
        case unsorted
        /// Recursive: photos in this folder and in every folder below it (a group).
        case folderTree(String)
        case mediaType(MediaType)
    }
    public enum KindFilter: Hashable, Sendable { case any, hasRaw, withoutRaw, videos, lightCraftEdited }
    public enum SortField: Hashable, Sendable { case captureDate, added, name, rating }
    public enum Grouping: Hashable, Sendable { case none, day, month, year }

    public var scope: Scope
    public var searchText = ""
    public var minRating = 0
    public var kind: KindFilter = .any
    public var camera: String?
    public var lens: String?
    public var sort: SortField = .captureDate
    public var ascending = true
    public var grouping: Grouping = .none

    public init(scope: Scope = .all) { self.scope = scope }
}

public struct PhotoSection: Hashable, Sendable {
    public var id: String
    public var title: String
    public var photoIDs: [Int64]

    public init(id: String, title: String, photoIDs: [Int64]) {
        self.id = id
        self.title = title
        self.photoIDs = photoIDs
    }
}
