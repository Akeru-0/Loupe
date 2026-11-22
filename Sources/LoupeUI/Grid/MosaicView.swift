import AppKit
import LoupeCore
import LoupeMedia

/// The grid zoomed out beyond its last step, as Photos' Years view: every photo a square, edge to edge, row after
/// row without date headers, a month's name over the row where it starts. Built for scrolling through thousands
/// of photos on a MacBook Air: each photo is a plain layer (no view, no badges) showing a small picture
/// (`ThumbnailLoader.mosaic`), and only the rows on screen have layers, taken from a pool as they scroll in.
/// Clicking a photo zooms back in to it.
@MainActor final class MosaicView: NSView {
    struct Photo: Equatable {
        var id: Int64
        var file: MediaFile?
        var kind: VersionKind
        var rotation: Int?
        var date: Date?
    }

    var photos: [Photo] = [] {
        didSet { if photos != oldValue { relayout(reload: true) } }
    }
    var columns = 30 {
        didSet { if columns != oldValue { relayout(reload: true) } }
    }
    weak var loader: ThumbnailLoader?
    /// A photo clicked: zoom in to it.
    var onClick: (Int64) -> Void = { _ in }
    var onMagnify: (NSEvent) -> Void = { _ in }

    private var tiles: [Int: CALayer] = [:]
    private var pool: [CALayer] = []
    private var labels: [Int: CALayer] = [:]
    /// Rows that start a labelled month, and the label.
    private var monthRows: [(row: Int, title: String)] = []
    private var lastPrefetchY: CGFloat?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var side: CGFloat { bounds.width / CGFloat(max(1, columns)) }
    private var rows: Int { (photos.count + columns - 1) / max(1, columns) }

    /// The tiles' picture size: the tile in pixels, in steps (smaller pictures decode faster and take less memory:
    /// 96 px for the finest mosaic, about 25 KB a photo).
    private var pixels: Int {
        let tile = side * (window?.backingScaleFactor ?? 2)
        return tile <= 96 ? 96 : tile <= 128 ? 128 : ThumbnailCache.microPixelSize
    }

    // MARK: - Layout

    /// Sizes the view for `width` (the scroll view's) and its rows; with `reload`, every tile is set again.
    func relayout(width: CGFloat? = nil, reload: Bool = false) {
        let width = width ?? enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let side = width / CGFloat(max(1, columns))
        let height = max(CGFloat(rows) * side, enclosingScrollView?.contentView.bounds.height ?? 0)
        if frame.size != CGSize(width: width, height: height) { setFrameSize(CGSize(width: width, height: height)) }
        if reload {
            for (_, tile) in tiles { recycle(tile) }
            tiles = [:]
            for (_, label) in labels { label.removeFromSuperlayer() }
            labels = [:]
            monthRows = Self.monthRows(photos.map(\.date), columns: columns)
            lastPrefetchY = nil
        }
        updateTiles()
    }

    /// Rows where a month starts, labelled "Jun 2019", at least two rows apart so labels never crowd.
    static func monthRows(_ dates: [Date?], columns: Int, calendar: Calendar = .current) -> [(row: Int, title: String)] {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
        var result: [(row: Int, title: String)] = []
        var lastMonth: DateComponents?
        for (index, date) in dates.enumerated() {
            guard let date else { continue }
            let month = calendar.dateComponents([.year, .month], from: date)
            guard month != lastMonth else { continue }
            lastMonth = month
            let row = index / max(1, columns)
            if let last = result.last, row - last.row < 2 { continue }
            result.append((row, formatter.string(from: date)))
        }
        return result
    }

    private func frame(of index: Int) -> CGRect {
        let side = self.side
        let x = (CGFloat(index % columns) * side).rounded(.down)
        let y = (CGFloat(index / columns) * side).rounded(.down)
        let next = CGPoint(x: (CGFloat(index % columns + 1) * side).rounded(.down),
                           y: (CGFloat(index / columns + 1) * side).rounded(.down))
        return CGRect(x: x, y: y, width: next.x - x, height: next.y - y)  // whole points: no hairline seams
    }

