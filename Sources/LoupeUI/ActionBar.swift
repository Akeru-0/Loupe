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
    static func targets(viewerPhotoID: Int64?, selection: Set<Int64>, sections: [PhotoSection]) -> [Int64] {
        if let viewerPhotoID { return [viewerPhotoID] }
        return ordered(selection, in: sections)
    }

    /// Favorite (button and F): every photo becomes a favorite, unless all already are; then none is.
    static func favoriteValue(after current: [Bool]) -> Bool { !current.allSatisfy { $0 } }

    /// Videos ignore rotation: a photo can be rotated unless what it shows is a video (a Live Photo's still can).
    static func canRotate(_ versions: [VersionRecord]) -> Bool {
        guard let display = versions.first(where: \.isDisplay) ?? versions.first else { return false }
        return display.kind != .video && display.kind != .live
    }

    /// The photos of `selection` that can be rotated, in its order.
    static func rotatable(in selection: ActionSelection) -> [Int64] {
        selection.photos.compactMap { photo in
            photo.id.flatMap { canRotate(selection.versions[$0] ?? []) ? $0 : nil }
        }
    }
}

/// Which of the capsule's buttons work, and whether the heart is filled. `loaded` is the targets' records as last
/// loaded; it may lag behind a selection change by a moment.
struct ActionBarState: Equatable {
    var canInfo = false
    var canPlay = false
    var canShare = false
    var canFavorite = false
    var canRotate = false
    /// Every target is a favorite.
    var isFavorite = false

