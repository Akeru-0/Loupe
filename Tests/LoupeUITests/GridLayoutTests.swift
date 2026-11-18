import CoreGraphics
import Foundation
import Testing
@testable import LoupeUI

@Suite struct GridLayoutTests {
    @Test func itemSideFillsWidth() {
        #expect(GridLayout.itemSide(containerWidth: 1000, columns: 7) == CGFloat(1000 - 12) / 7)
        #expect(GridLayout.itemSide(containerWidth: 1000, columns: 4, spacing: 0) == 250)
        #expect(GridLayout.itemSide(containerWidth: 300, columns: 1) == 300)
    }

    @Test func defaultColumnsPerMode() {
        #expect(GridLayout.defaultColumns(for: .years) == 14)
        #expect(GridLayout.defaultColumns(for: .months) == 10)
        #expect(GridLayout.defaultColumns(for: .days) == 5)
        #expect(GridLayout.defaultColumns(for: .all) == 7)
        #expect(GridLayout.columnRange == 3...15)
        for mode in BrowseMode.allCases { #expect(GridLayout.columnRange.contains(GridLayout.defaultColumns(for: mode))) }
    }

    /// Two sections of 7 and 3 items in 3 columns:  0 1 2 / 3 4 5 / 6 | 0 1 2
    @Test func arrowKeysMoveThroughSections() {
        let counts = [7, 3]
        func move(_ s: Int, _ i: Int, _ d: GridLayout.Direction) -> IndexPath? {
            GridLayout.neighbor(of: IndexPath(item: i, section: s), d, sectionCounts: counts, columns: 3)
        }
        #expect(move(0, 0, .left) == nil)
        #expect(move(0, 6, .right) == IndexPath(item: 0, section: 1))
        #expect(move(1, 0, .left) == IndexPath(item: 6, section: 0))
        #expect(move(1, 2, .right) == nil)
        #expect(move(0, 1, .down) == IndexPath(item: 4, section: 0))
        #expect(move(0, 4, .down) == IndexPath(item: 6, section: 0))  // short last row: last item
        #expect(move(0, 6, .down) == IndexPath(item: 0, section: 1))
        #expect(move(0, 5, .down) == IndexPath(item: 6, section: 0))  // short last row: last item
        #expect(move(1, 2, .up) == IndexPath(item: 6, section: 0))   // previous section's last row is short
        #expect(move(1, 0, .up) == IndexPath(item: 6, section: 0))
        #expect(move(0, 4, .up) == IndexPath(item: 1, section: 0))
        #expect(move(0, 2, .up) == nil)
        #expect(move(1, 1, .down) == nil)
    }
}
