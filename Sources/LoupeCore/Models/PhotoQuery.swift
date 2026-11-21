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
        /// Photos whose newest edit (`PhotoRecord.lastEditedAt`) falls within the last `days` days.
        case recentlyEdited(days: Int)
        /// Photos with a byte-identical copy in another photo group (Utilities ▸ Duplicates).
        case duplicates
        /// Hidden photos, which every other scope leaves out.
        case hidden
        /// Photos imported from cards, grouped by import day.
        case imports
        /// Photos in the Recently Deleted folder, which every other scope leaves out.
        case recentlyDeleted
        /// Photos whose last cloud upload failed.
        case unableToUpload
        /// Utilities ▸ People: photos showing any of the people and pets found (shown as their grid first).
        case people
        /// Photos showing one person or pet: a face group (`face_group.id`).
        case faceGroup(Int64)
        /// The photos matching a smart album's rules.
        case smartAlbum(SmartAlbum)
    }
    public enum KindFilter: Hashable, Sendable { case any, hasRaw, withoutRaw, videos, lightCraftEdited }
    public enum SortField: Hashable, Sendable { case captureDate, added, name, rating, edited }
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

    /// Shows `scope` (a sidebar item was picked). Recently Edited starts newest edit first; leaving it restores the
    /// default sort, as the edit time means nothing elsewhere. Any other switch keeps the user's sort.
    public mutating func select(_ scope: Scope) {
        let wasEdited = if case .recentlyEdited = self.scope { true } else { false }
        self.scope = scope
        if case .recentlyEdited = scope {
            if !wasEdited { (sort, ascending) = (.edited, false) }
        } else if sort == .edited {
            (sort, ascending) = (.captureDate, true)
        }
    }
}

public struct PhotoSection: Hashable, Sendable {
    public var id: String
    public var title: String
    public var photoIDs: [Int64]
    /// Each photo's capture date, parallel to `photoIDs` (empty when not loaded).
    public var captureDates: [Date?]

    public init(id: String, title: String, photoIDs: [Int64], captureDates: [Date?] = []) {
        self.id = id
        self.title = title
        self.photoIDs = photoIDs
        self.captureDates = captureDates
    }
}
