import AppKit
import LoupeCore
import LoupeIndex
import SwiftUI

/// The rules behind the toolbar's action capsule and Image ▸ Rotate: what they act on, how Favorite toggles (shared
/// with the F key) and which photos can be rotated.
enum ActionBar {
    /// The selection in query order; ids the view doesn't show are left out.
    static func ordered(_ selection: Set<Int64>, in sections: [PhotoSection]) -> [Int64] {
        guard !selection.isEmpty else { return [] }
        return sections.flatMap { $0.photoIDs.filter(selection.contains) }
    }

    /// While the viewer is open, the photo it shows; otherwise the selection in query order.
    /// Nothing is targeted behind the import window or while the tag editor is open.
    static func targets(
        viewerPhotoID: Int64?, selection: Set<Int64>, sections: [PhotoSection],
        showsImport: Bool = false, editsTags: Bool = false
    ) -> [Int64] {
        if showsImport || editsTags { return [] }
        if let viewerPhotoID { return [viewerPhotoID] }
        return ordered(selection, in: sections)
    }

    /// Favorite (button and F): every photo becomes a favorite, unless all already are; then none is.
    static func favoriteValue(after current: [Bool]) -> Bool { !current.allSatisfy { $0 } }

    /// Videos ignore rotation: a photo can be rotated unless what it shows is a video (a Live Photo's still can).
    static func canRotate(_ flags: ActionFlags) -> Bool {
        guard let kind = flags.displayKind else { return false }
        return kind != .video && kind != .live
    }

    /// The photos of `ids` known to be rotatable, in order.
    static func rotatable(_ ids: [Int64], flags: [Int64: ActionFlags]) -> [Int64] {
        ids.filter { flags[$0].map(canRotate) == true }
    }
}

/// Which of the capsule's buttons work, and whether the heart is filled. `flags` are as last loaded; they may lag
/// behind a selection change by a moment.
struct ActionBarState: Equatable {
    var canInfo = false
    var canPlay = false
    var canShare = false
    var canFavorite = false
    var canRotate = false
    /// Every target is a favorite.
    var isFavorite = false

    init(targets: [Int64], flags: [Int64: ActionFlags], viewHasPhotos: Bool) {
        canPlay = !targets.isEmpty || viewHasPhotos
        guard !targets.isEmpty else { return }
        canInfo = true
        canShare = true
        canFavorite = true
        isFavorite = targets.allSatisfy { flags[$0]?.isFavorite == true }
        // Disabled only when every target is known to be a video; the action itself re-checks.
        canRotate = targets.contains { id in flags[id].map(ActionBar.canRotate) ?? true }
    }
}

// MARK: - Model

extension AppModel {
    /// What the action bar and Image ▸ Rotate act on (`ActionBar.targets`).
    var actionTargetIDs: [Int64] {
        ActionBar.targets(
            viewerPhotoID: viewerPhotoID, selection: selection, sections: photoSections,
            showsImport: importModel != nil, editsTags: tagEditorPhotoIDs != nil)
    }

    var actionBarState: ActionBarState {
        let viewHasPhotos = importModel == nil && tagEditorPhotoIDs == nil
            && photoSections.contains { !$0.photoIDs.isEmpty }
        return ActionBarState(targets: actionTargetIDs, flags: actionFlags, viewHasPhotos: viewHasPhotos)
    }

    /// Loads the targets' `ActionFlags` off the main thread, 150 ms after the last change (⌘A, ⇧-arrow bursts and
    /// library changes coalesce). Flags of earlier targets are kept, so going back to a photo shows its state at once.
    func reloadActionBar() {
        actionBarTask?.cancel()
        guard let library else {
            actionFlags = [:]
            return
        }
        actionBarTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            let ids = actionTargetIDs
            guard !ids.isEmpty, let loaded = await Self.loadFlags(ids, library: library),
                !Task.isCancelled, self.library === library
            else { return }
            actionFlags.merge(loaded) { $1 }
        }
    }

    /// Runs a menu entry's action; errors are presented.
    func runAction(_ perform: @escaping ActionPerform) {
        Task {
            do { try await perform(self) } catch { present(error) }
        }
    }

    /// Favorite on every target, or off if all of them are favorites (the F key's rule).
    func toggleFavoriteOfTargets() {
        let ids = actionTargetIDs
        guard let library, !ids.isEmpty else { return }
        Task {
            guard let flags = await Self.loadFlags(ids, library: library) else { return }
            let photoIDs = ids.filter { flags[$0] != nil }
            guard !photoIDs.isEmpty else { return }
            let value = ActionBar.favoriteValue(after: photoIDs.map { flags[$0]?.isFavorite == true })
            // The heart changes at once; the reload after `Library.didChange` confirms it.
            for id in photoIDs { actionFlags[id] = ActionFlags(isFavorite: value, displayKind: flags[id]?.displayKind) }
            let errors = await library.apply([.setFavorite(value)], to: photoIDs)
            await presentActionErrors(errors, "Couldn't change Favorite", library: library)
        }
    }

    var canRotateTargets: Bool { library != nil && actionBarState.canRotate }

    /// Rotates the targets' stills a quarter turn through `Library.apply`; videos are left alone.
    func rotateTargets(clockwise: Bool) {
        let ids = actionTargetIDs
        guard let library, !ids.isEmpty else { return }
        Task {
            guard let flags = await Self.loadFlags(ids, library: library) else { return }
            let photoIDs = ActionBar.rotatable(ids, flags: flags)
            guard !photoIDs.isEmpty else { return NSSound.beep() }
            let errors = await library.apply([.rotate(clockwise: clockwise)], to: photoIDs)
            await presentActionErrors(errors, "Couldn't rotate", library: library)
        }
    }

    /// Image ▸ Rotate Left/Right (⌘L, ⌘R): not while typing in a text field (the search field, a sheet's field).
    func rotateFromMenu(clockwise: Bool) {
        guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
        rotateTargets(clockwise: clockwise)
    }

    /// The Share button: loads the targets (the viewer's focused version when it is open) off the main thread, then
    /// shows the context menu's Share entries below `anchor`.
    func showShareMenu(below anchor: NSView) {
        let ids = actionTargetIDs
        guard let library, !ids.isEmpty else { return }
        let focused = viewerFocusedVersion.flatMap { $0.photoId == viewerPhotoID ? $0 : nil }
        Task {
            guard var selection = await Self.loadSelection(ids, library: library), ids == actionTargetIDs,
                anchor.window != nil
            else { return }
            selection.focusedVersion = focused
            let share = registry.actions.first { $0.id == "share" }?.entries(for: selection).first { $0.id == "share" }
            guard let entries = share?.children, !entries.isEmpty else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries { menu.addItem(ActionMenuItems.item(entry) { self.runAction($0) }) }
            let y = anchor.isFlipped ? anchor.bounds.maxY + 6 : anchor.bounds.minY - 6
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: y), in: anchor)
        }
    }

    private func presentActionErrors(_ errors: [Int64: any Error], _ title: String, library: Library) async {
        guard !errors.isEmpty else { return }
        let index = library.index, ids = Array(errors.keys)
        let names = await Task.detached(priority: .userInitiated) {
            var names: [Int64: String] = [:]
            for id in ids { if let photo = try? index.photo(id: id) { names[id] = photo.stem } }
            return names
        }.value
        PhotoGridController.presentErrors(errors, title, names: names, model: self)
    }

    @concurrent nonisolated private static func loadFlags(_ ids: [Int64], library: Library) async -> [Int64: ActionFlags]? {
        guard !Task.isCancelled else { return nil }
        return try? library.index.actionFlags(ids: ids)
    }

    @concurrent nonisolated private static func loadSelection(_ ids: [Int64], library: Library) async -> ActionSelection? {
        guard !Task.isCancelled else { return nil }
        return try? library.index.actionSelection(ids: ids, root: library.location.rootURL)
    }
}

