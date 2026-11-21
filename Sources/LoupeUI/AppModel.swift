import AppKit
import Foundation
import LoupeCore
import LoupeFeatures
import LoupeImport
import LoupeIndex
import Observation
import UniformTypeIdentifiers

public enum BrowseMode: CaseIterable, Hashable {
    case years, months, days, all

    var title: String {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .days: "Days"
        case .all: "All Photos"
        }
    }

    var grouping: PhotoQuery.Grouping {
        switch self {
        case .years: .year
        case .months: .month
        case .days: .day
        case .all: .none
        }
    }
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let message: String
}

/// One sidebar section with its items, as shown.
public struct SidebarGroup: Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let items: [SidebarItem]
}

/// App state: the open library, the sidebar, the current query and its results, settings and the activity log.
/// Disk and database work runs off the main actor; this class only publishes results.
@MainActor @Observable public final class AppModel: ActionContext {
    public nonisolated static let defaultSupportDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Loupe", isDirectory: true)
    public nonisolated static let defaultCacheDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Loupe", isDirectory: true)
    static let settingsKey = "library.settings"

    public private(set) var library: Library?
    public let registry: FeatureRegistry
    /// As persisted. The `-LoupeRoot` launch argument (`rootOverride`) wins over `settings.rootPath`.
    public private(set) var settings: LibrarySettings
    public let rootOverride: String?

