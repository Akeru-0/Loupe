import Foundation
import LoupeCore
import LoupeFeatures
import LoupeImport
import LoupeIndex
import Observation

/// Where an import goes.
enum ImportDestination: Hashable, Codable, Sendable {
    /// The Photos folder at the top of the library, created by the first import into it. The default.
    case photos
    /// The library root.
    case unsorted
    /// An existing album, root-relative.
    case album(String)
    /// A new album folder, inside a group (root-relative, `nil` or empty for the top level).
    case newAlbum(name: String, inGroup: String?)

    /// The root-relative folder the import goes to (missing folders are created by the importer).
    var folder: String {
        switch self {
        case .photos: return Self.photosFolder
        case .unsorted: return ""
        case .album(let path): return path
        case .newAlbum(let name, let group):
            let parts = (group ?? "").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            return (parts.filter { !$0.isEmpty } + [name.trimmingCharacters(in: .whitespaces)]).joined(separator: "/")
        }
    }

    static let photosFolder = LibrarySettings.photosFolderName

    /// New Album's group: the current year, e.g. `2026` → `2026/<name>`.
    static func defaultGroup(for date: Date = Date()) -> String {
        String(Calendar.current.component(.year, from: date))
    }

    /// A folder name the library accepts: not empty, not hidden, no `/` or `:`.
    static func isValidName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && !name.contains("/")
            && !name.contains(":")
    }
}

/// The import engine operations the import window uses; tests inject fakes. All of them do disk I/O and are only
/// ever called off the main actor.
struct ImportEngine: Sendable {
    var list: @Sendable (Card) throws -> [PhotoGroup]
    var check: @Sendable ([PhotoGroup], @escaping @Sendable (Int, Int) -> Void) async throws -> DuplicateReport
    var run: @Sendable (ImportPlan, @escaping @Sendable (ImportProgress) -> Void) async throws -> ImportResult
    /// Returns once the library's initial scan has finished: until then its index does not know every file.
    var waitForLibrary: @Sendable () async -> Void = {}

    /// The real engine for `library`. Duplicates are looked for in the library and, if there is one, in
    /// `<root>/Photos Library.photoslibrary`, once the library's initial scan has indexed it.
    static func live(_ library: Library) -> ImportEngine {
        let root = library.location.rootURL, index = library.index, markers = library.settings.editMarkers
        return ImportEngine(
            list: { try CardListing.groups(on: $0, editMarkers: markers) },
            check: { groups, progress in
                await library.waitUntilStarted()
                let photos = root.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
                let finder = DuplicateFinder(
                    index: index, root: root,
                    photosLibrary: FileManager.default.fileExists(atPath: photos.path) ? photos : nil)
                return try await finder.present(groups, progress: progress)
            },
            run: { plan, progress in try await library.importFiles(plan, progress: progress) },
            waitForLibrary: { await library.waitUntilStarted() })
    }
}

extension PhotoGroup {
    /// Identifies a card group in the import window's selection.
    var importID: String { folder.path + "/" + stemKey }
}

/// One card in the import window: lists it, finds what is already on the Mac, and imports the rest.
/// Listing, the duplicate check and the import all run off the main actor; this class only publishes their state.
@MainActor @Observable final class ImportModel {
    enum Phase {
        case listing
        /// The library is still running its first scan; the duplicate check waits for it.
        case waitingForLibrary
        case checking(done: Int, total: Int)
        case ready
        case importing(ImportProgress)
        case done(ImportResult)
        case failed(String)

        var isReady: Bool { if case .ready = self { true } else { false } }
        var isImporting: Bool { if case .importing = self { true } else { false } }
        var isWaitingForLibrary: Bool { if case .waitingForLibrary = self { true } else { false } }
        /// Listing, checking or importing.
        var isBusy: Bool {
            switch self {
            case .listing, .waitingForLibrary, .checking, .importing: true
            case .ready, .done, .failed: false
            }
        }
    }

    static let destinationKey = "import.lastDestination"
    static let deleteSourcesKey = "import.deleteFromCard"

