import Foundation
import LoupeCore
import LoupeFeatures
import LoupeIndex
import Testing
@testable import LoupeUI

private final class MemoryPreferences: PreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}

@MainActor @Suite struct SidebarArrangementTests {
    private func makeModel(_ preferences: MemoryPreferences = MemoryPreferences()) -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-ui-\(UUID().uuidString)")
        return AppModel(preferences: preferences, rootOverride: "/lib", supportDirectory: dir, cacheDirectory: dir)
    }

    private func group(_ id: String, _ items: [SidebarItem] = []) -> SidebarGroup {
        SidebarGroup(id: id, title: id, items: items)
    }

    private func album(_ path: String, children: [SidebarItem] = []) -> SidebarItem {
        SidebarItem(id: "folder:\(path)", title: path, systemImage: "rectangle.stack", scope: .folder(path),
                    children: children, dropTarget: .folder(path))
    }

    @Test func sectionsFollowTheSavedOrderAndNewOnesStayAboveTheirNeighbour() {
        let groups = ["library", "media", "utilities", "albums", "tags"].map { group($0) }
        let ids = { (order: [String]) in AppModel.arranged(groups, order: order).map(\.id) }
        #expect(ids([]) == ["library", "media", "utilities", "albums", "tags"])
        #expect(ids(["library", "albums", "media", "utilities", "tags"]) == ["library", "albums", "media", "utilities", "tags"])
        // "media" isn't in the saved order: it stays right above "utilities", which it naturally precedes.
        #expect(ids(["albums", "library", "utilities", "tags"]) == ["albums", "library", "media", "utilities", "tags"])
        // One with nothing saved after it goes to the end.
        #expect(ids(["albums", "library", "media", "utilities"]) == ["albums", "library", "media", "utilities", "tags"])
        // A new section before every saved one goes to the top.
        #expect(AppModel.arranged([group("new")] + groups, order: ["library", "media"]).first?.id == "new")
        // Pinned first appears right above Media Types, also when sections were reordered before it existed.
        let withPinned = [group("library"), group("pinned"), group("media"), group("albums")]
        #expect(AppModel.arranged(withPinned, order: ["library", "media", "albums"]).map(\.id)
                == ["library", "pinned", "media", "albums"])
        #expect(AppModel.arranged(withPinned, order: ["albums", "library", "media"]).map(\.id)
                == ["albums", "library", "pinned", "media"])
        #expect(AppModel.arranged(withPinned, order: ["media", "library", "albums"]).map(\.id)
                == ["pinned", "media", "library", "albums"])
    }

    @Test func pinnedRowsAreLeafCopiesUnderTheirOwnIDs() {
        let model = makeModel()
        let trip = album("Trip", children: [album("Trip/Day 1")])
        let groups = [group("albums", [trip])]
        #expect(model.pinnedGroup(from: groups) == nil)  // nothing pinned: no Pinned section

        model.togglePin(trip.children[0])
        model.togglePin(trip)
        let pinned = model.pinnedGroup(from: groups)
        #expect(pinned?.items.map(\.id) == ["pin:folder:Trip/Day 1", "pin:folder:Trip"])
        #expect(pinned?.items.allSatisfy(\.children.isEmpty) == true)
        #expect(model.isPinned(pinned!.items[1]) && model.isPinned(trip))

        model.togglePin(pinned!.items[0])  // unpinning from the Pinned row itself
        #expect(model.pinnedItemIDs == ["folder:Trip"])
    }

    @Test func pinsAreSavedPerLibraryAndFollowRenames() {
        let preferences = MemoryPreferences()
        let model = makeModel(preferences)
        model.togglePin(album("Trip"))
        model.togglePin(album("Trip/Day 1"))
        model.renameArrangement(from: "folder:Trip", to: "folder:Iceland")
        #expect(model.pinnedItemIDs == ["folder:Iceland", "folder:Iceland/Day 1"])
        #expect(makeModel(preferences).pinnedItemIDs == ["folder:Iceland", "folder:Iceland/Day 1"])

        let other = AppModel(
            preferences: preferences, rootOverride: "/other",
            supportDirectory: FileManager.default.temporaryDirectory, cacheDirectory: FileManager.default.temporaryDirectory)
        #expect(other.pinnedItemIDs.isEmpty)
    }

    @Test func itemsKeepTheirDraggedOrderAndIconsAtEveryLevelAndFollowRenames() {
        let preferences = MemoryPreferences()
        let model = makeModel(preferences)
        let groups = [group("albums", [album("A"), album("B", children: [album("B/1"), album("B/2")]), album("C")])]
        model.moveItems(in: "albums", shown: ["folder:A", "folder:B", "folder:C"], from: [2], to: 0)
        model.moveItems(in: "folder:B", shown: ["folder:B/1", "folder:B/2"], from: [1], to: 0)
        model.setIcon("airplane", for: groups[0].items[1].children[0])

        let shown = makeModel(preferences).customized(groups)[0].items  // saved
        #expect(shown.map(\.id) == ["folder:C", "folder:A", "folder:B"])
        #expect(shown[2].children.map(\.id) == ["folder:B/2", "folder:B/1"])
        #expect(shown[2].children[1].systemImage == "airplane")
        // A new album stays right above the one it naturally precedes.
        let withNew = [group("albums", [album("A"), album("Aa"), album("B"), album("C")])]
        #expect(model.customized(withNew)[0].items.map(\.id) == ["folder:C", "folder:A", "folder:Aa", "folder:B"])

        model.renameArrangement(from: "folder:B", to: "folder:Bee")
        let renamed = [group("albums", [album("A"), album("Bee", children: [album("Bee/1"), album("Bee/2")]), album("C")])]
        let after = model.customized(renamed)[0].items
        #expect(after.map(\.id) == ["folder:C", "folder:A", "folder:Bee"])
        #expect(after[2].children.map(\.id) == ["folder:Bee/2", "folder:Bee/1"])
        #expect(after[2].children[1].systemImage == "airplane")

        model.setIcon(nil, for: after[2].children[1])
        #expect(model.customized(renamed)[0].items[1].children.isEmpty)
        #expect(model.customized(renamed)[0].items[2].children[1].systemImage == "rectangle.stack")
    }

    @Test func aPersonOpensFromPeopleAndBackReturnsThere() {
        let model = makeModel()
        func group(_ id: Int64, _ kind: String, _ count: Int) -> LibraryIndex.FaceGroup {
            LibraryIndex.FaceGroup(id: id, kind: kind, photoCount: count, coverFaceID: id, coverPhotoID: id, coverBox: .zero)
        }
        model.faceGroups = [group(4, "person", 10), group(9, "cat", 5), group(2, "person", 3)]
        #expect(model.faceGroups.map(model.faceGroupTitle) == ["Person 1", "Cat 1", "Person 2"])

        model.query.scope = .people
        model.openFaceGroup(2)
        #expect(model.query.scope == .faceGroup(2) && model.selectedTitle == "Person 2" && model.canGoBack)
        model.goBack()
        #expect(model.openedFaceGroup == nil && model.query.scope == .people)

        model.openFaceGroup(4)
        model.selectedItemID = "favorites"  // another sidebar item closes the person
        #expect(model.openedFaceGroup == nil)
    }

    @Test func backReturnsToThePreviousItemsThenClosesTheViewerFirst() {
        let model = makeModel()
        #expect(!model.canGoBack)
        model.selectedItemID = "favorites"
        model.selectedItemID = "recent"
        model.viewerPhotoID = 3
        #expect(model.canGoBack)
        model.goBack()
        #expect(model.viewerPhotoID == nil && model.selectedItemID == "recent")
    }
}
