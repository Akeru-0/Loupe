import AVFoundation
import AppKit
import LoupeCore
import LoupeIndex
import LoupeMedia
import Observation
import SwiftUI

/// The viewer's state: the photo `AppModel.viewerPhotoID` names, its versions, the focused version and its image
/// or player. Database reads and image decodes run off the main thread; every result is checked against the
/// current photo and focused version before it is shown, so a late result never shows a different photo.
@MainActor @Observable final class PhotoViewerModel {
    struct Records: Sendable {
        var photo: PhotoRecord
        var versions: [VersionRecord]
        var metadata: PhotoMetadata
    }

    /// Full-size images decoded at window size, for the current photo and its neighbours only.
    private struct ImageKey: Hashable {
        var photoID: Int64
        var path: String
        var size: Int64
        var modified: Date
        var maxPixelSize: Int
        /// The photo's extra turn (`PhotoRecord.rotation`); a rotated photo is decoded again.
        var rotation: Int?
    }

    let app: AppModel
    private(set) var photoID: Int64?
    private(set) var records: Records?
    /// The photo is no longer in the index.
    private(set) var isMissing = false
    private(set) var focusedVersion: VersionRecord?
    private(set) var image: CGImage?
    private(set) var imageFailed = false
    private(set) var player: AVPlayer?
    private(set) var actionEntries: [ActionMenuEntry] = []
    var showsInfo = false

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var zoomView: ZoomScrollView?
    /// Bumped whenever the photo or the focused version changes; older results are dropped.
    @ObservationIgnored private var generation = 0
    /// The version the shown `image` belongs to.
    @ObservationIgnored private var imageVersionID: Int64?
    @ObservationIgnored private var fullResolutionRequested = false
    @ObservationIgnored private var recordsTask: Task<Void, Never>?
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var cachedRecords: [Int64: Records] = [:]
    @ObservationIgnored private var fullImages: [ImageKey: CGImage] = [:]
    /// Where the current photo was in the query order, for navigating after it disappeared.
    @ObservationIgnored private var lastIndex = 0
    @ObservationIgnored private var changeObserver: (any NSObjectProtocol)?

    init(app: AppModel) { self.app = app }

    // MARK: - Lifetime

