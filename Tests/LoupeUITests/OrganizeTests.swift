import AppKit
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
}
