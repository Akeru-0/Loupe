import Foundation
import LoupeCore
import LoupeFeatures
import LoupeImport
import LoupeIndex
import LoupeTestSupport
import Testing
@testable import LoupeUI

private final class Preferences: PreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}

/// What the fake engine was asked to import.
private final class Plans: @unchecked Sendable {
    private let lock = NSLock()
    private var _plans: [ImportPlan] = []
    var plans: [ImportPlan] { lock.lock(); defer { lock.unlock() }; return _plans }
    func append(_ plan: ImportPlan) { lock.lock(); _plans.append(plan); lock.unlock() }
}

/// A card folder that need not exist: the engine is faked.
private let folder = URL(fileURLWithPath: "/nonexistent-card/DCIM/100CANON", isDirectory: true)
private let card = Card(
    volumeURL: URL(fileURLWithPath: "/nonexistent-card"), name: "EOS_DIGITAL",
    dcimURL: URL(fileURLWithPath: "/nonexistent-card/DCIM"))

private func group(_ stem: String) -> PhotoGroup {
    let file = MediaFile(url: folder.appendingPathComponent(stem + ".CR2"), size: 1000, modified: .now, created: .now)
    return PhotoGroup(
        folder: folder, stem: stem, stemKey: stem.lowercased(), versions: [GroupedVersion(file: file, kind: .raw)],
        sidecar: nil, legacySidecars: [])
}

/// An engine over `groups` where `present` are on the Mac; imports succeed and are recorded in `plans`.
private func engine(_ groups: [PhotoGroup], present: [PhotoGroup] = [], plans: Plans) -> ImportEngine {
    let presentFiles = Set(present.flatMap { $0.versions.map(\.file.url) })
    return ImportEngine(
        list: { _ in groups },
        check: { _, _ in DuplicateReport(presentFiles: presentFiles, photosLibraryChecked: true) },
        run: { plan, _ in
            plans.append(plan)
            let names = plan.groups.flatMap(\.allFiles).map(\.lastPathComponent)
            return ImportResult(
                imported: names.map { plan.destinationFolder.isEmpty ? $0 : plan.destinationFolder + "/" + $0 },
                destinationFolder: plan.destinationFolder)
        })
}

@MainActor @Suite struct ImportModelTests {
    @Test func importAllNewSkipsPresent() async throws {
        let groups = [group("IMG_1"), group("IMG_2"), group("IMG_3")]
        let plans = Plans()
        let model = ImportModel(
            card: card, engine: engine(groups, present: [groups[1]], plans: plans), preferences: Preferences())
        #expect(model.importAllNew() == nil)  // nothing listed yet: refused
        await model.load().value
        #expect(model.phase.isReady)
        #expect(model.newGroups.map(\.stem) == ["IMG_1", "IMG_3"])
        #expect(model.isOnMac(groups[1]))

        await model.importAllNew()?.value
        #expect(plans.plans.map { $0.groups.map(\.stem) } == [["IMG_1", "IMG_3"]])
        guard case .done(let result) = model.phase else { Issue.record("not done: \(model.phase)"); return }
        #expect(result.imported == ["Photos/IMG_1.CR2", "Photos/IMG_3.CR2"])  // the default destination
        // What was just imported counts as on the Mac: a second Import All New has nothing to do.
        #expect(model.newGroups.isEmpty)
        #expect(model.importAllNew() == nil)
        #expect(plans.plans.count == 1)
    }