/// Registry action entries as AppKit menu items, for the grid's context menu and the toolbar's Share menu.
@MainActor enum ActionMenuItems {
    static func item(_ entry: ActionMenuEntry, run: @escaping (@escaping ActionPerform) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.shortcut.map { String($0) } ?? "")
        item.keyEquivalentModifierMask = []
        item.isEnabled = entry.isEnabled
        if let symbol = entry.systemImage { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if !entry.children.isEmpty {
            let submenu = NSMenu(title: entry.title)
            submenu.autoenablesItems = false
            for child in entry.children { submenu.addItem(Self.item(child, run: run)) }
            item.submenu = submenu
        } else if let perform = entry.perform {
            let handler = Handler(perform: perform, run: run)
            item.target = handler
            item.action = #selector(Handler.fire(_:))
            item.representedObject = handler  // the target is weak
        }
        return item
    }

    @MainActor private final class Handler: NSObject {
        let perform: ActionPerform
        let run: (@escaping ActionPerform) -> Void
        init(perform: @escaping ActionPerform, run: @escaping (@escaping ActionPerform) -> Void) {
            self.perform = perform
            self.run = run
        }
        @objc func fire(_ sender: NSMenuItem) { run(perform) }
    }
}

// MARK: - View

/// The toolbar's Photos-style capsule: Info, Play, Share, Favorite and Rotate in their own glass capsule left of
/// the zoom slider. The buttons act on `AppModel.actionTargetIDs`.
struct ActionCapsule: View {
    var model: AppModel
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let showsInfo: State<Bool>
    private let shareAnchor: State<ViewBox>

    init(model: AppModel) {
        self.model = model
        showsInfo = State(initialValue: false)
        shareAnchor = State(initialValue: ViewBox())
    }

    var body: some View {
        let state = model.actionBarState
        HStack(spacing: 12) {
            Button { showsInfo.wrappedValue.toggle() } label: { symbol("info.circle") }
                .help("Get Info")
                .disabled(!state.canInfo)
                .popover(isPresented: showsInfo.projectedValue, arrowEdge: .bottom) { InfoPopover(model: model) }
            Button { model.startSlideshow() } label: { symbol("play.fill") }
                .help("Play Slideshow")
                .disabled(!state.canPlay)
            Button {
                if let view = shareAnchor.wrappedValue.view { model.showShareMenu(below: view) }
            } label: {
                symbol("square.and.arrow.up")
            }
            .background(ViewCapture(box: shareAnchor.wrappedValue))
            .help("Share")
            .disabled(!state.canShare)
            Button { model.toggleFavoriteOfTargets() } label: { symbol(state.isFavorite ? "heart.fill" : "heart") }
                .help(state.isFavorite ? "Unfavorite" : "Favorite")
                .disabled(!state.canFavorite)
            Button {
                model.rotateTargets(clockwise: NSEvent.modifierFlags.contains(.option))
            } label: {
                symbol("rotate.left")
            }
            .help("Rotate Left (⌘L); Option-click to rotate right (⌘R)")
            .disabled(!state.canRotate)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)  // room inside the toolbar's capsule
        .onChange(of: state.canInfo) { _, can in if !can { showsInfo.wrappedValue = false } }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .regular))
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
    }
}

/// Holds the AppKit view a menu is shown from.
final class ViewBox {
    weak var view: NSView?
}

/// Puts a plain NSView behind a SwiftUI view, so an AppKit menu can be anchored to it.
private struct ViewCapture: NSViewRepresentable {
    let box: ViewBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}
