import Foundation
import LoupeIndex

/// The sidebar's arrangement: items pinned into a Pinned section (which appears with the first pin), the order of the
/// sections and of the items in each section or album group (all changed by dragging), and icons chosen for albums.
/// Pins, item order and icons are kept per library root, the section order for all libraries.
extension AppModel {
    static let pinnedPrefix = "pin:"
    private static let pinnedKey = "sidebar.pinned"
    private static let sectionOrderKey = "sidebar.sectionOrder"
    private static let itemOrderKey = "sidebar.itemOrder"
    private static let iconsKey = "sidebar.icons"

    /// Icons offered for albums and groups (the default is the album's or group's own).
    static let albumIcons: [(name: String, symbol: String)] = [
        ("Album", "rectangle.stack"), ("Folder", "folder"), ("Star", "star"), ("Heart", "heart"),
        ("Camera", "camera"), ("People", "person.2"), ("Pets", "pawprint"), ("Home", "house"),
        ("Travel", "airplane"), ("Car", "car"), ("Mountains", "mountain.2"), ("Beach", "beach.umbrella"),
        ("Nature", "leaf"), ("Sun", "sun.max"), ("Snow", "snowflake"), ("City", "building.2"),
        ("Map", "map"), ("Food", "fork.knife"), ("Party", "party.popper"), ("Gift", "gift"),
        ("Sports", "figure.run"), ("Music", "music.note"), ("Work", "briefcase"), ("Book", "book"),
    ]

    /// Ids of the pinned items (the originals' ids), in the order shown; some may not exist right now.
    var pinnedItemIDs: [String] { pinnedByRoot[effectiveSettings.rootPath] ?? [] }

    /// A pinned row's id is its original's prefixed with `pinnedPrefix`.
    static func originalID(_ id: String) -> String {
        id.hasPrefix(pinnedPrefix) ? String(id.dropFirst(pinnedPrefix.count)) : id
    }

    func canPin(_ item: SidebarItem) -> Bool { !item.id.hasPrefix("device:") && !item.id.hasPrefix("drive:") }
    func isPinned(_ item: SidebarItem) -> Bool { pinnedItemIDs.contains(Self.originalID(item.id)) }

    func togglePin(_ item: SidebarItem) {
        let id = Self.originalID(item.id)
        var ids = pinnedItemIDs
        if let i = ids.firstIndex(of: id) {
            ids.remove(at: i)
            if selectedItemID == Self.pinnedPrefix + id { selectedItemID = id }  // keep showing it
        } else {
            ids.append(id)
        }
        setPinned(ids)
    }

    /// Reorders the Pinned rows (`List.onMove` indices, over the rows shown); pins that don't exist right now keep
    /// their place at the end.
    func movePinned(from source: IndexSet, to destination: Int) {
        let existing = Set(pinnedGroup(from: sidebar)?.items.map { Self.originalID($0.id) } ?? [])
        var shown = pinnedItemIDs.filter(existing.contains)
        shown.move(fromOffsets: source, toOffset: destination)
        setPinned(shown + pinnedItemIDs.filter { !existing.contains($0) })
    }

