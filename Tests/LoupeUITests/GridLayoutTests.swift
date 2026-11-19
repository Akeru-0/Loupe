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

    @Test func gapIsAShareOfTheTileAndRowFillsWidth() {
        for width in [600.0, 1200.0, 2400.0] as [CGFloat] {
            for c in GridLayout.columnRange {
                let (side, gap) = GridLayout.metrics(containerWidth: width, columns: c)
                // tiles + gaps between them + both edge gaps fill the width exactly
                #expect(abs(CGFloat(c) * side + CGFloat(c + 1) * gap - width) < 0.001)
                #expect(gap >= 3)
                if side * GridLayout.spacingRatio >= 3 { #expect(abs(gap - side * GridLayout.spacingRatio) <= 1) }
            }
        }
        // 1200 pt wide, 10 columns → ~110 pt tiles with ~9 pt gaps; zooming out narrows the gap
        #expect(GridLayout.metrics(containerWidth: 1200, columns: 10).spacing == 9)
        #expect(GridLayout.metrics(containerWidth: 1200, columns: 3).spacing >
                GridLayout.metrics(containerWidth: 1200, columns: 15).spacing)
    }

    @Test func photosFitTheirSlotInTheirOwnShape() {
        let slot = CGRect(x: 0, y: 0, width: 150, height: 150)
        // landscape 3:2 → full width, centred vertically
        #expect(PhotoCellView.photoRect(for: CGSize(width: 600, height: 400), in: slot) == CGRect(x: 0, y: 25, width: 150, height: 100))
        // portrait 2:3 → full height, slim and centred horizontally
        #expect(PhotoCellView.photoRect(for: CGSize(width: 400, height: 600), in: slot) == CGRect(x: 25, y: 0, width: 100, height: 150))
        // square, and no thumbnail yet → the whole slot
        #expect(PhotoCellView.photoRect(for: CGSize(width: 500, height: 500), in: slot) == slot)
        #expect(PhotoCellView.photoRect(for: nil, in: slot) == slot)
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