    let card: Card
    private(set) var groups: [PhotoGroup] = []
    /// Card files with an identical copy on the Mac (or imported by this window).
    private(set) var present: Set<URL> = []
    private(set) var photosLibraryChecked = true
    /// `PhotoGroup.importID`s.
    var selection: Set<String> = []
    var destination: ImportDestination { didSet { saveDestination() } }
    /// Delete each photo from the card once its copy in the library is verified. Remembered; off by default.
    var deletesSources: Bool { didSet { preferences.set(deletesSources, forKey: Self.deleteSourcesKey) } }
    private(set) var phase: Phase = .listing

    /// Thumbnails of card files, cached in the library's normal thumbnail directory.
    @ObservationIgnored let thumbnails: ThumbnailLoader?
    @ObservationIgnored private let engine: ImportEngine
    @ObservationIgnored private let preferences: any PreferenceStore
    @ObservationIgnored private let onError: (any Error) -> Void
    /// Called when an import ends, whatever the outcome.
    @ObservationIgnored var onImportFinished: (ImportModel) -> Void = { _ in }
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var cancelImport: (() -> Void)?

    /// `albums`: the album paths that exist now; a remembered album that is gone falls back to Unsorted.
    init(
        card: Card, engine: ImportEngine, preferences: any PreferenceStore, albums: Set<String>? = nil,
        thumbnails: ThumbnailLoader? = nil, onError: @escaping (any Error) -> Void = { _ in }
    ) {
        self.card = card
        self.engine = engine
        self.preferences = preferences
        self.thumbnails = thumbnails
        self.onError = onError
        var remembered = Self.loadDestination(from: preferences)
        if case .album(let path) = remembered, let albums,
            !albums.contains(path.precomposedStringWithCanonicalMapping)
        {
            remembered = .photos
        }
        destination = remembered
        deletesSources = preferences.bool(forKey: Self.deleteSourcesKey) ?? false
    }

    // MARK: - State

    func isOnMac(_ group: PhotoGroup) -> Bool {
        group.versions.allSatisfy { present.contains($0.file.url) }
    }

    var newGroups: [PhotoGroup] { groups.filter { !isOnMac($0) } }

    /// Import buttons are enabled only with something listed and checked, and nothing running.
    var canImport: Bool {
        switch phase {
        case .ready, .done: !newGroups.isEmpty
        default: false
        }
    }

    var canImportSelected: Bool { canImport && newGroups.contains { selection.contains($0.importID) } }

    // MARK: - Listing and checking

    /// Lists the card, then checks which groups are already on the Mac.
    @discardableResult func load() -> Task<Void, Never> {
        loadTask?.cancel()
        phase = .listing
        let card = card, engine = engine
        let task = Task { [weak self] in
            let listed = await Task.detached(priority: .userInitiated) { Result { try engine.list(card) } }.value
            guard let self, !Task.isCancelled else { return }
            let groups: [PhotoGroup]
            switch listed {
            case .success(let g): groups = g
            case .failure(let error):
                fail(error, "Couldn't read “\(card.name)”")
                return
            }
            self.groups = groups
            phase = .waitingForLibrary
            await engine.waitForLibrary()
            guard !Task.isCancelled else { return }
            phase = .checking(done: 0, total: groups.reduce(0) { $0 + $1.versions.count })
            // Holds the model until the check ends; cancelling the load cancels the check.
            let check = Task.detached(priority: .userInitiated) {
                try await engine.check(groups) { done, total in
                    Task { @MainActor in self.checkProgressed(done: done, total: total) }
                }
            }
            let report = await withTaskCancellationHandler { await check.result } onCancel: { check.cancel() }
            guard !Task.isCancelled else { return }
            switch report {
            case .success(let report):
                present = report.presentFiles
                photosLibraryChecked = report.photosLibraryChecked
                phase = .ready
            case .failure(let error):
                fail(error, "Couldn't check “\(card.name)” for photos already on this Mac")
            }
        }
        loadTask = task
        return task
    }

    private func checkProgressed(done: Int, total: Int) {
        guard case .checking(let shown, _) = phase, done >= shown else { return }
        phase = .checking(done: done, total: total)
    }

    private func fail(_ error: any Error, _ what: String) {
        let message = "\(what): \(error.localizedDescription)"
        phase = .failed(message)
        onError(ImportUIError(message))
    }

    /// Stops listing or checking (the card went away). A running import is not affected.
    func stopLoading() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Import

    @discardableResult func importAllNew() -> Task<Void, Never>? {
        guard canImport else { return nil }
        return startImport(newGroups)
    }

