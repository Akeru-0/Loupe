import Foundation
import LoupeCore
import LoupeFeatures
import LoupeImport
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
        #expect(result.imported == ["IMG_1.CR2", "IMG_3.CR2"])
        // What was just imported counts as on the Mac: a second Import All New has nothing to do.
        #expect(model.newGroups.isEmpty)
        #expect(model.importAllNew() == nil)
        #expect(plans.plans.count == 1)
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
        #expect(ImportDestination.defaultGroup(for: Date(timeIntervalSince1970: 1_790_000_000)) == "2026")
    }

    @Test func lastDestinationIsRemembered() {
        let preferences = Preferences()
        let plans = Plans()
        let first = ImportModel(card: card, engine: engine([], plans: plans), preferences: preferences)
        #expect(first.destination == .unsorted)
        first.destination = .album("2026/Iceland")
        #expect(preferences.string(forKey: "import.lastDestination") != nil)

        let second = ImportModel(card: card, engine: engine([], plans: plans), preferences: preferences)
        #expect(second.destination == .album("2026/Iceland"))
        // An album that no longer exists falls back to Unsorted.
        let third = ImportModel(
            card: card, engine: engine([], plans: plans), preferences: preferences, albums: ["2025/Other"])
        #expect(third.destination == .unsorted)
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

@MainActor private final class ErrorsBox {
    var errors: [any Error] = []
}
