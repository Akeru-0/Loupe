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

    public var selectedItemID: String? = "library" { didSet { selectedItemChanged() } }
    public var query = PhotoQuery() { didSet { if query != oldValue { observeQuery() } } }
    public var selection: Set<Int64> = [] { didSet { if selection != oldValue { reloadActionBar() } } }
    /// The photo the viewer shows. Close the viewer with `closeViewer()`; setting nil directly is a reset.
    public var viewerPhotoID: Int64? {
        didSet {
            closedViewerPhotoID = nil
            if viewerPhotoID != oldValue { reloadActionBar() }
        }
    }
    /// The version the viewer focuses (set by the viewer); Share in the toolbar shares it.
    var viewerFocusedVersion: VersionRecord?
    public var mode: BrowseMode = .all {
        didSet {
            query.grouping = mode.grouping
            columns = GridLayout.defaultColumns(for: mode)
        }
    }
    public var columns = 7
    public var showsActivityLog = false
    public var alertMessage: String?
    /// The photos the tag editor (⌘T) is open for.
    public var tagEditorPhotoIDs: [Int64]?
    /// Favorite and display kind of photos the action bar targeted, as last loaded (`reloadActionBar()`).
    var actionFlags: [Int64: ActionFlags] = [:]

    public private(set) var sidebar: [SidebarGroup] = []
    public private(set) var photoSections: [PhotoSection] = []
    public private(set) var cameras: [String] = []
    public private(set) var lenses: [String] = []
    public private(set) var isScanning = false
    public private(set) var log: [LogEntry] = []
    /// Mounted camera cards, shown under Devices.
    public private(set) var cards: [Card] = []
    /// The import window of the selected card (it replaces the grid).
    private(set) var importModel: ImportModel?
    /// An import that keeps running after another sidebar item was selected.
    private(set) var backgroundImport: ImportModel?

    /// The grid's thumbnail memory cache, so the viewer can show a thumbnail instantly.
    @ObservationIgnored var thumbnailLoader: ThumbnailLoader?
    @ObservationIgnored private let preferences: any PreferenceStore
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private let cacheDirectory: URL
    /// Bumped whenever the library is replaced; late results for an older library are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarRefreshPending = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Set by `closeViewer()`, taken once by the grid; any other change of `viewerPhotoID` clears it.
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
    }

    /// The settings the library runs with.
    public var effectiveSettings: LibrarySettings {
        var s = settings
        if let rootOverride { s.rootPath = rootOverride }
        return s
    }

    public var photoCount: Int { photoSections.reduce(0) { $0 + $1.photoIDs.count } }

    public var scanStatus: String {
        let n = photoCount
        return isScanning ? "Scanning… \(n.formatted())" : (n == 1 ? "1 photo" : "\(n.formatted()) photos")
    }

    public var selectedTitle: String {
        selectedItemID.flatMap(item(withID:))?.title ?? "Loupe"
    }

    // MARK: - Launch and library lifetime

    /// Call once at app launch.
    public func launch() {
        SharePreferences.clearOutputDirectory()
        for dir in [supportDirectory, cacheDirectory, ScriptsFeature.scriptsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Library.didLog, object: nil, queue: .main) { [weak self] note in
            let message = note.userInfo?["message"] as? String ?? "\(note)"
            MainActor.assumeIsolated { self?.log(message) }
        })
        for name in [Library.didChange, Library.albumsDidChange] {
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
        library = nil
        photoSections = []
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
        viewerPhotoID = nil
        closedViewerPhotoID = id
    }

    /// The photo the viewer closed on, once.
    func takeClosedViewerPhoto() -> Int64? {
        defer { closedViewerPhotoID = nil }
        return closedViewerPhotoID
    }

    private func selectedItemChanged() {
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
        query.scope = item.scope
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
                    if card(forItemID: id) == nil, query.scope != item.scope { query.scope = item.scope }
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

    /// The sidebar as shown: the sections, with Devices (only while there are cards) after the top section.
    var sidebarGroups: [SidebarGroup] {
        let devices = deviceCards.map {
            SidebarItem(id: Self.deviceItemID($0), title: $0.name, systemImage: "sdcard", scope: .all)
        }
        guard !devices.isEmpty else { return sidebar }
        var groups = sidebar
        let at = groups.first?.title == nil ? 1 : 0
        groups.insert(SidebarGroup(id: "devices", title: "Devices", items: devices), at: min(at, groups.count))
        return groups
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
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.cardsChanged(cards) } }
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
        if let id = selectedItemID, id.hasPrefix("device:"), card(forItemID: id) == nil { selectedItemID = "library" }
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

    /// Shows the album an import went into (`""`: Unsorted).
    func showImported(folder: String) {
        selectedItemID = folder.isEmpty ? "unsorted" : "folder:" + folder.precomposedStringWithCanonicalMapping
    }

    /// Ejects the card off the main thread (it waits for the disk); errors are presented.
    func eject(_ card: Card) {
        let url = card.volumeURL
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            }.value
            if case .failure(let error) = result {
                present(ImportUIError("Couldn't eject “\(card.name)”: \(error.localizedDescription)"))
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