    /// The photos on screen (and half a screen around) get layers; the rest give theirs back to the pool.
    func updateTiles() {
        guard !photos.isEmpty, side > 0, let visible = enclosingScrollView?.contentView.bounds else { return }
        let margin = visible.height / 2
        let firstRow = max(0, Int((visible.minY - margin) / side))
        let lastRow = min(rows - 1, Int((visible.maxY + margin) / side))
        guard firstRow <= lastRow else { return }
        let range = (firstRow * columns)..<min(photos.count, (lastRow + 1) * columns)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tile) in tiles where !range.contains(index) {
            recycle(tile)
            tiles[index] = nil
        }
        let pixels = self.pixels
        for index in range where tiles[index] == nil {
            let tile = pool.popLast() ?? makeTile()
            tile.frame = frame(of: index)
            tile.isHidden = false
            let photo = photos[index]
            if let file = photo.file, let image = loader?.cachedMosaic(file, rotation: photo.rotation, pixels: pixels) {
                tile.contents = image
            } else {
                tile.contents = nil
                load(index, into: tile, pixels: pixels)
            }
            tiles[index] = tile
        }
        updateLabels(rows: firstRow...lastRow)
        CATransaction.commit()
        prefetchAhead(visible)
    }

    private func makeTile() -> CALayer {
        let tile = CALayer()
        tile.contentsGravity = .resizeAspectFill
        tile.masksToBounds = true
        tile.backgroundColor = NSColor.gray.withAlphaComponent(0.18).cgColor
        tile.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(tile)
        return tile
    }

    private func recycle(_ tile: CALayer) {
        tile.isHidden = true
        tile.contents = nil
        pool.append(tile)
    }

    private func load(_ index: Int, into tile: CALayer, pixels: Int) {
        guard let loader, let file = photos[index].file else { return }
        let photo = photos[index]
        Task { [weak self] in
            let image = await loader.mosaic(for: file, kind: photo.kind, rotation: photo.rotation, pixels: pixels)
            // Still the same photo in that tile (it may have scrolled away and come back as another one).
            guard let self, let image, self.tiles[index] === tile, self.photos.indices.contains(index),
                self.photos[index] == photo
            else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tile.contents = image
            CATransaction.commit()
        }
    }

    /// Pictures for a screen and a half ahead in both directions, loaded quietly while scrolling.
    private func prefetchAhead(_ visible: CGRect) {
        guard let loader else { return }
        if let last = lastPrefetchY, abs(visible.minY - last) < visible.height / 2 { return }
        lastPrefetchY = visible.minY
        let side = self.side
        let first = max(0, Int((visible.minY - visible.height * 1.5) / side)) * columns
        let last = min(photos.count, Int((visible.maxY + visible.height * 1.5) / side + 1) * columns)
        guard first < last else { return }
        let pixels = self.pixels
        for photo in photos[first..<last] {
            guard let file = photo.file, loader.cachedMosaic(file, rotation: photo.rotation, pixels: pixels) == nil else { continue }
            Task(priority: .utility) {
                _ = await loader.mosaic(for: file, kind: photo.kind, rotation: photo.rotation, pixels: pixels, priority: .utility)
            }
        }
    }

    private func updateLabels(rows: ClosedRange<Int>) {
        let scale = window?.backingScaleFactor ?? 2
        let shown = Set(monthRows.filter { rows.contains($0.row) }.map(\.row))
        for (row, label) in labels where !shown.contains(row) {
            label.removeFromSuperlayer()
            labels[row] = nil
        }
        for month in monthRows where shown.contains(month.row) && labels[month.row] == nil {
            guard let picture = BadgeImages.pill(month.title, scale: scale) else { continue }
            let label = CALayer()
            label.contents = picture.image
            label.contentsScale = scale
            label.zPosition = 5
            label.actions = ["position": NSNull(), "bounds": NSNull()]
            label.frame = CGRect(origin: CGPoint(x: 8, y: CGFloat(month.row) * side + 6), size: picture.size)
            layer?.addSublayer(label)
            labels[month.row] = label
        }
    }

    // MARK: - What's on screen

    /// The photo at the top left of the screen.
    var topPhotoID: Int64? {
        guard let visible = enclosingScrollView?.contentView.bounds, side > 0 else { return nil }
        let index = max(0, Int((visible.minY + side / 2) / side)) * columns
        return photos.indices.contains(index) ? photos[index].id : nil
    }

    /// The dates of the photos on screen.
    var visibleDates: [Date] {
        guard let visible = enclosingScrollView?.contentView.bounds, side > 0, !photos.isEmpty else { return [] }
        let first = max(0, Int(visible.minY / side)) * columns
        let last = min(photos.count, Int(visible.maxY / side + 1) * columns)
        return first < last ? photos[first..<last].compactMap(\.date) : []
    }

    /// Tiles on screen without their picture yet, and all tiles on screen (for the scroll benchmark).
    var emptyTiles: (empty: Int, shown: Int) {
        guard let visible = enclosingScrollView?.contentView.bounds else { return (0, 0) }
        let shown = tiles.values.filter { visible.intersects($0.frame) }
        return (shown.filter { $0.contents == nil }.count, shown.count)
    }

    /// Scrolls so `id`'s row is at the top.
    func scroll(toTop id: Int64) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        scroll(NSPoint(x: 0, y: CGFloat(index / columns) * side))
    }

    // MARK: - Events

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard side > 0 else { return }
        let column = Int(point.x / side), row = Int(point.y / side)
        let index = row * columns + column
        if column < columns, photos.indices.contains(index) { onClick(photos[index].id) }
    }

    override func magnify(with event: NSEvent) { onMagnify(event) }
}