    public var selectedItemID: String? = "library" {
        didSet {
            if !isGoingBack, let oldValue, oldValue != selectedItemID { backStack.append(oldValue) }
            if selectedItemID != restoringSession?.item { restoringSession = nil }  // the user moved on
            if selectedItemID != oldValue {
                unlockDeclined = false  // opening a locked view asks again
                openedFaceGroup = nil  // a person opened from People closes with it
            }
            selectedItemChanged()
            saveSession()
        }
    }
    /// Sidebar items shown before the current one, most recent last, for the toolbar's back button.
    private var backStack: [String] = []
    private var isGoingBack = false
    public var query = PhotoQuery() { didSet { if query != oldValue { observeQuery() } } }
    public var selection: Set<Int64> = [] { didSet { if selection != oldValue { reloadActionBar() } } }
    /// The photo the viewer shows. Close the viewer with `closeViewer()`; setting nil directly is a reset.
    public var viewerPhotoID: Int64? {
        didSet {
            closedViewerPhotoID = nil
            if viewerPhotoID != oldValue {
                reloadActionBar()
                saveSession()
            }
        }
    }
    /// The tile the viewer opens from, set by the grid just before it opens the viewer and taken by the viewer.
    @ObservationIgnored var viewerOpening: ViewerFlight?
    /// The photo flying back to its tile after the viewer closed itself (`ViewerLanding`).
    var viewerClosing: ViewerFlight?
    /// The open viewer's photo as drawn, for that flight back (set by the viewer while it is shown).
    @ObservationIgnored var viewerSnapshot: (@MainActor () -> ViewerFlight?)?
    /// The version the viewer focuses (set by the viewer); Share in the toolbar shares it.
    var viewerFocusedVersion: VersionRecord?
    /// The record of the photo the viewer shows (set by the viewer), for the title bar's date heading.
    var viewerPhoto: PhotoRecord?
    /// Settings ▸ Import ▸ Import from Apple Photos, and Settings ▸ Faces' downloadable recognition model.
    @ObservationIgnored private(set) lazy var applePhotosImport = ApplePhotosImport(supportDirectory: supportDirectory)
    @ObservationIgnored private(set) lazy var faceModel = FaceRecognitionModel(supportDirectory: supportDirectory)
    /// Updates for the installed app (set by the app target; nil in development builds).
    @ObservationIgnored public var updater: (any AppUpdater)?
    /// Face recognition (FaceScanning.swift).
    var faceScanStatus: FaceScanStatus = .unavailable
    /// The people and pets People shows, and the one opened from it (its photos are shown).
    var faceGroups: [LibraryIndex.FaceGroup] = []
    var openedFaceGroup: Int64?
    var runtimeInstall: RuntimeInstall = .idle
    @ObservationIgnored var faceScanTask: Task<Void, Never>?
    @ObservationIgnored var faceScanPending = false
    /// Cloud upload (CloudUpload.swift): the synced folder per library root, and what the upload is doing.
    var uploadFoldersByRoot: [String: String] = [:]
    var uploadStatus: CloudUploadStatus = .off
    @ObservationIgnored var uploadTask: Task<Void, Never>?
    @ObservationIgnored var uploadPending = false
    /// The Favorites folder's sync (FavoritesFolderSync.swift).
    @ObservationIgnored var favoritesTask: Task<Void, Never>?
    @ObservationIgnored var favoritesPending = false
    @ObservationIgnored var favoritesWatcher: FolderWatcher?
    /// Hidden and Recently Deleted were unlocked (LockedAlbums.swift), until `unlockDuration` has passed.
    var isUnlocked = false { didSet { if isUnlocked != oldValue { unlockChanged() } } }
    /// How long an unlock lasts (tests shorten it).
    @ObservationIgnored var unlockDuration: Duration = .seconds(15 * 60)
    /// When the current unlock ends, for the padlock's help.
    var unlockExpiry: Date?
    @ObservationIgnored var relockTask: Task<Void, Never>?
    /// The unlock prompt was cancelled (or the user locked by hand): don't ask again by itself until another item.
    @ObservationIgnored var unlockDeclined = false
    @ObservationIgnored var isAuthenticating = false
    /// The toolbar's Info popover is open (the grid's Get Info opens it too).
    var showsInfo = false
    /// A photo the grid selects and scrolls to once it shows it (Show in Library / Show in Album), then clears.
    var pendingRevealID: Int64?
    /// The months of the dated photos on screen in the grid (first and last, each the start of its month); nil when
    /// none are. Set by the grid as it scrolls and zooms.
    var visibleMonths: ClosedRange<Date>?
    public var mode: BrowseMode = .all {
        didSet {
            query.grouping = mode.grouping
            columns = GridLayout.defaultColumns(for: mode)
        }
    }
    public var columns = 7 { didSet { if columns != oldValue { saveSession() } } }
    /// What was on screen when the app last ran, until the restored view's photos are in (SessionRestore.swift).
    @ObservationIgnored var restoringSession: Session?
    /// The photo at the top of the grid, as the grid last reported it.
    @ObservationIgnored var topPhotoID: Int64?
    /// After launch: the photo the grid scrolls to the top once it shows it, then clears.
    var pendingTopPhotoID: Int64?
    public var showsActivityLog = false
    public var alertMessage: String?
    /// The photos the tag editor (⌘T) is open for.
    public var tagEditorPhotoIDs: [Int64]?
    /// The smart album sheet's album, while it's open.
    var smartAlbumEditing: SmartAlbumEditing?
    /// Favorite and display kind of photos the action bar targeted, as last loaded (`reloadActionBar()`).
    var actionFlags: [Int64: ActionFlags] = [:]
    /// The running slideshow (Play), in its own window over the screen.
    private(set) var slideshow: SlideshowController?

    public private(set) var sidebar: [SidebarGroup] = []
    /// Pinned sidebar item ids per library root, and the sections' order by id (see SidebarArrangement.swift).
    var pinnedByRoot: [String: [String]] = [:]
    var sectionOrder: [String] = []
    /// Per library root: the dragged order of the items under each section or album group (by its id), and the
    /// icons chosen for albums (by item id).
    var itemOrderByRoot: [String: [String: [String]]] = [:]
    var iconsByRoot: [String: [String: String]] = [:]
    /// The sidebar row (by its id) showing the icon picker.
    var iconPickerItemID: String?
    /// The section header being dragged in the sidebar, while it is.
    @ObservationIgnored var draggedSectionID: String?
    public private(set) var photoSections: [PhotoSection] = []
    public private(set) var cameras: [String] = []
    public private(set) var lenses: [String] = []
    public private(set) var isScanning = false
    public private(set) var log: [LogEntry] = []
    /// Mounted camera cards, shown under Devices.
    public private(set) var cards: [Card] = []
    /// Ejectable drives that aren't camera cards, listed under Devices to eject (Devices.swift).
    public private(set) var drives: [ExternalDrive] = []
    /// The import window of the selected card (it replaces the grid).
    private(set) var importModel: ImportModel?
    /// An import that keeps running after another sidebar item was selected.
    private(set) var backgroundImport: ImportModel?

