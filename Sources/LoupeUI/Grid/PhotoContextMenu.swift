import AppKit
import LoupeCore
import LoupeIndex

/// The grid's context menu, laid out like Photos': Get Info; Share; Show in Library / Album / Finder; Rotate and the edit
/// items; Create, Add to, Edit With; Duplicate, Hide, Delete; then the other feature actions and Move to Unsorted.
/// Photos items Loupe has nothing behind (Copy Edits, Live Photo, Shared Album…) are shown disabled.
@MainActor enum PhotoContextMenu {
    /// `photos`: the selection's records, in `ids` order; `files`: each one's displayed file; `actions`: the feature
    /// actions' entries, per feature.
    static func make(
        ids: [Int64], photos: [PhotoRecord], files: [URL], actions: [[ActionMenuEntry]], model: AppModel,
        run: @escaping (@escaping ActionPerform) -> Void, trash: @escaping () -> Void,
        setHidden: ((Bool) -> Void)? = nil
    ) -> NSMenu {
        let setHidden = setHidden ?? { model.setHidden(ids, $0) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let count = ids.count == 1 ? "1 Photo" : "\(ids.count) Photos"
        // In Recently Deleted: only what makes sense for a deleted photo.
        if !photos.isEmpty, photos.allSatisfy(Library.isDeleted) {
            menu.addItem(ClosureMenuItem("Get Info") { model.showsInfo = true })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Recover \(count)") { model.recover(ids) })
            menu.addItem(ClosureMenuItem("Delete \(count) Permanently", handler: trash))
            return menu
        }
        let item = { (entry: ActionMenuEntry) in ActionMenuItems.item(entry, run: run) }
        // In a person's photos: correct a wrong match.
        if let opened = model.openedFaceGroup, let group = model.faceGroups.first(where: { $0.id == opened }) {
            for correction in faceCorrections(ids: ids, group: group, model: model) { menu.addItem(correction) }
            menu.addItem(.separator())
        }
        let extras = actions.joined().filter { $0.id != "share" && $0.id != "edit-in" }
        let share = actions.joined().first { $0.id == "share" }
        // Edit opens the default editor (E); Edit With ▸ only chooses which app that is.
        let editEntry = actions.joined().first { $0.id == "edit-in" }
        var edit = editEntry
        edit?.children = []
        var editWith = editEntry
        editWith?.title = "Edit With"
        editWith?.shortcut = nil
        editWith?.systemImage = nil

        if model.query.scope == .unableToUpload {
            menu.addItem(ClosureMenuItem("Retry Upload") { model.scheduleUpload() })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Get Info") { model.showsInfo = true })
        menu.addItem(.separator())
        if let share {
            menu.addItem(item(share))
            menu.addItem(.separator())
        }

        menu.addItem(ClosureMenuItem("Show in Library") { if let id = ids.first { model.reveal(id, in: "library") } })
        menu.addItem(showInAlbum(photos, model: model))
        let finder = ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
        finder.isEnabled = !files.isEmpty
        menu.addItem(finder)
        menu.addItem(.separator())

        let rotateLeft = ClosureMenuItem("Rotate Left") { model.rotateTargets(clockwise: false) }
        let rotateRight = ClosureMenuItem("Rotate Right") { model.rotateTargets(clockwise: true) }
        rotateRight.isAlternate = true  // shown while ⌥ is held
        rotateRight.keyEquivalentModifierMask = .option
        rotateLeft.keyEquivalentModifierMask = []
        menu.addItem(rotateLeft)  // videos alone beep, as with the toolbar button
        menu.addItem(rotateRight)
        for title in ["Copy Edits", "Paste Edits", "Revert to Original", "Reprocess RAW"] { menu.addItem(disabled(title)) }
        menu.addItem(.separator())
        menu.addItem(disabled("Use RAW as Original"))
        menu.addItem(.separator())
        let live = disabled("Turn On Live Photo")
        live.image = NSImage(systemSymbolName: "livephoto.slash", accessibilityDescription: nil)
        menu.addItem(live)
        menu.addItem(.separator())

        menu.addItem(submenu("Create", [
            ClosureMenuItem("New Album with Selection…") {
                Task {
                    guard let path = await model.newAlbum(in: "", select: false) else { return }
                    model.move(ids, toFolder: path)
                }
            },
            ClosureMenuItem("Slideshow") { model.startSlideshow() },
        ]))
        let albumItems = AlbumMenu.items(for: ids, model: model)  // "Add to Album ▸", "Move to Unsorted"
        if let add = albumItems.first {
            add.title = "Add to"
            menu.addItem(add)
        }
        let shared = disabled("Add to Shared Album")
        shared.submenu = NSMenu()
        menu.addItem(shared)
        menu.addItem(disabled("Add to Album"))
        if let edit { menu.addItem(item(edit)) }
        if let editWith { menu.addItem(item(editWith)) }
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Duplicate \(count)") { model.duplicate(ids) })
        let allHidden = !photos.isEmpty && photos.allSatisfy(\.isHidden)
        menu.addItem(ClosureMenuItem("\(allHidden ? "Unhide" : "Hide") \(count)") { setHidden(!allHidden) })
        menu.addItem(ClosureMenuItem("Delete \(count)", handler: trash))

        if !extras.isEmpty || albumItems.count > 1 {
            menu.addItem(.separator())
            for entry in extras { menu.addItem(item(entry)) }
            for other in albumItems.dropFirst() { menu.addItem(other) }  // Move to Unsorted
        }
        return menu
    }

    /// "Not Anna" and "Change Person ▸ (everyone else of the same kind, named first) · New Person…".
    private static func faceCorrections(ids: [Int64], group: LibraryIndex.FaceGroup, model: AppModel) -> [NSMenuItem] {
        let person = group.kind == "person"
        let not = ClosureMenuItem("Not \(model.faceGroupTitle(group))") { Task { await model.moveFaces(in: ids, to: .nobody) } }
        let others = model.faceGroups.filter { $0.kind == group.kind && $0.id != group.id }
        let named = others.filter { model.shownName($0) != nil }
            .sorted { model.faceGroupTitle($0).localizedStandardCompare(model.faceGroupTitle($1)) == .orderedAscending }
        let unnamed = others.filter { model.shownName($0) == nil }  // Person 1, 2… in People's order
        var choices: [NSMenuItem] = (named + unnamed).map { other in
            ClosureMenuItem(model.faceGroupTitle(other)) { Task { await model.moveFaces(in: ids, to: .group(other.id)) } }
        }
        if !choices.isEmpty { choices.append(.separator()) }
        choices.append(ClosureMenuItem(person ? "New Person…" : "New Pet…") {
            Task { await model.moveFacesToNewPerson(in: ids, kind: group.kind) }
        })
        return [not, submenu(person ? "Change Person" : "Change Pet", choices)]
    }

    /// The album (folder) each selected photo is in; Unsorted for the root. One photo's album shows that photo in it.
    /// Photos in the Photos folder are in no album.
    private static func showInAlbum(_ photos: [PhotoRecord], model: AppModel) -> NSMenuItem {
        var seen = Set<String>()
        let entries = photos.compactMap { photo -> NSMenuItem? in
            let folder = photo.folderPath.precomposedStringWithCanonicalMapping
            let inPhotos = folder == LibrarySettings.photosFolderName || folder.hasPrefix(LibrarySettings.photosFolderName + "/")
            guard let id = photo.id, !inPhotos, seen.insert(photo.folderPath).inserted else { return nil }
            let itemID = folder.isEmpty ? "unsorted" : "folder:" + folder
            let title = folder.isEmpty ? "Unsorted"
                : String(folder.split(separator: "/").last ?? "").replacingOccurrences(of: ":", with: "/")
            return ClosureMenuItem(title) { model.reveal(id, in: itemID) }
        }
        let item = submenu("Show in Album", entries)
        item.isEnabled = !entries.isEmpty
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