    /// After an album or group is renamed, its pin, place, icon and those of the albums inside it follow.
    func renameArrangement(from old: String, to new: String) {
        func renamed(_ id: String) -> String {
            id == old ? new : id.hasPrefix(old + "/") ? new + id.dropFirst(old.count) : id
        }
        let ids = pinnedItemIDs.map(renamed)
        if ids != pinnedItemIDs { setPinned(ids) }
        let root = effectiveSettings.rootPath
        if let order = itemOrderByRoot[root] {
            itemOrderByRoot[root] = Dictionary(order.map { (renamed($0.key), $0.value.map(renamed)) }, uniquingKeysWith: { a, _ in a })
            save(itemOrderByRoot, forKey: Self.itemOrderKey)
        }
        if let icons = iconsByRoot[root] {
            iconsByRoot[root] = Dictionary(icons.map { (renamed($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            save(iconsByRoot, forKey: Self.iconsKey)
        }
    }

    /// Reorders the items under `parent` (a section's or an album group's id); `shown` are their ids as shown.
    func moveItems(in parent: String, shown: [String], from source: IndexSet, to destination: Int) {
        var ids = shown
        ids.move(fromOffsets: source, toOffset: destination)
        itemOrderByRoot[effectiveSettings.rootPath, default: [:]][parent] = ids
        save(itemOrderByRoot, forKey: Self.itemOrderKey)
    }

    /// Albums, groups and smart albums can get another icon.
    func canChangeIcon(_ item: SidebarItem) -> Bool {
        if case .smartAlbum = item.scope { return true }
        return !(item.albumFolder ?? "").isEmpty
    }
    func icon(of item: SidebarItem) -> String? { iconsByRoot[effectiveSettings.rootPath]?[Self.originalID(item.id)] }

    /// `nil` puts the album's own icon back.
    func setIcon(_ symbol: String?, for item: SidebarItem) {
        iconsByRoot[effectiveSettings.rootPath, default: [:]][Self.originalID(item.id)] = symbol
        save(iconsByRoot, forKey: Self.iconsKey)
    }

    /// The groups with the saved item order and icons applied, at every level.
    func customized(_ groups: [SidebarGroup]) -> [SidebarGroup] {
        let order = itemOrderByRoot[effectiveSettings.rootPath] ?? [:]
        let icons = iconsByRoot[effectiveSettings.rootPath] ?? [:]
        func apply(_ items: [SidebarItem], under parent: String) -> [SidebarItem] {
            Self.ordered(items, id: \.id, order: order[parent] ?? []).map { item in
                var item = item
                if let icon = icons[item.id] { item.systemImage = icon }
                item.children = apply(item.children, under: item.id)
                return item
            }
        }
        return groups.map { SidebarGroup(id: $0.id, title: $0.title, items: apply($0.items, under: $0.id)) }
    }

    /// Drops the dragged section onto `target`: it takes the target's place, the sections between shift over.
    func moveSection(_ id: String, onto target: String) {
        var ids = sidebarGroups.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        // Sections not shown right now (Devices, an empty Pinned) keep a place at the end.
        sectionOrder = ids + sectionOrder.filter { !ids.contains($0) }
        save(sectionOrder, forKey: Self.sectionOrderKey)
    }

    /// The Pinned section: copies of the pinned items without their children, under `pinnedPrefix` ids.
    func pinnedGroup(from groups: [SidebarGroup]) -> SidebarGroup? {
        var byID: [String: SidebarItem] = [:]
        func collect(_ items: [SidebarItem]) {
            for item in items {
                byID[item.id] = item
                collect(item.children)
            }
        }
        collect(groups.flatMap(\.items))
        let items = pinnedItemIDs.compactMap { byID[$0] }.map { item in
            var pinned = item
            pinned.id = Self.pinnedPrefix + item.id
            pinned.children = []
            return pinned
        }
        return items.isEmpty ? nil : SidebarGroup(id: "pinned", title: "Pinned", items: items)
    }

    /// Sections in `order`; one not in it (Pinned, Devices when they first appear) stays right above the section it
    /// naturally precedes, wherever that was moved (at the end if none).
    static func arranged(_ groups: [SidebarGroup], order: [String]) -> [SidebarGroup] {
        ordered(groups, id: \.id, order: order)
    }

    /// `elements` in `order`; one not in it (a new section or album) stays right above the one it naturally precedes,
    /// wherever that was moved (at the end if none).
    static func ordered<T>(_ elements: [T], id: (T) -> String, order: [String]) -> [T] {
        guard !order.isEmpty else { return elements }
        var next = Double(order.count)
        var keys = [Double](repeating: 0, count: elements.count)
        for i in elements.indices.reversed() {
            if let saved = order.firstIndex(of: id(elements[i])) {
                next = Double(saved)
                keys[i] = next
            } else {
                keys[i] = next - 0.5
            }
        }
        return elements.indices.sorted { (keys[$0], $0) < (keys[$1], $1) }.map { elements[$0] }
    }

    func loadSidebarArrangement() {
        pinnedByRoot = load([String: [String]].self, forKey: Self.pinnedKey) ?? [:]
        sectionOrder = load([String].self, forKey: Self.sectionOrderKey) ?? []
        itemOrderByRoot = load([String: [String: [String]]].self, forKey: Self.itemOrderKey) ?? [:]
        iconsByRoot = load([String: [String: String]].self, forKey: Self.iconsKey) ?? [:]
    }

    private func setPinned(_ ids: [String]) {
        pinnedByRoot[effectiveSettings.rootPath] = ids.isEmpty ? nil : ids
        save(pinnedByRoot, forKey: Self.pinnedKey)
    }

    private func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        preferences.string(forKey: key).flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }

    private func save(_ value: some Encodable, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { preferences.set(String(decoding: data, as: UTF8.self), forKey: key) }
    }
}