    init(targets: [Int64], loaded: ActionSelection?, viewHasPhotos: Bool) {
        canPlay = !targets.isEmpty || viewHasPhotos
        guard !targets.isEmpty else { return }
        canInfo = true
        canShare = true
        canFavorite = true
        let photos = Dictionary(
            (loaded?.photos ?? []).compactMap { p in p.id.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        isFavorite = targets.allSatisfy { photos[$0]?.isFavorite == true }
        // Disabled only when every target is known to be a video; the action itself re-checks.
        canRotate = targets.contains { id in
            photos[id] == nil || ActionBar.canRotate(loaded?.versions[id] ?? [])
        }
    }
}

// MARK: - Model

extension AppModel {
    /// What the action bar and Image ▸ Rotate act on (`ActionBar.targets`).
    var actionTargetIDs: [Int64] {
        ActionBar.targets(viewerPhotoID: viewerPhotoID, selection: selection, sections: photoSections)
    }

    var actionBarState: ActionBarState {
        ActionBarState(
            targets: actionTargetIDs, loaded: actionBarSelection,
            viewHasPhotos: importModel == nil && photoSections.contains { !$0.photoIDs.isEmpty })
    }

    /// Loads the targets' records off the main thread, for the buttons' states and the Share menu.
    func reloadActionBar() {
        actionBarTask?.cancel()
        let ids = actionTargetIDs
        guard let library, !ids.isEmpty else {
            actionBarSelection = nil
            actionBarLoadedIDs = []
            return
        }
        actionBarTask = Task { [weak self] in
            let loaded = await Self.loadSelection(ids, library: library)
            guard let self, !Task.isCancelled, self.library === library else { return }
            actionBarSelection = loaded
            actionBarLoadedIDs = ids
        }
    }

    /// The Share submenu's entries (the context menu's), for the viewer's focused version or the selection;
    /// nil while the targets' records are still loading.
    var shareEntries: [ActionMenuEntry]? {
        _ = actionBarRevision
        let ids = actionTargetIDs
        guard !ids.isEmpty, var selection = actionBarSelection, Set(actionBarLoadedIDs) == Set(ids) else { return nil }
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        selection.photos.sort { (rank[$0.id ?? -1] ?? .max) < (rank[$1.id ?? -1] ?? .max) }
        if let version = viewerFocusedVersion, version.photoId == viewerPhotoID { selection.focusedVersion = version }
        let share = registry.actions.first { $0.id == "share" }?.entries(for: selection).first { $0.id == "share" }
        return share?.children ?? []
    }

    /// Runs a menu entry's action; errors are presented.
    func runAction(_ perform: @escaping ActionPerform) {
        Task {
            do { try await perform(self) } catch { present(error) }
            actionBarRevision += 1
        }
    }

    /// Favorite on every target, or off if all of them are favorites (the F key's rule).
    func toggleFavoriteOfTargets() {
        let ids = actionTargetIDs
        guard let library, !ids.isEmpty else { return }
        Task {
            guard let selection = await Self.loadSelection(ids, library: library), !selection.photos.isEmpty else { return }
            let value = ActionBar.favoriteValue(after: selection.photos.map(\.isFavorite))
            let photoIDs = selection.photos.compactMap(\.id)
            // The heart changes at once; the reload after `Library.didChange` confirms it.
            if var shown = actionBarSelection {
                for i in shown.photos.indices where photoIDs.contains(shown.photos[i].id ?? -1) {
                    shown.photos[i].isFavorite = value
                }
                actionBarSelection = shown
            }
            let errors = await library.apply([.setFavorite(value)], to: photoIDs)
            PhotoGridController.presentErrors(
                errors, "Couldn't change Favorite", names: Self.stems(selection), model: self)
        }
    }

    var canRotateTargets: Bool { library != nil && actionBarState.canRotate }

    /// Rotates the targets' stills a quarter turn through `Library.apply`; videos are left alone.
    func rotateTargets(clockwise: Bool) {
        let ids = actionTargetIDs
        guard let library, !ids.isEmpty else { return }
        Task {
            guard let selection = await Self.loadSelection(ids, library: library) else { return }
            let photoIDs = ActionBar.rotatable(in: selection)
            guard !photoIDs.isEmpty else { return NSSound.beep() }
            let errors = await library.apply([.rotate(clockwise: clockwise)], to: photoIDs)
            PhotoGridController.presentErrors(errors, "Couldn't rotate", names: Self.stems(selection), model: self)
        }
    }

    /// Play. Task 26 replaces this with the slideshow; for now it opens the viewer on the first target, or on the
    /// view's first photo when nothing is selected.
    func startSlideshow() {
        guard let id = actionTargetIDs.first ?? photoSections.lazy.flatMap(\.photoIDs).first else { return }
        viewerPhotoID = id
    }

    @concurrent nonisolated private static func loadSelection(_ ids: [Int64], library: Library) async -> ActionSelection? {
        guard !Task.isCancelled else { return nil }
        return try? library.index.actionSelection(ids: ids, root: library.location.rootURL)
    }

    private static func stems(_ selection: ActionSelection) -> [Int64: String] {
        Dictionary(selection.photos.compactMap { p in p.id.map { ($0, p.stem) } }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - View

/// The toolbar's Photos-style capsule: Info, Play, Share, Favorite and Rotate, one glass capsule left of the zoom
/// slider. The buttons act on `AppModel.actionTargetIDs`.
struct ActionCapsule: View {
    var model: AppModel
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let showsInfo: State<Bool>

    init(model: AppModel) {
        self.model = model
        showsInfo = State(initialValue: false)
    }

    var body: some View {
        let state = model.actionBarState
        HStack(spacing: 2) {
            Button { showsInfo.wrappedValue.toggle() } label: { symbol("info.circle") }
                .help("Get Info")
                .disabled(!state.canInfo)
                .popover(isPresented: showsInfo.projectedValue, arrowEdge: .bottom) { InfoPopover(model: model) }
            Button { model.startSlideshow() } label: { symbol("play.fill") }
                .help("Play Slideshow")
                .disabled(!state.canPlay)
            Menu {
                ShareMenuContent(model: model)
            } label: {
                symbol("square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
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
        .padding(.horizontal, 6)  // room inside the toolbar's capsule, like the zoom slider's
        .onChange(of: state.canInfo) { _, can in if !can { showsInfo.wrappedValue = false } }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .imageScale(.large)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
    }
}

/// The Share button's menu: the context menu's Share entries.
private struct ShareMenuContent: View {
    var model: AppModel

    var body: some View {
        if let entries = model.shareEntries {
            ActionEntryList(entries: entries, run: model.runAction)
        } else {
            Text("Loading…")
        }
    }
}