    /// The grid's thumbnail memory cache, so the viewer can show a thumbnail instantly.
    @ObservationIgnored var thumbnailLoader: ThumbnailLoader?
    @ObservationIgnored let preferences: any PreferenceStore
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private let cacheDirectory: URL
    /// Bumped whenever the library is replaced; late results for an older library are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarRefreshPending = false
    @ObservationIgnored var observers: [any NSObjectProtocol] = []
    /// Set by `closeViewer()` (and the slideshow ending), taken once by the grid; any other change of `viewerPhotoID`
    /// clears it.
    @ObservationIgnored private var closedViewerPhotoID: Int64?
    @ObservationIgnored private var cardDetector: CardDetector?
    @ObservationIgnored var actionBarTask: Task<Void, Never>?

    public init(
        preferences: any PreferenceStore = UserDefaultsStore.standard,
        rootOverride: String? = UserDefaults.standard.string(forKey: "LoupeRoot"),
        supportDirectory: URL = AppModel.defaultSupportDirectory,
        cacheDirectory: URL = AppModel.defaultCacheDirectory
    ) {
        var registry = FeatureRegistry()
        for feature in BuiltInFeatures.all { feature.register(in: &registry) }
        self.registry = registry
        self.preferences = preferences
        self.rootOverride = rootOverride
        self.supportDirectory = supportDirectory
        self.cacheDirectory = cacheDirectory
        settings = Self.loadSettings(from: preferences)
        loadSidebarArrangement()
        loadUploadFolders()
        restoreSession()
    }

    /// The settings the library runs with.
    public var effectiveSettings: LibrarySettings {
        var s = settings
        if let rootOverride { s.rootPath = rootOverride }
        return s
    }

    public var photoCount: Int { photoSections.reduce(0) { $0 + $1.photoIDs.count } }

    /// The viewer's photo's place in the current list, 1-based ("241 of 251"); nil when it isn't in it.
    var viewerPosition: Int? {
        guard let id = viewerPhotoID else { return nil }
        var offset = 0
        for section in photoSections {
            if let i = section.photoIDs.firstIndex(of: id) { return offset + i + 1 }
            offset += section.photoIDs.count
        }
        return nil
    }

    public var scanStatus: String {
        let n = photoCount
        return isScanning ? "Scanning… \(n.formatted())" : (n == 1 ? "1 photo" : "\(n.formatted()) photos")
    }

    public var selectedTitle: String {
        if let opened = openedFaceGroup, let group = faceGroups.first(where: { $0.id == opened }) {
            return faceGroupTitle(group)  // a person opened from People
        }
        return selectedItemID.flatMap(item(withID:))?.title ?? "Loupe"
    }

    // MARK: - Launch and library lifetime

