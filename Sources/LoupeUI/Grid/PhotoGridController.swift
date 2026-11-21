import AppKit
import LoupeCore
import LoupeIndex
import Observation

/// The photo grid: an `NSCollectionView` with a compositional layout and a diffable data source keyed by photo id,
/// fed from `AppModel.photoSections`. Cell contents load in one batched query off the main thread; thumbnails load
/// asynchronously per cell. Selection, columns and the viewer photo are kept in sync with `AppModel`.
@MainActor final class PhotoGridController: NSViewController, NSCollectionViewDelegate, NSCollectionViewPrefetching {
    /// Dragged photos: each pasteboard item carries one photo's id as a decimal string, next to its file URL.
    static let photoIDsType = NSPasteboard.PasteboardType("local.loupe.photo-ids")

    /// The photo ids of a drag from the grid, in order and without repeats; empty for anything else (Finder files).
    static func photoIDs(in items: [NSPasteboardItem]) -> [Int64] {
        var seen: Set<Int64> = []
        return items.compactMap { $0.string(forType: photoIDsType).flatMap { Int64($0) } }.filter { seen.insert($0).inserted }
    }

    private let model: AppModel
    private let collectionView = GridCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<String, Int64>!

    /// What the data source currently shows.
    private var shownSections: [PhotoSection] = []
    private var columns: Int
    private var infos: [Int64: CellInfo] = [:]
    private var loader: ThumbnailLoader?
    private var library: Library?
    /// Bumped when the library is replaced; results of older loads are dropped.
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var reloadAll = false
    /// Keyboard focus (the item arrows move from) and the fixed end of a ⇧-arrow range.
    private var focusID: Int64?
    private var anchorID: Int64?
    private var magnification: CGFloat = 0
    private var changeObserver: (any NSObjectProtocol)?
    private var scrollObserver: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
        columns = model.columns
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override func loadView() {
        collectionView.grid = self
        collectionView.collectionViewLayout = makeLayout()
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(PhotoCell.self, forItemWithIdentifier: PhotoCell.identifier)
        collectionView.register(
            SectionHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: SectionHeaderView.identifier)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)