    /// Imports the selected groups that are not on the Mac yet.
    @discardableResult func importSelected() -> Task<Void, Never>? {
        guard canImport else { return nil }
        let chosen = newGroups.filter { selection.contains($0.importID) }
        guard !chosen.isEmpty else { return nil }
        return startImport(chosen)
    }

    func cancel() { cancelImport?() }

    private func startImport(_ groups: [PhotoGroup]) -> Task<Void, Never> {
        let plan = ImportPlan(groups: groups, destinationFolder: destination.folder, deleteSources: deletesSources)
        let filesTotal = groups.reduce(0) { $0 + $1.allFiles.count }
        let bytesTotal = groups.reduce(Int64(0)) { $0 + $1.versions.reduce(0) { $0 + $1.file.size } }
        phase = .importing(ImportProgress(filesDone: 0, filesTotal: filesTotal, bytesDone: 0, bytesTotal: bytesTotal))
        let engine = engine
        // Holds the model until the import ends.
        let work = Task.detached(priority: .userInitiated) {
            try await engine.run(plan) { progress in
                Task { @MainActor in self.importProgressed(progress) }
            }
        }
        cancelImport = { work.cancel() }
        return Task { [weak self] in
            let outcome = await work.result
            self?.finishImport(plan, outcome)
        }
    }

    private func importProgressed(_ progress: ImportProgress) {
        guard case .importing(let shown) = phase, progress.filesDone >= shown.filesDone else { return }
        phase = .importing(progress)
    }

    private func finishImport(_ plan: ImportPlan, _ outcome: Result<ImportResult, any Error>) {
        cancelImport = nil
        switch outcome {
        case .success(let result):
            // Verified copies are on the Mac now; failed and skipped groups are not.
            let notImported = Set(result.skipped).union(result.failed.keys)
            for group in plan.groups where !group.allFiles.contains(where: notImported.contains) {
                present.formUnion(group.versions.map(\.file.url))
                selection.remove(group.importID)
            }
            // Photos deleted from the card leave its listing.
            let deleted = Set(result.deletedSources)
            groups.removeAll { group in !group.allFiles.isEmpty && group.allFiles.allSatisfy(deleted.contains) }
            if case .newAlbum = destination { destination = .album(result.destinationFolder) }
            phase = .done(result)
        case .failure(let error):
            phase = .ready
            if !(error is CancellationError) { onError(error) }
        }
        onImportFinished(self)
    }

    // MARK: - Remembered destination

    private func saveDestination() {
        // A new album is remembered once it exists (as `.album`).
        if case .newAlbum = destination { return }
        guard let data = try? JSONEncoder().encode(destination) else { return }
        preferences.set(String(decoding: data, as: UTF8.self), forKey: Self.destinationKey)
    }

    private static func loadDestination(from preferences: any PreferenceStore) -> ImportDestination {
        guard let json = preferences.string(forKey: destinationKey),
            let destination = try? JSONDecoder().decode(ImportDestination.self, from: Data(json.utf8))
        else { return .photos }
        if case .newAlbum = destination { return .photos }
        return destination
    }

    // MARK: - Summary

    /// "125 files imported and deleted from the card, 2 skipped, 1 failed, 1 couldn't be deleted from the card."
    static func summary(of result: ImportResult) -> String {
        var first = "\(result.imported.count) \(result.imported.count == 1 ? "file" : "files") imported"
        if !result.deletedSources.isEmpty {
            first += result.deletedSources.count == result.imported.count
                ? " and deleted from the card" : " (\(result.deletedSources.count) deleted from the card)"
        }
        var parts = [first]
        if !result.skipped.isEmpty { parts.append("\(result.skipped.count) skipped") }
        if !result.failed.isEmpty { parts.append("\(result.failed.count) failed") }
        if !result.sourceDeleteFailures.isEmpty {
            parts.append("\(result.sourceDeleteFailures.count) couldn't be deleted from the card")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// One line per failed file, by name: "IMG_1.CR2: <reason>"; then files that stayed on the card.
    static func failures(of result: ImportResult) -> [String] {
        result.failed.map { "\($0.key.lastPathComponent): \($0.value.localizedDescription)" }.sorted()
            + result.sourceDeleteFailures.map {
                "\($0.key.lastPathComponent): imported, but not deleted from the card: \($0.value.localizedDescription)"
            }.sorted()
    }
}

struct ImportUIError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