    func start() {
        changeObserver = NotificationCenter.default.addObserver(forName: Library.didChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.reloadCurrent() }
        }
        show(app.viewerPhotoID)
    }

    /// Releases the player, the images and all pending work.
    func stop() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        recordsTask?.cancel()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks = [:]
        focus(nil)
        cachedRecords = [:]
        fullImages = [:]
        records = nil
        photoID = nil
    }

    func close() { app.closeViewer() }

    // MARK: - Photo

    func show(_ id: Int64?) {
        guard let id, id != photoID else { return }
        photoID = id
        if let i = order().firstIndex(of: id) { lastIndex = i }
        recordsTask?.cancel()
        records = nil
        isMissing = false
        focus(nil)
        if let cached = cachedRecords[id] {
            apply(cached, keepFocus: false)
        } else {
            loadRecords(of: id, keepFocus: false)
        }
    }

    private func loadRecords(of id: Int64, keepFocus: Bool) {
        guard let index = app.library?.index else { return }
        recordsTask = Task { [weak self] in
            let loaded = await Self.readRecords(id, index: index)
            guard let self, !Task.isCancelled, self.photoID == id else { return }
            if let loaded {
                cachedRecords[id] = loaded
                apply(loaded, keepFocus: keepFocus)
            } else {
                records = nil
                isMissing = true
                focus(nil)
            }
        }
    }

    private func apply(_ loaded: Records, keepFocus: Bool) {
        let sameOrientation = loaded.photo.rotation == records?.photo.rotation
        records = loaded
        isMissing = false
        if keepFocus, sameOrientation, let current = focusedVersion, loaded.versions.contains(current) {
            rebuildActionEntries()
        } else if keepFocus, !sameOrientation, let current = focusedVersion,
            let rotated = loaded.versions.first(where: { $0.id == current.id })
        {
            focus(rotated)  // same version, turned (its width and height may have swapped)
        } else {
            focus(loaded.versions.first(where: \.isDisplay) ?? loaded.versions.first)
        }
        prefetchNeighbours()
    }

    /// After a library change: re-reads the current photo; its image stays if the focused file didn't change.
    private func reloadCurrent() {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks = [:]
        cachedRecords = [:]
        guard let id = photoID else { return }
        recordsTask?.cancel()
        loadRecords(of: id, keepFocus: true)
    }

    // MARK: - Focused version

    func focus(_ version: VersionRecord?) {
        let samePhoto = version != nil && version?.photoId == focusedVersion?.photoId
        generation += 1
        imageTask?.cancel()
        stopPlayer()
        fullResolutionRequested = false
        imageFailed = false
        focusedVersion = version
        app.viewerFocusedVersion = version
        rebuildActionEntries()
        // Within one photo the previous version stays up until the new one is decoded; another photo starts blank.
        if !samePhoto { setImage(nil, version: nil) }
        guard let version, let url = url(of: version) else { return }
        if Self.isMotion(version.kind) {
            setImage(nil, version: nil)
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        } else {
            loadImage(version, url: url)
        }
    }

    var isStill: Bool { focusedVersion.map { !Self.isMotion($0.kind) } ?? false }

    /// The focused version's full size, for the zoom geometry.
    var pixelSize: CGSize {
        if let v = focusedVersion, let w = v.pixelWidth, let h = v.pixelHeight, w > 0, h > 0 {
            return CGSize(width: w, height: h)
        }
        return image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1, height: 1)
    }

    func url(of version: VersionRecord) -> URL? {
        app.library.map { version.url(in: $0.location.rootURL) }
    }

    private func setImage(_ image: CGImage?, version: Int64?) {
        self.image = image
        imageVersionID = version
    }

    private func stopPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private static func isMotion(_ kind: VersionKind) -> Bool { kind == .video || kind == .live }

    /// Thumbnail first (instantly from the grid's memory cache when it has it), then the window-size decode.
    private func loadImage(_ version: VersionRecord, url: URL) {
        let gen = generation
        let maxPixelSize = windowPixelSize()
        let rotation = photoRotation(of: version)
        let key = Self.key(version, url: url, maxPixelSize: maxPixelSize, rotation: rotation)
        if let full = fullImages[key] {
            setImage(full, version: version.id)
            return
        }
        let file = MediaFile(url: url, size: version.size, modified: version.modified, created: version.modified)
        let loader = app.thumbnailLoader
        let thumbnails = app.library?.thumbnails
        if image == nil, let thumbnail = loader?.cached(file, rotation: rotation) {
            setImage(thumbnail, version: version.id)
        }
        imageTask = Task { [weak self] in
            if self?.image == nil {
                let thumbnail: CGImage?
                if let loader {
                    thumbnail = await loader.image(for: file, kind: version.kind, rotation: rotation)
                } else {
                    thumbnail = await thumbnails?.thumbnail(for: file, kind: version.kind, rotation: rotation)
                }
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                if let thumbnail, self.image == nil { self.setImage(thumbnail, version: version.id) }
            }
            // While ←/→ is held, photos flash by on their thumbnails; only the one that stays gets decoded.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let full = await Self.decode(url, maxPixelSize: maxPixelSize, rotation: rotation)
            guard let self, gen == self.generation, !Task.isCancelled else { return }
            if let full {
                fullImages[key] = full
                if !fullResolutionRequested { setImage(full, version: version.id) }
            } else if imageVersionID != version.id {
                setImage(nil, version: nil)
                imageFailed = true
            }
        }
    }

    /// Zoomed beyond fit: decodes the focused version at its own size (once per focus), replacing the window-size image.
    func requestFullResolution() {
        guard !fullResolutionRequested, let version = focusedVersion, !Self.isMotion(version.kind),
            let url = url(of: version)
        else { return }
        let target = min(16384, max(version.pixelWidth ?? 16384, version.pixelHeight ?? 16384))
        guard target > windowPixelSize() else { return }
        fullResolutionRequested = true
        let gen = generation
        let rotation = photoRotation(of: version)
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            let full = await Self.decode(url, maxPixelSize: target, rotation: rotation)
            guard let self, gen == self.generation, !Task.isCancelled, let full else { return }
            setImage(full, version: version.id)
        }
    }

    private func windowPixelSize() -> Int {
        guard let window = window ?? NSApp.keyWindow else { return 2048 }
        let size = window.frame.size
        return max(512, Int((max(size.width, size.height) * window.backingScaleFactor).rounded()))
    }

    /// The extra turn of the photo `version` belongs to; the same for all its versions.
    private func photoRotation(of version: VersionRecord) -> Int? {
        records?.photo.id == version.photoId ? records?.photo.rotation : nil
    }

    private static func key(_ version: VersionRecord, url: URL, maxPixelSize: Int, rotation: Int?) -> ImageKey {
        ImageKey(photoID: version.photoId, path: url.path, size: version.size, modified: version.modified,
                 maxPixelSize: maxPixelSize, rotation: rotation)
    }

    // MARK: - Neighbours

    private func order() -> [Int64] { app.photoSections.flatMap(\.photoIDs) }

    /// Loads the previous and next photos' records and window-size images; everything else is released.
    private func prefetchNeighbours() {
        guard let id = photoID, let library = app.library else { return }
        let order = order()
        guard let i = order.firstIndex(of: id) else { return }
        let neighbours = [i - 1, i + 1].filter(order.indices.contains).map { order[$0] }
        let keep = Set(neighbours + [id])
        cachedRecords = cachedRecords.filter { keep.contains($0.key) }
        fullImages = fullImages.filter { keep.contains($0.key.photoID) }
        for (nid, task) in prefetchTasks where !keep.contains(nid) { task.cancel() }
        prefetchTasks = prefetchTasks.filter { keep.contains($0.key) }

        let maxPixelSize = windowPixelSize()
        let index = library.index, root = library.location.rootURL
        for nid in neighbours where prefetchTasks[nid] == nil {
            prefetchTasks[nid] = Task(priority: .utility) { [weak self] in
                // Skip neighbours of photos that are only flashed past.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                var loaded = self?.cachedRecords[nid]
                if loaded == nil {
                    loaded = await Self.readRecords(nid, index: index)
                    guard let self, !Task.isCancelled, let loaded else { return }
                    cachedRecords[nid] = loaded
                }
                guard let loaded, let display = loaded.versions.first(where: \.isDisplay) ?? loaded.versions.first,
                    !Self.isMotion(display.kind)
                else { return }
                let url = display.url(in: root)
                let rotation = loaded.photo.rotation
                let key = Self.key(display, url: url, maxPixelSize: maxPixelSize, rotation: rotation)
                guard self?.fullImages[key] == nil else { return }
                let full = await Self.decode(url, maxPixelSize: maxPixelSize, rotation: rotation)
                guard let self, !Task.isCancelled, let full else { return }
                fullImages[key] = full
            }
        }
    }

    // MARK: - Navigation

    func navigate(_ delta: Int) {
        let order = order()
        guard !order.isEmpty else { return }
        let target: Int
        if let i = photoID.flatMap(order.firstIndex(of:)) {
            target = i + delta
        } else {
            // The photo left the query; `lastIndex` now holds the photo after it.
            target = delta > 0 ? lastIndex : lastIndex - 1
        }
        guard order.indices.contains(target) else { return NSSound.beep() }
        app.viewerPhotoID = order[target]
    }

    // MARK: - Keys

    /// `characters` as in `NSEvent.charactersIgnoringModifiers`. Returns false for keys the viewer doesn't use.
    func handleKey(characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let command = KeyCommand.from(characters: characters, modifiers: modifiers) else { return false }
        switch command {
        case .rate(let n): rate(n)
        case .toggleFavorite: toggleFavorite()
        case .edit: performShortcut("e")
        case .trash: trash()
        case .toggleViewer, .closeViewer: close()
        case .previous: navigate(-1)
        case .next: navigate(1)
        case .zoomIn: if isStill { zoomView?.zoom(by: 1.25) }
        case .zoomOut: if isStill { zoomView?.zoom(by: 0.8) }
        }
        return true
    }

    // MARK: - Metadata, trash and actions

    func rate(_ rating: Int) {
        change(.setRating(rating)) {
            $0.photo.rating = rating
            $0.metadata.rating = rating
        }
    }

    func toggleFavorite() {
        guard let records else { return }
        let favorite = ActionBar.favoriteValue(after: [records.photo.isFavorite])
        change(.setFavorite(favorite)) {
            $0.photo.isFavorite = favorite
            $0.metadata.isFavorite = favorite
        }
    }

    /// Shows the change at once; the reload after `Library.didChange` confirms or reverts it.
    private func change(_ change: MetadataChange, _ update: (inout Records) -> Void) {
        guard let id = photoID, var updated = records, let library = app.library else { return }
        update(&updated)
        records = updated
        cachedRecords[id] = updated
        let app = app
        Task {
            let errors = await library.apply([change], to: [id])
            if let error = errors[id] { app.present(error) }
        }
    }

    /// The grid's confirmation and trash flow; afterwards the next photo (or the previous one) is shown.
    func trash() {
        guard let id = photoID, let library = app.library, let window else { return }
        let order = order()
        PhotoGridController.confirmTrash([id], library: library, window: window, model: app) { [weak self] trashed in
            guard let self, trashed.contains(id), self.app.viewerPhotoID == id else { return }
            let gone = Set(trashed)
            let i = order.firstIndex(of: id) ?? 0
            let next = order[min(i + 1, order.count)...].first { !gone.contains($0) }
                ?? order[..<min(i, order.count)].last { !gone.contains($0) }
            if let next { self.app.viewerPhotoID = next } else { self.app.closeViewer() }
        }
    }

    func showInFinder() {
        guard let version = focusedVersion, let url = url(of: version) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func rebuildActionEntries() {
        guard let records, let photoID = records.photo.id, let version = focusedVersion, let root = app.library?.location.rootURL
        else {
            actionEntries = []
            return
        }
        let selection = ActionSelection(
            photos: [records.photo], versions: [photoID: records.versions], focusedVersion: version, root: root)
        actionEntries = app.registry.actions.flatMap { $0.entries(for: selection) }
    }

    func run(_ perform: @escaping ActionPerform) {
        let app = app
        Task { [weak self] in
            do { try await perform(app) } catch { app.present(error) }
            // Entries can show state the action changed (e.g. Share's "Remove Location" checkmark).
            self?.rebuildActionEntries()
        }
    }

    private func performShortcut(_ key: Character) {
        guard let entry = actionEntries.first(where: { $0.shortcut == key && $0.isEnabled }), let perform = entry.perform
        else { return }
        run(perform)
    }

    // MARK: - Off the main thread

    @concurrent nonisolated private static func readRecords(_ id: Int64, index: LibraryIndex) async -> Records? {
        guard !Task.isCancelled, let photo = try? index.photo(id: id), let versions = try? index.versions(ofPhoto: id),
            !versions.isEmpty
        else { return nil }
        return Records(photo: photo, versions: versions, metadata: (try? index.metadata(ofPhoto: id)) ?? PhotoMetadata())
    }

    @concurrent nonisolated private static func decode(_ url: URL, maxPixelSize: Int, rotation: Int?) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return ImageLoader.image(at: url, maxPixelSize: maxPixelSize, rotation: rotation)
    }
}