    /// Call once at app launch.
    public func launch() {
        SharePreferences.clearOutputDirectory()
        for dir in [supportDirectory, cacheDirectory, ScriptsFeature.scriptsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let center = NotificationCenter.default
        lockWhenScreenLocks()
        observers.append(center.addObserver(forName: Library.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleUpload()  // new and changed files go up
                self?.scheduleFaceScan()  // and are scanned for faces
                self?.scheduleFavoritesSync()  // favorites changed, or their files
            }
        })
        observers.append(center.addObserver(forName: Library.didLog, object: nil, queue: .main) { [weak self] note in
            let message = note.userInfo?["message"] as? String ?? "\(note)"
            MainActor.assumeIsolated { self?.log(message) }
        })
        // Duplicates: the sidebar shows the number of sets.
        for name in [Library.didChange, Library.albumsDidChange, Library.duplicatesDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSidebar() }
            })
        }
        // Favorites, rotation or versions of the targets may have changed.
        observers.append(center.addObserver(forName: Library.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadActionBar() }
        })
        startCardDetection()
        openLibrary()
    }

    /// Persists `new`; a different root, edit markers or exclusions replace the library (the old one is stopped).
    public func updateSettings(_ new: LibrarySettings) {
        guard new != settings else { return }
        let before = effectiveSettings
        settings = new
        if let data = try? JSONEncoder().encode(new) {
            preferences.set(String(decoding: data, as: UTF8.self), forKey: Self.settingsKey)
        }
        let after = effectiveSettings
        if before.rootPath != after.rootPath || before.editMarkers != after.editMarkers
            || before.excludedFolderNames != after.excludedFolderNames
        {
            openLibrary()
        } else {
            refreshSidebar()
        }
    }

    static func loadSettings(from preferences: any PreferenceStore) -> LibrarySettings {
        guard let json = preferences.string(forKey: settingsKey),
            let settings = try? JSONDecoder().decode(LibrarySettings.self, from: Data(json.utf8))
        else { return .standard() }
        return settings
    }

    /// Stops the current library (if any), opens one for `effectiveSettings` and scans it in the background.
    private func openLibrary() {
        generation += 1
        let gen = generation
        let old = library
        let oldOpen = openTask
        oldOpen?.cancel()
        queryTask?.cancel()
        cancelUpload()
        cancelFaceScan()
        stopFavoritesSync()
        library = nil
        photoSections = []
        slideshow?.end(handoff: false)
        viewerPhotoID = nil
        reloadActionBar()  // drops the old library's records
        isScanning = true
        leaveImport()  // its engine belongs to the old library

        let settings = effectiveSettings
        let registry = registry
        let support = supportDirectory, cache = cacheDirectory
        openTask = Task { [weak self] in
            await old?.stop()
            // The cancelled open or scan winds down before the new library touches the index (it may be the same file).
            await oldOpen?.value
            if let old { self?.log("Closed \(old.location.rootURL.path)") }
            let opened = await Task.detached(priority: .userInitiated) {
                Result {
                    try Library(
                        location: LocalFolderLocation(rootURL: URL(fileURLWithPath: settings.rootPath, isDirectory: true)),
                        settings: settings, registry: registry, supportDirectory: support, cacheDirectory: cache)
                }
            }.value
            guard let self, gen == self.generation, !Task.isCancelled else {
                if case .success(let lib) = opened { await lib.stop() }
                return
            }
            let lib: Library
            switch opened {
            case .success(let l): lib = l
            case .failure(let error):
                isScanning = false
                present(error)
                return
            }
            library = lib
            reloadActionBar()
            log("Opened \(settings.rootPath)")
            observeQuery()
            refreshSidebar()
            if let id = selectedItemID, let card = card(forItemID: id) { showImport(for: card) }
            let started = Date()
            let report = await lib.start()
            guard gen == generation else { return }
            isScanning = false
            scheduleUpload()
            scheduleFaceScan()
            watchFavoritesFolder()
            scheduleFavoritesSync()
            refreshFaceGroups()
            log(String(
                format: "Scan finished in %.1f s: %d added, %d updated, %d removed, %d unreadable",
                Date().timeIntervalSince(started), report.added, report.updated, report.removed, report.failed.count))
        }
    }

    // MARK: - Query

    private func observeQuery() {
        queryTask?.cancel()
        guard let library else { return }
        let stream = library.index.observeSections(for: query)
        queryTask = Task { [weak self] in
            do {
                for try await sections in stream {
                    guard !Task.isCancelled else { return }
                    self?.photoSections = sections
                    self?.finishRestoringSession()
                }
            } catch {
                if !Task.isCancelled { self?.log("Could not load photos: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Viewer

    /// The viewer closing itself (Esc, Space, the close button): the grid then selects the photo it showed, scrolls
    /// it into view and takes the keyboard back. Resets (another sidebar item, a reopened library) don't do that.
    func closeViewer() {
        guard let id = viewerPhotoID else { return }
        viewerClosing = viewerSnapshot?()
        viewerPhotoID = nil
        closedViewerPhotoID = id
    }

    /// The tile the viewer opens on `id` from, once.
    func takeViewerOpening(for id: Int64?) -> ViewerFlight? {
        defer { viewerOpening = nil }
        return viewerOpening?.photoID == id ? viewerOpening : nil
    }

    /// Play: a full-screen slideshow of the targets if two or more are selected, otherwise of the whole query,
    /// starting at the selected or viewed photo (`SlideshowModel`).
    func startSlideshow() {
        guard slideshow == nil, actionBarState.canPlay, let library,
            let show = SlideshowModel(targets: actionTargetIDs, order: photoSections.flatMap(\.photoIDs))
        else { return }
        let controller = SlideshowController(app: self, library: library, show: show)
        slideshow = controller
        controller.start(over: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    /// The slideshow ended on `id` (nil: it was reset, e.g. the library was replaced). An open viewer shows that
    /// photo; otherwise the grid selects it and scrolls it into view, as when the viewer closes on it.
    func slideshowEnded(on id: Int64?) {
        slideshow = nil
        guard let id else { return }
        if viewerPhotoID != nil {
            viewerPhotoID = id
        } else {
            closedViewerPhotoID = id  // the grid takes it when it sees `slideshow` change
        }
    }

    /// The photo the viewer closed on, once.
    func takeClosedViewerPhoto() -> Int64? {
        defer { closedViewerPhotoID = nil }
        return closedViewerPhotoID
    }

    /// Shows the sidebar item `itemID` with the photo selected and scrolled into view.
    func reveal(_ id: Int64, in itemID: String) {
        pendingRevealID = id
        if selectedItemID != itemID { selectedItemID = itemID }
    }

    /// The toolbar's back button: closes the viewer, or else returns to the previous sidebar item that still exists.
    var canGoBack: Bool { viewerPhotoID != nil || openedFaceGroup != nil || !backStack.isEmpty }

    /// Shows `id` without recording the current item for Back (restoring the last session).
    func select(withoutHistory id: String) {
        isGoingBack = true
        selectedItemID = id
        isGoingBack = false
    }

    func goBack() {
        if viewerPhotoID != nil { return closeViewer() }
        if openedFaceGroup != nil { return closeFaceGroup() }  // a person: back to People
        while let id = backStack.popLast() {
            guard item(withID: id) != nil || card(forItemID: id) != nil else { continue }
            isGoingBack = true
            selectedItemID = id
            isGoingBack = false
            return
        }
    }

    private func selectedItemChanged() {
        if let id = selectedItemID, drive(forItemID: id) != nil {  // nothing to browse: the drive's own view
            selection = []
            viewerPhotoID = nil
            leaveImport()
            return
        }
        if let id = selectedItemID, let card = card(forItemID: id) {
            selection = []
            viewerPhotoID = nil
            showImport(for: card)
            return
        }
        leaveImport()
        guard let id = selectedItemID, let item = item(withID: id) else { return }
        selection = []
        viewerPhotoID = nil
        query.select(item.scope)
        if item.scope == .people { refreshFaceGroups() }
    }

    // MARK: - Sidebar

    /// Rebuilds the sidebar (and the filter menus' cameras and lenses) off the main actor; coalesces bursts.
    func refreshSidebar() {
        guard let library else { return }
        if sidebarTask != nil {
            sidebarRefreshPending = true
            return
        }
        let sections = registry.sidebarSections.sorted { $0.order < $1.order }
        let index = library.index, root = library.location.rootURL, settings = effectiveSettings
        let gen = generation
        sidebarTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var groups: [SidebarGroup] = []
                var errors: [String] = []
                for section in sections {
                    do {
                        let items = try section.items(index: index, root: root, settings: settings)
                        groups.append(SidebarGroup(id: section.id, title: section.title, items: items))
                    } catch {
                        errors.append("Sidebar \(section.title ?? section.id): \(error.localizedDescription)")
                    }
                }
                return (groups, (try? index.cameras()) ?? [], (try? index.lenses()) ?? [], errors)
            }.value
            guard let self else { return }
            sidebarTask = nil
            if gen == generation {
                (sidebar, cameras, lenses) = (result.0, result.1, result.2)
                for message in result.3 { log(message) }
                if let id = selectedItemID, let item = item(withID: id) {
                    // A renamed or new album selected before it was listed, or an album that became a group.
                    // (A person opened from People keeps their own view.)
                    if card(forItemID: id) == nil, openedFaceGroup == nil, query.scope != item.scope {
                        query.scope = item.scope
                    }
                } else if selectedItemID != nil, !sidebarRefreshPending {
                    selectedItemID = "library"
                }
            }
            if sidebarRefreshPending {
                sidebarRefreshPending = false
                refreshSidebar()
            }
        }
    }

    func item(withID id: String) -> SidebarItem? {
        func find(_ items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.id == id { return item }
                if let found = find(item.children) { return found }
            }
            return nil
        }
        return find(sidebarGroups.flatMap(\.items))
    }

    /// The sidebar as shown: the sections, with Devices (only while there are cards) after the top section and Pinned
    /// (once something is pinned) right above Media Types; sections and items in the order the user dragged them
    /// into, albums with the icons chosen for them.
    var sidebarGroups: [SidebarGroup] {
        let devices = deviceCards.map {
            SidebarItem(id: Self.deviceItemID($0), title: $0.name, systemImage: "sdcard", scope: .all)
        } + drives.map {
            SidebarItem(id: Self.driveItemID($0), title: $0.name, systemImage: "externaldrive", scope: .all)
        }
        var groups = sidebar
        if !devices.isEmpty {
            let at = groups.first?.title == nil ? 1 : 0
            groups.insert(SidebarGroup(id: "devices", title: "Devices", items: devices), at: min(at, groups.count))
        }
        groups = customized(groups)
        if let pinned = pinnedGroup(from: groups) {
            let at = groups.firstIndex { $0.id == "mediaTypes" } ?? min(1, groups.count)
            groups.insert(pinned, at: at)
        }
        return Self.arranged(groups, order: sectionOrder)
    }

    // MARK: - Import

    /// Watches for camera cards. Workspace notifications arrive on the main thread, so the listing of `/Volumes`
    /// runs on a background queue and only the result is published here, in order.
    private func startCardDetection() {
        let queue = OperationQueue()
        queue.name = "Loupe card detection"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let publish: @Sendable ([Card]) -> Void = { [weak self] cards in
            let drives = ExternalDrives.current(excluding: cards)  // here, off the main thread
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.drives = drives
                    self?.cardsChanged(cards)
                }
            }
        }
        let detector = CardDetector(queue: queue, onChange: publish)
        detector.start()
        queue.addOperation { publish(detector.currentCards()) }
        cardDetector = detector
    }

    private func cardsChanged(_ new: [Card]) {
        cards = new
        // The shown card went away: leave its window, unless an import from it is still running (it ends with
        // errors for the missing files, and its summary is shown then).
        if let shown = importModel, !new.contains(shown.card), !shown.phase.isImporting { leaveImport() }
        selectLibraryIfDeviceGone()
    }

    private func selectLibraryIfDeviceGone() {
        if let id = selectedItemID, id.hasPrefix("device:") || id.hasPrefix("drive:"),
            card(forItemID: id) == nil, drive(forItemID: id) == nil
        {
            selectedItemID = "library"
        }
    }

    /// The cards under Devices: the mounted ones, plus the shown one while it is still importing after removal.
    var deviceCards: [Card] {
        guard let shown = importModel, shown.phase.isImporting, !cards.contains(shown.card) else { return cards }
        return cards + [shown.card]
    }

    /// True while any import runs; every Import button is disabled then.
    var isImporting: Bool {
        importModel?.phase.isImporting == true || backgroundImport?.phase.isImporting == true
    }

    static func deviceItemID(_ card: Card) -> String { "device:" + card.volumeURL.path }

    func card(forItemID id: String) -> Card? {
        guard id.hasPrefix("device:") else { return nil }
        return deviceCards.first { Self.deviceItemID($0) == id }
    }

    /// Shows the import window for `card`: the running import from it if there is one, else a fresh listing.
    private func showImport(for card: Card) {
        if importModel?.card == card { return }
        leaveImport()
        if let running = backgroundImport, running.card == card {
            backgroundImport = nil
            importModel = running
            return
        }
        guard let library else { return }  // opening; shown once it is open
        // Before the sidebar's first load nothing is known, so a remembered album is kept.
        let albums = sidebar.isEmpty ? nil : Set(Self.albumPaths(sidebar.first { $0.id == "albums" }?.items ?? []))
        let model = ImportModel(
            card: card, engine: .live(library), preferences: preferences, albums: albums,
            thumbnails: ThumbnailLoader(thumbnails: library.thumbnails),
            onError: { [weak self] error in self?.present(error) })
        model.onImportFinished = { [weak self] model in self?.importFinished(model) }
        importModel = model
        model.load()
    }

    /// Hides the import window. A running import goes on in the background; listing and checking stop.
    private func leaveImport() {
        guard let shown = importModel else { return }
        importModel = nil
        if shown.phase.isImporting {
            backgroundImport = shown
        } else {
            shown.stopLoading()
        }
    }

    private func importFinished(_ model: ImportModel) {
        guard case .done(let result) = model.phase else { return }
        let summary = "Import from “\(model.card.name)”: \(ImportModel.summary(of: result))"
        log(summary)
        let failures = ImportModel.failures(of: result)
        for line in failures { log(line) }
        let cardGone = !cards.contains(model.card)
        let shown = model === importModel
        if model === backgroundImport { backgroundImport = nil }
        // Nobody sees the window's summary: say what went wrong here.
        if (!shown || cardGone), !failures.isEmpty || !result.skipped.isEmpty {
            present(ImportUIError(([summary] + failures.prefix(10)).joined(separator: "\n")))
        }
        if shown, cardGone {
            leaveImport()
            selectLibraryIfDeviceGone()
        }
    }

    /// Shows the album an import went into; Library for the Photos folder and the top of the library (no album).
    func showImported(folder: String) {
        selectedItemID = folder.isEmpty || folder == LibrarySettings.photosFolderName ? "library"
            : "folder:" + folder.precomposedStringWithCanonicalMapping
    }

    /// Ejects the card off the main thread (it waits for the disk); errors are presented.
    func eject(_ card: Card) { eject(volumeURL: card.volumeURL, name: card.name) }

    /// Unmounts and ejects the volume off the main thread, so it's safe to unplug; errors (a file still open
    /// elsewhere) are presented. Devices drops it when the unmount is noticed.
    func eject(volumeURL url: URL, name: String) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            }.value
            if case .failure(let error) = result {
                present(ImportUIError("Couldn't eject “\(name)”: \(error.localizedDescription)"))
            } else {
                log("Ejected \(name)")
            }
        }
    }

    private static func albumPaths(_ items: [SidebarItem]) -> [String] {
        items.flatMap { item -> [String] in
            let mine = item.isAlbum ? item.albumFolder.map { [$0] } ?? [] : []
            return mine + albumPaths(item.children)
        }
    }

    // MARK: - ActionContext

    public func share(_ urls: [URL]) {
        guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        NSSharingServicePicker(items: urls).show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    public func log(_ message: String) {
        log.append(LogEntry(date: Date(), message: message))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    public func present(_ error: any Error) {
        log(error.localizedDescription)
        alertMessage = error.localizedDescription
    }

    public func chooseApplication() async -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an app to edit photos with."
        panel.prompt = "Choose"
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}
