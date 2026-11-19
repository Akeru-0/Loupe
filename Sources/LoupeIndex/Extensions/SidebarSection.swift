import Foundation
import LoupeCore

/// Where photos dragged onto a sidebar item go.
public enum DropTarget: Hashable, Sendable {
    /// Root-relative folder path (`""` is the root).
    case folder(String)
    case album(String)
}

public struct SidebarItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var scope: PhotoQuery.Scope
    public var children: [SidebarItem]
    public var dropTarget: DropTarget?
    /// A count shown at the row's trailing edge (nil: none).
    public var badge: Int?

    public init(
        id: String, title: String, systemImage: String, scope: PhotoQuery.Scope, children: [SidebarItem] = [],
        dropTarget: DropTarget? = nil, badge: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.scope = scope
        self.children = children
        self.dropTarget = dropTarget
        self.badge = badge
    }
}

/// A group of sidebar items. `items` may read the disk and the index; the app calls it off the main thread.
public protocol SidebarSection: Sendable {
    var id: String { get }
    /// Section header; nil for the untitled top section.
    var title: String? { get }
    /// Sections are shown in ascending order.
    var order: Int { get }
    func items(index: LibraryIndex, root: URL, settings: LibrarySettings) throws -> [SidebarItem]
}