    @Test func deleteFromCardIsRememberedPassedOnAndDeletedPhotosLeaveTheListing() async throws {
        let groups = [group("IMG_1"), group("IMG_2")]
        let plans = Plans()
        let preferences = Preferences()
        let deleting = ImportEngine(
            list: { _ in groups },
            check: { _, _ in DuplicateReport(presentFiles: [], photosLibraryChecked: true) },
            run: { plan, _ in
                plans.append(plan)
                // IMG_1 is imported and deleted; IMG_2 is imported but stays on the card.
                var result = ImportResult(imported: ["IMG_1.CR2", "IMG_2.CR2"])
                result.deletedSources = groups[0].allFiles
                result.sourceDeleteFailures = [groups[1].allFiles[0]: CocoaError(.fileWriteNoPermission)]
                return result
            })
        let model = ImportModel(card: card, engine: deleting, preferences: preferences)
        #expect(!model.deletesSources)  // off by default
        model.deletesSources = true
        #expect(ImportModel(card: card, engine: deleting, preferences: preferences).deletesSources)

        await model.load().value
        await model.importAllNew()?.value
        #expect(plans.plans.map(\.deleteSources) == [true])
        #expect(model.groups.map(\.stem) == ["IMG_2"])
        guard case .done(let result) = model.phase else { Issue.record("not done: \(model.phase)"); return }
        #expect(ImportModel.summary(of: result)
                == "2 files imported (1 deleted from the card), 1 couldn't be deleted from the card.")
        #expect(ImportModel.failures(of: result).count == 1)
    }

    @Test func importSelectedTakesOnlyNewSelectedGroups() async throws {
        let groups = [group("IMG_1"), group("IMG_2"), group("IMG_3")]
        let plans = Plans()
        let model = ImportModel(
            card: card, engine: engine(groups, present: [groups[1]], plans: plans), preferences: Preferences())
        await model.load().value
        model.selection = [groups[1].importID, groups[2].importID]
        await model.importSelected()?.value
        #expect(plans.plans.map { $0.groups.map(\.stem) } == [["IMG_3"]])
        #expect(model.selection == [groups[1].importID])  // imported groups leave the selection
    }

    @Test func newAlbumDestinationPath() async throws {
        let groups = [group("IMG_1")]
        let plans = Plans()
        let preferences = Preferences()
        let model = ImportModel(card: card, engine: engine(groups, plans: plans), preferences: preferences)
        await model.load().value
        model.destination = .newAlbum(name: "Iceland", inGroup: "2026")
        await model.importAllNew()?.value
        #expect(plans.plans.first?.destinationFolder == "2026/Iceland")
        // Once created, the new album is an album like any other, and the one remembered.
        #expect(model.destination == .album("2026/Iceland"))
        #expect(ImportModel(card: card, engine: engine(groups, plans: plans), preferences: preferences).destination
            == .album("2026/Iceland"))

        #expect(ImportDestination.newAlbum(name: " Iceland ", inGroup: nil).folder == "Iceland")
        #expect(ImportDestination.newAlbum(name: "Iceland", inGroup: " ").folder == "Iceland")
        #expect(ImportDestination.unsorted.folder == "")
        #expect(ImportDestination.photos.folder == "Photos")
        #expect(ImportDestination.defaultGroup(for: Date(timeIntervalSince1970: 1_790_000_000)) == "2026")
    }

    @Test func lastDestinationIsRemembered() {
        let preferences = Preferences()
        let plans = Plans()
        let first = ImportModel(card: card, engine: engine([], plans: plans), preferences: preferences)
        #expect(first.destination == .photos)  // the default
        first.destination = .album("2026/Iceland")
        #expect(preferences.string(forKey: "import.lastDestination") != nil)

        let second = ImportModel(card: card, engine: engine([], plans: plans), preferences: preferences)
        #expect(second.destination == .album("2026/Iceland"))
        // An album that no longer exists falls back to Photos.
        let third = ImportModel(
            card: card, engine: engine([], plans: plans), preferences: preferences, albums: ["2025/Other"])
        #expect(third.destination == .photos)
        third.destination = .unsorted
        #expect(ImportModel(card: card, engine: engine([], plans: plans), preferences: preferences).destination == .unsorted)
    }

    @Test func listingFailureIsReported() async throws {
        let errors = ErrorsBox()
        let model = ImportModel(
            card: card,
            engine: ImportEngine(
                list: { _ in throw CocoaError(.fileReadNoSuchFile) },
                check: { _, _ in DuplicateReport(presentFiles: [], photosLibraryChecked: true) },
                run: { _, _ in ImportResult() }),
            preferences: Preferences(), onError: { errors.errors.append($0) })
        await model.load().value
        guard case .failed = model.phase else { Issue.record("not failed: \(model.phase)"); return }
        #expect(errors.errors.count == 1)
        #expect(model.importAllNew() == nil)
    }
}

/// A gate the test opens; `wait()` returns once it is open.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if open { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
    }
    func openGate() {
        lock.lock(); open = true; let w = waiters; waiters = []; lock.unlock()
        for c in w { c.resume() }
    }
}

/// The import check must not run against a library whose first scan has not indexed it yet: everything would
/// look new and Import All New would copy duplicates (always so on first launch).
@MainActor @Suite struct ImportWaitsForLibraryTests {
    @Test func modelWaitsForTheLibraryBeforeChecking() async throws {
        let gate = Gate()
        let checked = Gate()
        let groups = [group("IMG_1")]
        let model = ImportModel(
            card: card,
            engine: ImportEngine(
                list: { _ in groups },
                check: { _, _ in
                    checked.openGate()
                    return DuplicateReport(presentFiles: [], photosLibraryChecked: true)
                },
                run: { _, _ in ImportResult() },
                waitForLibrary: { await gate.wait() }),
            preferences: Preferences())
        let load = model.load()
        let deadline = Date().addingTimeInterval(5)
        while !model.phase.isWaitingForLibrary && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase.isWaitingForLibrary)
        #expect(!model.canImport)
        #expect(model.importAllNew() == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!checked.isOpen)
        gate.openGate()
        await load.value
        #expect(checked.isOpen)
        #expect(model.phase.isReady)
    }

    @Test func liveCheckWaitsForTheInitialScan() async throws {
        let lib = try TestLibrary()
        let cardDir = try TestLibrary()
        try lib.addJPEG("2026/Trip/IMG_1.JPG")
        try FileManager.default.createDirectory(at: cardDir.url("DCIM/100CANON"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: lib.url("2026/Trip/IMG_1.JPG"), to: cardDir.url("DCIM/100CANON/IMG_1.JPG"))
        try cardDir.addJPEG("DCIM/100CANON/IMG_2.JPG", width: 64)
        let card = Card(volumeURL: cardDir.root, name: "CARD", dcimURL: cardDir.url("DCIM"))
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let library = try Library(
            location: LocalFolderLocation(rootURL: lib.root), settings: LibrarySettings(rootPath: lib.root.path),
            registry: FeatureRegistry(), supportDirectory: support, cacheDirectory: support.appendingPathComponent("cache"))
        let engine = ImportEngine.live(library)
        let groups = try engine.list(card)
        #expect(groups.map(\.stem) == ["IMG_1", "IMG_2"])

        let done = Gate()
        let check = Task.detached {
            let report = try await engine.check(groups) { _, _ in }
            done.openGate()
            return report
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!done.isOpen)  // the library has not been started yet
        _ = await library.start()
        let report = try await check.value
        await library.stop()
        #expect(report.isOnMac(groups[0]))  // indexed by the initial scan
        #expect(!report.isOnMac(groups[1]))
    }
}

@MainActor private final class ErrorsBox {
    var errors: [any Error] = []
}