        dataSource = NSCollectionViewDiffableDataSource<String, Int64>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            let item = collectionView.makeItem(withIdentifier: PhotoCell.identifier, for: indexPath) as! PhotoCell
            item.configure(id: id, info: self?.infos[id], loader: self?.loader)
            return item
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: SectionHeaderView.identifier, for: indexPath) as! SectionHeaderView
            header.title = self?.section(at: indexPath.section)?.title ?? ""
            return header
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        changeObserver = NotificationCenter.default.addObserver(forName: Library.didChange, object: nil, queue: .main) {
            [weak self] _ in
            // Ratings, favorites, edits or versions may have changed without the sections changing.
            MainActor.assumeIsolated { self?.scheduleRefresh(full: true) }
        }
        let clipView = (view as! NSScrollView).contentView
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibleInfo() }
        }
        observeModel()
        modelChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(collectionView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateVisibleInfo()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        model.visibleMonths = nil
    }

    /// Tells the model the months of the dated photos on screen (the toolbar's subtitle) and the photo at the top
    /// (remembered for the next launch).
    private func updateVisibleInfo() {
        let rect = collectionView.visibleRect
        var first: Date?
        var last: Date?
        var top: IndexPath?
        for attributes in collectionView.collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
        where attributes.representedElementCategory == .item {
            if let path = attributes.indexPath, attributes.frame.midY >= rect.minY, top.map({ path < $0 }) ?? true {
                top = path
            }
            guard let path = attributes.indexPath, let section = section(at: path.section),
                section.captureDates.indices.contains(path.item), let date = section.captureDates[path.item]
            else { continue }
            if first.map({ date < $0 }) ?? true { first = date }
            if last.map({ date > $0 }) ?? true { last = date }
        }
        let calendar = Calendar.current
        func month(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)?.start ?? date }
        var months: ClosedRange<Date>?
        if let first, let last { months = month(first)...month(last) }
        if model.visibleMonths != months { model.visibleMonths = months }
        // Not before the remembered position is back, or the launch position would overwrite it.
        if model.pendingTopPhotoID == nil, let top, let id = dataSource.itemIdentifier(for: top) { model.noteTopPhoto(id) }
    }

    /// After launch: scrolls the remembered photo to the top once the restored view shows it.
    private func restorePendingTop() {
        guard let id = model.pendingTopPhotoID, shownSections == model.photoSections,
            let path = dataSource.indexPath(for: id)
        else { return }
        model.pendingTopPhotoID = nil
        collectionView.layoutSubtreeIfNeeded()
        collectionView.scrollToItems(at: [path], scrollPosition: .top)
    }

    // MARK: - Model sync

    private func observeModel() {
        withObservationTracking {
            _ = model.library
            _ = model.photoSections
            _ = model.columns
            _ = model.selection
            _ = model.viewerPhotoID
            _ = model.slideshow  // its end hands the last shown photo over like the viewer's
            _ = model.pendingRevealID
            _ = model.pendingTopPhotoID
        } onChange: { [weak self] in
            // Called before the change is stored; read the new values on the next main-actor turn.
            Task { @MainActor in
                guard let self else { return }
                self.observeModel()
                self.modelChanged()
            }
        }
    }

    private func modelChanged() {
        if model.library !== library {
            library = model.library
            generation += 1
            refreshTask?.cancel()
            refreshTask = nil
            refreshAgain = false
            infos = [:]
            loader = library.map { ThumbnailLoader(thumbnails: $0.thumbnails) }
            model.thumbnailLoader = loader
            scheduleRefresh(full: false)
        } else if model.photoSections != shownSections {
            scheduleRefresh(full: false)
        }
        if model.columns != columns { applyColumns(model.columns) }
        // Only the viewer closing itself hands its photo back; programmatic resets leave selection and focus alone.
        let closedViewerPhoto = model.viewerPhotoID == nil ? model.takeClosedViewerPhoto() : nil
        if let id = closedViewerPhoto, dataSource.indexPath(for: id) != nil, model.selection != [id] {
            model.selection = [id]
        }
        syncSelectionFromModel(prune: false)
        if let id = closedViewerPhoto {
            revealAfterViewer(id)
            aimViewerLanding(at: id)
        }
        revealPending()  // already showing the view it is in
        restorePendingTop()
    }

    /// Opens the viewer on `id`, its photo flying in from the tile (hidden until the viewer covers it).
    private func openViewer(_ id: Int64) {
        if ViewerFlight.isEnabled, let path = dataSource.indexPath(for: id),
            let cell = collectionView.item(at: path) as? PhotoCell, let image = cell.shownImage,
            collectionView.visibleRect.intersects(cell.view.frame), let from = cell.view.flightRect(cell.photoFrame)
        {
            model.viewerOpening = ViewerFlight(photoID: id, image: image, from: from)
            hideDuringFlight(cell)
        }
        model.viewerPhotoID = id
    }

    /// Aims the photo flying back from the closed viewer at its tile (scrolled into view by now), hiding the tile
    /// until it lands.
    private func aimViewerLanding(at id: Int64) {
        guard var flight = model.viewerClosing, flight.photoID == id, !flight.isAimed else { return }
        collectionView.layoutSubtreeIfNeeded()
        if flight.image != nil, let path = dataSource.indexPath(for: id),
            let frame = collectionView.layoutAttributesForItem(at: path)?.frame,
            collectionView.visibleRect.intersects(frame)
        {
            let size = flight.image.map { CGSize(width: $0.width, height: $0.height) }
            flight.to = collectionView.flightRect(PhotoCellView.photoRect(for: size, in: frame))
            if let item = collectionView.item(at: path) { hideDuringFlight(item) }
        }
        flight.isAimed = true
        model.viewerClosing = flight
    }

    private func hideDuringFlight(_ item: NSCollectionViewItem) {
        item.view.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + ViewerFlight.duration) { [weak item] in
            item?.view.alphaValue = 1
        }
    }

    /// The viewer closed on `id` (selected by now): scroll it into view and take the keyboard back.
    private func revealAfterViewer(_ id: Int64) {
        if let path = dataSource.indexPath(for: id) {
            focusID = id
            anchorID = id
            collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        }
        view.window?.makeFirstResponder(collectionView)
    }

    /// Loads missing (or, with `full`, all) cell infos off the main thread, then shows the model's sections.
    /// Requests while a load runs are coalesced into one more pass.
    private func scheduleRefresh(full: Bool) {
        reloadAll = reloadAll || full
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        let gen = generation
        refreshTask = Task { [weak self] in await self?.refresh(generation: gen) }
    }

    private func refresh(generation gen: Int) async {
        repeat {
            refreshAgain = false
            let sections = model.photoSections
            let full = reloadAll
            reloadAll = false
            if let library {
                let all = sections.flatMap(\.photoIDs)
                let ids = full ? all : all.filter { infos[$0] == nil }
                if !ids.isEmpty {
                    let index = library.index, root = library.location.rootURL
                    let loaded = await Task.detached(priority: .userInitiated) {
                        Result { try index.cellInfo(ids: ids, root: root) }
                    }.value
                    guard gen == generation else { return }
                    switch loaded {
                    case .success(let loaded): merge(loaded, requested: ids)
                    case .failure(let error): model.log("Could not load photo details: \(error.localizedDescription)")
                    }
                }
            }
            show(sections)
        } while refreshAgain && gen == generation
        if gen == generation { refreshTask = nil }
    }

    private func merge(_ loaded: [Int64: CellInfo], requested: [Int64]) {
        var changed: Set<Int64> = []
        for id in requested where infos[id] != loaded[id] {
            infos[id] = loaded[id]
            changed.insert(id)
        }
        reconfigureVisible(changed)
    }

    private func show(_ sections: [PhotoSection]) {
        guard sections != shownSections else { return }
        var snapshot = NSDiffableDataSourceSnapshot<String, Int64>()
        for section in sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.photoIDs, toSection: section.id)
        }
        shownSections = sections
        dataSource.apply(snapshot, animatingDifferences: false)
        syncSelectionFromModel(prune: sections == model.photoSections)
        revealPending()
        restorePendingTop()
        DispatchQueue.main.async { [weak self] in self?.updateVisibleInfo() }  // once the new items are laid out
    }

    /// Show in Library / Show in Album: once the new view's photos are shown, selects the photo and scrolls to it.
    private func revealPending() {
        guard let id = model.pendingRevealID, shownSections == model.photoSections, dataSource.indexPath(for: id) != nil
        else { return }
        model.pendingRevealID = nil
        model.selection = [id]
        syncSelectionFromModel(prune: false)
        revealAfterViewer(id)
    }

    private func reconfigureVisible(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        for case let cell as PhotoCell in collectionView.visibleItems() {
            if let id = cell.photoID, ids.contains(id) { cell.configure(id: id, info: infos[id], loader: loader) }
        }
    }

    private func section(at index: Int) -> PhotoSection? {
        shownSections.indices.contains(index) ? shownSections[index] : nil
    }

    // MARK: - Selection

    private func selectedIDs() -> Set<Int64> {
        Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
    }

    /// The selection in grid order.
    private func orderedSelection() -> [Int64] {
        ActionBar.ordered(model.selection, in: shownSections)
    }

    /// Model → grid. With `prune`, ids the grid no longer shows are dropped from the model's selection.
    private func syncSelectionFromModel(prune: Bool) {
        let wanted = model.selection
        if selectedIDs() != wanted {
            collectionView.selectionIndexPaths = Set(wanted.compactMap { dataSource.indexPath(for: $0) })
        }
        if prune {
            let shown = selectedIDs()
            if shown != wanted { model.selection = shown }
        }
    }

    /// Grid → model, after the user changed the selection. Equal values aren't written, so nothing echoes back.
    func selectionDidChange() {
        let ids = selectedIDs()
        if ids != model.selection { model.selection = ids }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let id = indexPaths.max().flatMap({ dataSource.itemIdentifier(for: $0) }) {
            focusID = id
            if collectionView.selectionIndexPaths.count == 1 { anchorID = id }
        }
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    private func moveFocus(_ direction: GridLayout.Direction, extend: Bool) {
        let current = focusID.flatMap { model.selection.contains($0) ? dataSource.indexPath(for: $0) : nil }
            ?? orderedSelection().first.flatMap { dataSource.indexPath(for: $0) }
        let target: IndexPath?
        if let current {
            target = GridLayout.neighbor(
                of: current, direction, sectionCounts: shownSections.map(\.photoIDs.count), columns: columns)
        } else {
            target = shownSections.firstIndex { !$0.photoIDs.isEmpty }.map { IndexPath(item: 0, section: $0) }
        }
        guard let target, let targetID = dataSource.itemIdentifier(for: target) else { return }
        focusID = targetID
        var ids: [Int64] = [targetID]
        if extend, let anchorID {
            let flat = shownSections.flatMap(\.photoIDs)
            if let a = flat.firstIndex(of: anchorID), let b = flat.firstIndex(of: targetID) {
                ids = Array(flat[min(a, b)...max(a, b)])
            }
        } else {
            anchorID = targetID
        }
        collectionView.selectionIndexPaths = Set(ids.compactMap { dataSource.indexPath(for: $0) })
        selectionDidChange()
        collectionView.scrollToItems(at: [target], scrollPosition: .nearestHorizontalEdge)
    }

    // MARK: - Keys and mouse

    /// Plain keys (and ⌘ keys that reach `keyDown`). Returns false for keys the collection view should handle.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty, let direction = Self.direction(event.specialKey) {
            moveFocus(direction, extend: event.modifierFlags.contains(.shift))
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers == "a" {
            collectionView.selectAll(nil)
            return true
        }
        guard let command = KeyCommand.from(characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags)
        else { return false }
        switch command {
        case .rate(let n): rate(n)
        case .toggleFavorite: toggleFavorite()
        case .edit: performShortcut("e")
        case .trash: confirmTrash()
        case .toggleViewer: toggleViewer()
        case .closeViewer:
            guard model.viewerPhotoID != nil else { return false }
            model.closeViewer()
        case .zoomIn: zoom(by: -1)
        case .zoomOut: zoom(by: 1)
        case .previous, .next: return false
        }
        return true
    }

    /// ⌘⌫, ⌘+ and ⌘- arrive as key equivalents before they reach `keyDown`.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let command = KeyCommand.from(characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags)
        else { return false }
        switch command {
        case .trash: confirmTrash()
        case .zoomIn: zoom(by: -1)
        case .zoomOut: zoom(by: 1)
        default: return false
        }
        return true
    }

    private static func direction(_ key: NSEvent.SpecialKey?) -> GridLayout.Direction? {
        switch key {
        case .leftArrow?: .left
        case .rightArrow?: .right
        case .upArrow?: .up
        case .downArrow?: .down
        default: nil
        }
    }

    func doubleClicked(_ event: NSEvent) {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let path = collectionView.indexPathForItem(at: point), let id = dataSource.itemIdentifier(for: path) else { return }
        openViewer(id)
    }

    private func toggleViewer() {
        if model.viewerPhotoID != nil {
            model.closeViewer()
        } else if let id = focusID.flatMap({ model.selection.contains($0) ? $0 : nil }) ?? orderedSelection().first {
            openViewer(id)
        }
    }

    // MARK: - Metadata and trash

    private func rate(_ rating: Int) {
        let ids = orderedSelection()
        guard !ids.isEmpty else { return }
        update(ids) { $0.rating = rating }
        apply(.setRating(rating), to: ids, failure: "Couldn't change the rating")
    }

    private func toggleFavorite() {
        let ids = orderedSelection()
        guard !ids.isEmpty else { return }
        let favorite = ActionBar.favoriteValue(after: ids.map { infos[$0]?.isFavorite == true })
        update(ids) { $0.isFavorite = favorite }
        apply(.setFavorite(favorite), to: ids, failure: "Couldn't change Favorite")
    }

    /// Shows the change at once; the index reload after `Library.apply` confirms or reverts it.
    private func update(_ ids: [Int64], _ change: (inout CellInfo) -> Void) {
        for id in ids {
            guard var info = infos[id] else { continue }
            change(&info)
            infos[id] = info
        }
        reconfigureVisible(Set(ids))
    }

    private func apply(_ change: MetadataChange, to ids: [Int64], failure: String) {
        guard let library else { return }
        Task { [weak self] in
            let errors = await library.apply([change], to: ids)
            self?.presentErrors(errors, failure)
        }
    }

    private func confirmTrash() {
        let ids = orderedSelection()
        guard !ids.isEmpty, let library, let window = view.window else { return }
        Self.confirmTrash(ids, library: library, window: window, model: model)
    }

    /// Asks (as a sheet on `window`) before deleting `ids` with all their files, then deletes them and presents
    /// per-photo errors. Photos go to Recently Deleted; ones already there go to the Trash for good. `completion`
    /// gets the ids that were deleted. Shared with the viewer.
    static func confirmTrash(
        _ ids: [Int64], library: Library, window: NSWindow, model: AppModel,
        completion: @escaping @MainActor ([Int64]) -> Void = { _ in }
    ) {
        let index = library.index, root = library.location.rootURL
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                Result { try index.actionSelection(ids: ids, root: root) }
            }.value
            guard model.library === library else { return }
            let selection: ActionSelection
            switch loaded {
            case .success(let s): selection = s
            case .failure(let error): return model.present(error)
            }
            let photoIDs = selection.photos.compactMap(\.id)
            guard !photoIDs.isEmpty else { return }
            let names = Dictionary(
                selection.photos.compactMap { p in p.id.map { ($0, p.stem) } }, uniquingKeysWith: { a, _ in a })
            let files = photoIDs.reduce(0) { $0 + (selection.versions[$1]?.count ?? 0) }
            let permanently = selection.photos.allSatisfy(Library.isDeleted)
            let alert = NSAlert()
            alert.messageText = deleteQuestion(photos: photoIDs.count, files: files, permanently: permanently)
            alert.informativeText = permanently
                ? "They're moved to the Trash and can't be recovered in Loupe."
                : "They stay in Recently Deleted for \(LibrarySettings.recentlyDeletedDays) days, then go to the Trash."
            alert.addButton(withTitle: permanently ? "Delete Permanently" : "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task { @MainActor in
                    let errors = permanently ? await library.deletePermanently(photoIDs) : await library.delete(photoIDs)
                    presentErrors(errors, "Couldn't delete", names: names, model: model)
                    completion(photoIDs.filter { errors[$0] == nil })
                }
            }
        }
    }

    static func deleteQuestion(photos: Int, files: Int, permanently: Bool) -> String {
        "Delete \(photos) photo\(photos == 1 ? "" : "s") (\(files) file\(files == 1 ? "" : "s"))"
            + (permanently ? " permanently?" : "?")
    }

    private struct GridError: LocalizedError {
        var errorDescription: String?
    }

    private func presentErrors(_ errors: [Int64: any Error], _ title: String) {
        var names: [Int64: String] = [:]
        for id in errors.keys {
            if let info = infos[id] { names[id] = info.displayFile.url.deletingPathExtension().lastPathComponent }
        }
        Self.presentErrors(errors, title, names: names, model: model)
    }

    /// One alert for per-photo errors, naming each photo (at most ten). Shared with the organising commands.
    static func presentErrors(_ errors: [Int64: any Error], _ title: String, names: [Int64: String], model: AppModel) {
        guard !errors.isEmpty else { return }
        let lines = errors.sorted { $0.key < $1.key }.prefix(10).map { id, error in
            "\(names[id] ?? "Photo \(id)"): \(error.localizedDescription)"
        }
        let more = errors.count > lines.count ? "\n…and \(errors.count - lines.count) more" : ""
        model.present(GridError(errorDescription: "\(title):\n" + lines.joined(separator: "\n") + more))
    }

    // MARK: - Actions (context menu, E)

    private func actionEntries() -> [[ActionMenuEntry]] {
        let ids = orderedSelection()
        guard !ids.isEmpty, let library,
            let selection = try? library.index.actionSelection(ids: ids, root: library.location.rootURL)
        else { return [] }
        return model.registry.actions.map { $0.entries(for: selection) }.filter { !$0.isEmpty }
    }

    func menu(for event: NSEvent) -> NSMenu? {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let path = collectionView.indexPathForItem(at: point), let id = dataSource.itemIdentifier(for: path)
        else { return nil }
        if !model.selection.contains(id) {
            collectionView.selectionIndexPaths = [path]
            focusID = id
            anchorID = id
            selectionDidChange()
        }
        let ids = orderedSelection()
        guard !ids.isEmpty, let library else { return nil }
        let selection = try? library.index.actionSelection(ids: ids, root: library.location.rootURL)
        let actions = selection.map { s in model.registry.actions.map { $0.entries(for: s) }.filter { !$0.isEmpty } } ?? []
        let byID = Dictionary((selection?.photos ?? []).compactMap { p in p.id.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        let files = ids.compactMap { id -> URL? in
            guard let selection, let versions = selection.versions[id] else { return nil }
            return (versions.first(where: \.isDisplay) ?? versions.first)?.url(in: selection.root)
        }
        return PhotoContextMenu.make(
            ids: ids, photos: ids.compactMap { byID[$0] }, files: files, actions: actions, model: model,
            run: { [weak self] in self?.run($0) }, trash: { [weak self] in self?.confirmTrash() })
    }

    private func performShortcut(_ key: Character) {
        guard let entry = actionEntries().joined().first(where: { $0.shortcut == key && $0.isEnabled }),
            let perform = entry.perform
        else { return }
        run(perform)
    }

    private func run(_ perform: @escaping @MainActor (any ActionContext) async throws -> Void) {
        let model = model
        Task { @MainActor in
            do { try await perform(model) } catch { model.present(error) }
        }
    }

    // MARK: - Zoom and layout

    private func zoom(by delta: Int) {
        let range = GridLayout.columnRange
        model.columns = min(range.upperBound, max(range.lowerBound, model.columns + delta))
    }

    func magnify(_ event: NSEvent) {
        if event.phase == .began { magnification = 0 }
        magnification += event.magnification
        if magnification > 0.2 {
            zoom(by: -1)
            magnification = 0
        } else if magnification < -0.2 {
            zoom(by: 1)
            magnification = 0
        }
    }

    /// Relayouts with `n` columns, keeping the first visible (preferably selected) photo where it was on screen.
    /// The change reads as a zoom around that photo (unless Reduce Motion is on): a picture of the old tiles scales
    /// and fades out while the new layout scales into place.
    private func applyColumns(_ n: Int) {
        let visible = collectionView.visibleItems().compactMap { collectionView.indexPath(for: $0) }
        let anchor = visible.filter(collectionView.selectionIndexPaths.contains).min() ?? visible.min()
        let anchorFrame = anchor.flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame }
        let clip = (view as! NSScrollView).contentView
        let offset = anchorFrame.map { $0.midY - clip.bounds.minY }
        let animates = anchorFrame != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let ghost = animates ? makeZoomGhost() : nil
        let oldSide = tileSide()
        columns = n
        collectionView.collectionViewLayout?.invalidateLayout()
        defer { DispatchQueue.main.async { [weak self] in self?.updateVisibleInfo() } }
        collectionView.layoutSubtreeIfNeeded()
        guard let anchor, let offset, let frame = collectionView.layoutAttributesForItem(at: anchor)?.frame else { return }
        collectionView.scroll(NSPoint(x: 0, y: max(0, frame.midY - offset)))
        collectionView.layoutSubtreeIfNeeded()
        if let ghost {
            zoom(ghost: ghost, by: oldSide / tileSide(), around: CGPoint(x: frame.midX - clip.bounds.minX, y: offset))
        }
    }

    private func tileSide() -> CGFloat {
        GridLayout.metrics(containerWidth: collectionView.bounds.width, columns: columns).side
    }

    private static let zoomDuration: CFTimeInterval = 0.25
    private static let zoomTiming = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
    private static let zoomKey = "loupe.zoom"
    private var zoomGhostView: NSView?

    /// A picture of the photos on screen as drawn now (part way through a zoom if one is running), laid over the
    /// grid in a view of its own; the layer to animate is returned.
    private func makeZoomGhost() -> CALayer {
        zoomGhostView?.removeFromSuperview()
        let scrollView = view as! NSScrollView
        let clip = scrollView.contentView
        let host = ZoomGhostView(frame: clip.frame)
        scrollView.addSubview(host, positioned: .above, relativeTo: clip)
        zoomGhostView = host

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ghost = CALayer()
        ghost.anchorPoint = .zero
        ghost.frame = host.bounds
        for case let cell as PhotoCell in collectionView.visibleItems() {
            guard let image = cell.shownImage, cell.view.bounds.width > 0 else { continue }
            let drawn = drawnFrame(of: cell.view).offsetBy(dx: -clip.bounds.minX, dy: -clip.bounds.minY)
            let scale = drawn.width / cell.view.bounds.width
            let photo = cell.photoFrame
            let tile = CALayer()
            tile.contents = image
            tile.contentsGravity = .resizeAspectFill
            tile.masksToBounds = true
            tile.cornerCurve = .continuous
            tile.cornerRadius = PhotoCellView.cornerRadius(for: photo) * scale
            tile.frame = CGRect(x: drawn.minX + photo.minX * scale, y: drawn.minY + photo.minY * scale,
                                width: photo.width * scale, height: photo.height * scale)
            ghost.addSublayer(tile)
        }
        host.layer?.addSublayer(ghost)
        CATransaction.commit()
        return ghost
    }

    /// `view`'s frame in the collection view as drawn now, part way through a zoom if it is zooming.
    private func drawnFrame(of view: NSView) -> CGRect {
        let frame = collectionView.convert(view.frame, from: view.superview)
        guard let layer = view.layer, layer.animation(forKey: Self.zoomKey) != nil,
            let t = layer.presentation()?.transform
        else { return frame }
        let s = t.m11
        let a = CGPoint(x: layer.anchorPoint.x * frame.width, y: layer.anchorPoint.y * frame.height)
        return CGRect(x: frame.minX + (1 - s) * a.x + t.m41, y: frame.minY + (1 - s) * a.y + t.m42,
                      width: frame.width * s, height: frame.height * s)
    }

    /// Scales the old tiles' picture by 1/`k` around `p` (on screen) as it fades, and every tile and header now on
    /// screen from `k` times its size around `p` to its place, so the anchor photo stays put.
    private func zoom(ghost: CALayer, by k: CGFloat, around p: CGPoint) {
        guard k > 0, k != 1 else {
            zoomGhostView?.removeFromSuperview()
            return
        }
        let host = zoomGhostView
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak host] in
            host?.removeFromSuperview()
            if self?.zoomGhostView === host { self?.zoomGhostView = nil }
        }
        let shrink = 1 / k
        let away = CABasicAnimation(keyPath: "transform")
        away.toValue = NSValue(caTransform3D: Self.scale(by: shrink, around: p))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [away, fade]
        group.duration = Self.zoomDuration
        group.timingFunction = Self.zoomTiming
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ghost.add(group, forKey: Self.zoomKey)

        let clip = (view as! NSScrollView).contentView.bounds
        let kind = NSCollectionView.elementKindSectionHeader
        let views = collectionView.visibleItems().map(\.view)
            + collectionView.visibleSupplementaryViews(ofKind: kind)
        for view in views {
            guard let layer = view.layer else { continue }
            // The layer's anchor point is its top left corner (AppKit), so `scale(by:around:)` applies as is
            // once `p` is in the layer's own coordinates.
            let origin = collectionView.convert(view.frame, from: view.superview).origin
            let local = CGPoint(x: p.x + clip.minX - origin.x - layer.anchorPoint.x * view.frame.width,
                                y: p.y + clip.minY - origin.y - layer.anchorPoint.y * view.frame.height)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: Self.scale(by: k, around: local))
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.duration = Self.zoomDuration
            grow.timingFunction = Self.zoomTiming
            layer.add(grow, forKey: Self.zoomKey)
        }
        CATransaction.commit()
    }

    /// Scaling by `s` that keeps `p` in place.
    private static func scale(by s: CGFloat, around p: CGPoint) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeTranslation(p.x * (1 - s), p.y * (1 - s), 0), s, s, 1)
    }

    private func makeLayout() -> NSCollectionViewLayout {
        let configuration = NSCollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .vertical
        return NSCollectionViewCompositionalLayout(sectionProvider: { [weak self] index, environment in
            guard let self else { return nil }
            let columns = self.columns
            let (side, spacing) = GridLayout.metrics(
                containerWidth: environment.container.effectiveContentSize.width, columns: columns)
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                subitem: item, count: columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: spacing, leading: spacing, bottom: spacing, trailing: spacing)
            // Date groupings have titles; All Photos has one untitled section and no header.
            if let title = self.section(at: index)?.title, !title.isEmpty {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1), heightDimension: .absolute(GridLayout.headerHeight)),
                    elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
                header.pinToVisibleBounds = true
                header.zIndex = 2
                section.boundarySupplementaryItems = [header]
            }
            return section
        }, configuration: configuration)
    }

    // MARK: - Prefetching and drag out

    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let loader else { return }
        for path in indexPaths {
            if let id = dataSource.itemIdentifier(for: path), let info = infos[id] {
                loader.prefetch(info.displayFile, kind: info.displayKind, rotation: info.rotation)
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        guard let loader else { return }
        for path in indexPaths {
            if let id = dataSource.itemIdentifier(for: path), let info = infos[id] {
                loader.cancelPrefetch(info.displayFile, rotation: info.rotation)
            }
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent
    ) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let info = infos[id] else { return nil }
        let item = NSPasteboardItem()
        item.setString(info.displayFile.url.absoluteString, forType: .fileURL)
        item.setString(String(id), forType: Self.photoIDsType)
        return item
    }
}

/// Holds the picture of the old tiles while the grid zooms; flipped like the collection view, and click-through.
private final class ZoomGhostView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Routes keys, double-clicks, pinches and context menus to the controller.
final class GridCollectionView: NSCollectionView {
    weak var grid: PhotoGridController?

    override func keyDown(with event: NSEvent) {
        if grid?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, grid?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { grid?.doubleClicked(event) }
    }

    override func magnify(with event: NSEvent) {
        grid?.magnify(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        grid?.menu(for: event)
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        grid?.selectionDidChange()
    }
}