typealias ActionPerform = @MainActor (any ActionContext) async throws -> Void

/// The full-size viewer, shown over the grid while `AppModel.viewerPhotoID` is set.
struct PhotoViewer: View {
    var model: AppModel
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let viewer: State<PhotoViewerModel>

    init(model: AppModel) {
        self.model = model
        viewer = State(initialValue: PhotoViewerModel(app: model))
    }

    var body: some View {
        let viewer = viewer.wrappedValue
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ViewerContent(viewer: viewer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ViewerBottomBar(viewer: viewer)
            }
            if viewer.showsInfo, let photoID = viewer.photoID {
                Divider()
                InfoPanel(model: model, photoID: photoID, versionID: viewer.focusedVersion?.id)
                    .frame(width: 300)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ViewerKeyCatcher(viewer: viewer))
        .onAppear { viewer.start() }
        .onChange(of: model.viewerPhotoID) { _, id in viewer.show(id) }
        .onDisappear { viewer.stop() }
    }
}

private struct ViewerContent: View {
    var viewer: PhotoViewerModel

    var body: some View {
        ZStack {
            if let player = viewer.player {
                VideoPlayerView(player: player)
            } else if viewer.isStill {
                ZoomableImageView(
                    image: viewer.image, pixelSize: viewer.pixelSize,
                    content: AnyHashable(viewer.focusedVersion?.id), viewer: viewer)
                if viewer.imageFailed {
                    ContentUnavailableView("Can't Display This File", systemImage: "exclamationmark.triangle")
                }
            } else if viewer.isMissing {
                ContentUnavailableView("Photo Unavailable", systemImage: "photo")
            }
        }
    }
}

