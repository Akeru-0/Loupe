import AppKit
import LoupeIndex

/// The grid's organising menu items: "Add to Album ▸" (the album tree, then New Album…) and "Remove from Album"
/// (to the top of the library, in no album). A photo is in exactly one album, so both move the files.
@MainActor enum AlbumMenu {
    static func items(for ids: [Int64], model: AppModel) -> [NSMenuItem] {
        let tree = model.sidebar.first { $0.id == "albums" }?.items ?? []
        let addMenu = NSMenu(title: "Add to Album")
        addMenu.autoenablesItems = false
        for item in tree { addMenu.addItem(menuItem(item, ids: ids, model: model)) }
        if !tree.isEmpty { addMenu.addItem(.separator()) }
        addMenu.addItem(ClosureMenuItem("New Album…") {
            Task {
                guard let path = await model.newAlbum(in: "", select: false) else { return }
                model.move(ids, toFolder: path)
            }
        })
        let add = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
        add.submenu = addMenu
        let remove = ClosureMenuItem("Remove from Album") { model.move(ids, toFolder: "") }
        return [add, remove]
    }

    /// An album is clickable; one with subfolders opens a submenu that starts with the album itself.
    /// A group only opens a submenu.
    private static func menuItem(_ item: SidebarItem, ids: [Int64], model: AppModel) -> NSMenuItem {
        let add: NSMenuItem? = item.isAlbum ? item.albumFolder.map { folder in
            ClosureMenuItem(item.title) { model.move(ids, toFolder: folder) }
        } : nil
        if item.children.isEmpty, let add { return add }

        let submenu = NSMenu(title: item.title)
        submenu.autoenablesItems = false
        if let add {
            submenu.addItem(add)
            submenu.addItem(.separator())
        }
        for child in item.children { submenu.addItem(menuItem(child, ids: ids, model: model)) }
        let parent = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}
