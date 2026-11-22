import AppKit
import LoupeCore
import Testing
@testable import LoupeUI

@MainActor @Suite struct OrganizeTests {
    @Test func dragReadsOneDecimalIDPerPasteboardItem() {
        func item(_ id: String?) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString("file:///tmp/x.jpg", forType: .fileURL)
            if let id { item.setString(id, forType: PhotoGridController.photoIDsType) }
            return item
        }
        #expect(PhotoGridController.photoIDs(in: [item("12"), item("7"), item("12")]) == [12, 7])
        // A Finder file (no photo id) or junk is not a photo of this library.
        #expect(PhotoGridController.photoIDs(in: [item(nil)]).isEmpty)
        #expect(PhotoGridController.photoIDs(in: [item("12,7"), item("x"), item("3")]) == [3])
    }

    @Test func tagsWithAPathSeparatorAreRefused() {
        #expect(TagEditorModel.isValidTag("Iceland"))
        #expect(!TagEditorModel.isValidTag("Trips|Iceland"))
        #expect(!TagEditorModel.isValidTag("|"))
    }

    @Test func tagsOnSomePhotosArePartial() {
        let tokens = TagEditorModel.tokens(perPhoto: [["Beach", "Iceland"], ["Iceland", "Zoo"], ["Iceland"]])
        #expect(tokens == [
            TagToken(name: "Beach", onAll: false),
            TagToken(name: "Iceland", onAll: true),
            TagToken(name: "Zoo", onAll: false),
        ])
        #expect(TagEditorModel.tokens(perPhoto: []).isEmpty)
        #expect(TagEditorModel.tokens(perPhoto: [["Tag 10", "Tag 2"]]).map(\.name) == ["Tag 2", "Tag 10"])
    }

    @MainActor @Test func shiftClickSelectsEveryPhotoBetweenRowByRowAcrossDays() {
        let sections = [PhotoSection(id: "2026-11-20", title: "", photoIDs: [1, 2, 3, 4, 5]),
                        PhotoSection(id: "2026-11-21", title: "", photoIDs: [6, 7, 8])]
        #expect(PhotoGridController.range(from: 2, to: 7, in: sections) == [2, 3, 4, 5, 6, 7])
        #expect(PhotoGridController.range(from: 7, to: 2, in: sections) == [2, 3, 4, 5, 6, 7])  // backwards too
        #expect(PhotoGridController.range(from: 4, to: 4, in: sections) == [4])
        #expect(PhotoGridController.range(from: 99, to: 4, in: sections) == nil)  // the anchor scrolled out of view
    }

    @MainActor @Test func farOutTilesShowOnlyTheSmallThumbnail() {
        // 15 columns in a 1,400 pt grid on a Retina screen: tiles of about 85 pt, 170 px.
        let side = GridLayout.metrics(containerWidth: 1400, columns: 15).side
        #expect(PhotoGridController.smallThumbnailSuffices(tilePixels: side * 2))
        // 5 columns: big tiles want the full thumbnail.
        #expect(!PhotoGridController.smallThumbnailSuffices(tilePixels: GridLayout.metrics(containerWidth: 1400, columns: 5).side * 2))
    }
}
