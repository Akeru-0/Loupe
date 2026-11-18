import AppKit

/// Grid geometry: square items, `spacing` between items and rows, a column count per browse mode.
public enum GridLayout {
    public static let columnRange = 3...15
    public static let spacing: CGFloat = 2
    public static let headerHeight: CGFloat = 40

    public static func itemSide(containerWidth: CGFloat, columns: Int, spacing: CGFloat = 2) -> CGFloat {
        let n = max(1, columns)
        return max(1, (containerWidth - spacing * CGFloat(n - 1)) / CGFloat(n))
    }

    public static func defaultColumns(for mode: BrowseMode) -> Int {
        switch mode {
        case .years: 14
        case .months: 10
        case .days: 5
        case .all: 7
        }
    }

    public enum Direction { case left, right, up, down }

    /// The item an arrow key moves to. Left and right run through all items in order; up and down keep the column,
    /// landing on the last item of a short row and crossing into the neighbouring section at the edges.
    static func neighbor(of path: IndexPath, _ direction: Direction, sectionCounts: [Int], columns: Int) -> IndexPath? {
        let cols = max(1, columns)
        let s = path.section, i = path.item
        guard sectionCounts.indices.contains(s), i < sectionCounts[s] else { return nil }
        func nonEmpty(from start: Int, step: Int) -> Int? {
            var k = start
            while sectionCounts.indices.contains(k) {
                if sectionCounts[k] > 0 { return k }
                k += step
            }
            return nil
        }
        switch direction {
        case .left:
            if i > 0 { return IndexPath(item: i - 1, section: s) }
            return nonEmpty(from: s - 1, step: -1).map { IndexPath(item: sectionCounts[$0] - 1, section: $0) }
        case .right:
            if i + 1 < sectionCounts[s] { return IndexPath(item: i + 1, section: s) }
            return nonEmpty(from: s + 1, step: 1).map { IndexPath(item: 0, section: $0) }
        case .down:
            let row = i / cols, lastRow = (sectionCounts[s] - 1) / cols
            if row < lastRow { return IndexPath(item: min(i + cols, sectionCounts[s] - 1), section: s) }
            return nonEmpty(from: s + 1, step: 1).map { IndexPath(item: min(i % cols, sectionCounts[$0] - 1), section: $0) }
        case .up:
            if i >= cols { return IndexPath(item: i - cols, section: s) }
            return nonEmpty(from: s - 1, step: -1).map {
                let count = sectionCounts[$0]
                return IndexPath(item: min((count - 1) / cols * cols + i % cols, count - 1), section: $0)
            }
        }
    }
}