private struct ViewerBottomBar: View {
    var viewer: PhotoViewerModel

    var body: some View {
        VStack(spacing: 8) {
            if let versions = viewer.records?.versions, versions.count > 1 {
                VersionStrip(viewer: viewer)
            }
            HStack(spacing: 10) {
                Button { viewer.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
                Text(viewer.records?.photo.stem ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let rating = viewer.records?.photo.rating, rating > 0 {
                    Text(String(repeating: "★", count: rating)).foregroundStyle(.secondary)
                }
                if viewer.records?.photo.isFavorite == true {
                    Image(systemName: "heart.fill").foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                ForEach(viewer.actionEntries) { entry in
                    ActionEntryView(entry: entry, run: viewer.run).fixedSize()
                }
                Button("Show in Finder", systemImage: "folder") { viewer.showInFinder() }
                    .disabled(viewer.focusedVersion == nil)
                Toggle(isOn: Binding(get: { viewer.showsInfo }, set: { viewer.showsInfo = $0 })) {
                    Image(systemName: "info.circle")
                }
                .toggleStyle(.button)
                .help("Info")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A registry action entry as a button, a menu, or (with a default action and choices, like Edit) a split button.
private struct ActionEntryView: View {
    let entry: ActionMenuEntry
    let run: (@escaping ActionPerform) -> Void

    var body: some View {
        if entry.children.isEmpty {
            Button {
                if let perform = entry.perform { run(perform) }
            } label: { label }
                .disabled(!entry.isEnabled)
        } else if let perform = entry.perform {
            Menu {
                ActionEntryList(entries: entry.children, run: run)
            } label: { label } primaryAction: { run(perform) }
                .disabled(!entry.isEnabled)
        } else {
            Menu {
                ActionEntryList(entries: entry.children, run: run)
            } label: { label }
                .disabled(!entry.isEnabled)
        }
    }

    @ViewBuilder private var label: some View {
        if let symbol = entry.systemImage {
            Label(entry.title, systemImage: symbol)
        } else {
            Text(entry.title)
        }
    }
}

private struct ActionEntryList: View {
    let entries: [ActionMenuEntry]
    let run: (@escaping ActionPerform) -> Void

    var body: some View {
        ForEach(entries) { ActionEntryView(entry: $0, run: run) }
    }
}

/// Routes the viewer's keys, whichever view inside it (the player, a button) is first responder.
/// It takes first responder from the grid when the viewer opens; the grid takes it back when the viewer closes.
private struct ViewerKeyCatcher: NSViewRepresentable {
    let viewer: PhotoViewerModel

    func makeNSView(context: Context) -> ViewerKeyView {
        let view = ViewerKeyView()
        view.viewer = viewer
        return view
    }

    func updateNSView(_ view: ViewerKeyView, context: Context) {}

    static func dismantleNSView(_ view: ViewerKeyView, coordinator: ()) {
        view.stopMonitoring()
    }
}

private final class ViewerKeyView: NSView {
    weak var viewer: PhotoViewerModel?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        viewer?.window = window
        window.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let characters = event.charactersIgnoringModifiers ?? "", modifiers = event.modifierFlags
            let eventWindow = event.window.map(ObjectIdentifier.init)
            let handled = MainActor.assumeIsolated {
                // Not for other windows, sheets and alerts, or text fields (the search field).
                guard let self, let window = self.window, eventWindow == ObjectIdentifier(window),
                    window.attachedSheet == nil, !(window.firstResponder is NSText), let viewer = self.viewer
                else { return false }
                return viewer.handleKey(characters: characters, modifiers: modifiers)
            }
            return handled ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
