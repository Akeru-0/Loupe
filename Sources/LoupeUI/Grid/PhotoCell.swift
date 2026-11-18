import AppKit
import LoupeCore
import LoupeIndex
import LoupeMedia

/// Thumbnails for the grid: an in-memory cache in front of the library's disk cache, plus prefetching.
/// Decoding happens off the main thread (in `ThumbnailCache`); this class only hands out finished images.
@MainActor final class ThumbnailLoader {
    private let thumbnails: ThumbnailCache
    private let cache = NSCache<NSString, CGImage>()
    private var prefetches: [NSString: (token: UUID, task: Task<CGImage?, Never>)] = [:]

    init(thumbnails: ThumbnailCache) {
        self.thumbnails = thumbnails
        cache.countLimit = 1000
    }

    private static func key(_ file: MediaFile) -> NSString {
        "\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)" as NSString
    }

    func cached(_ file: MediaFile) -> CGImage? { cache.object(forKey: Self.key(file)) }

    /// Cancelling the calling task stops the load if it hasn't started decoding yet.
    func image(for file: MediaFile, kind: VersionKind) async -> CGImage? {
        let key = Self.key(file)
        if let image = cache.object(forKey: key) { return image }
        if let pending = prefetches[key] {
            if let image = await pending.task.value { return image }
            // The prefetch was cancelled (or failed); load it for this cell instead.
            if Task.isCancelled { return nil }
        }
        guard !Task.isCancelled else { return nil }
        let image = await thumbnails.thumbnail(for: file, kind: kind)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func prefetch(_ file: MediaFile, kind: VersionKind) {
        let key = Self.key(file)
        guard cache.object(forKey: key) == nil, prefetches[key] == nil else { return }
        let token = UUID()
        let thumbnails = thumbnails
        let task = Task(priority: .utility) { [weak self] () -> CGImage? in
            let image = await thumbnails.thumbnail(for: file, kind: kind)
            if let self {
                if let image { self.cache.setObject(image, forKey: key) }
                if self.prefetches[key]?.token == token { self.prefetches[key] = nil }
            }
            return image
        }
        prefetches[key] = (token, task)
    }

    func cancelPrefetch(_ file: MediaFile) {
        let key = Self.key(file)
        prefetches[key]?.task.cancel()
        prefetches[key] = nil
    }
}

/// One square grid item: an aspect-filled thumbnail with badges.
final class PhotoCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCell")

    private(set) var photoID: Int64?
    private var info: CellInfo?
    private var loadTask: Task<Void, Never>?
    private var cellView: PhotoCellView { view as! PhotoCellView }

    override func loadView() { view = PhotoCellView() }

    override var isSelected: Bool {
        didSet { cellView.isSelected = isSelected }
    }

    /// Shows `info` for `id`. The thumbnail is reloaded only if the display file changed.
    func configure(id: Int64, info: CellInfo?, loader: ThumbnailLoader?) {
        let sameFile = photoID == id && info != nil && info?.displayFile == self.info?.displayFile
        photoID = id
        self.info = info
        cellView.show(info)
        guard !sameFile else { return }
        loadTask?.cancel()
        loadTask = nil
        guard let info, let loader else {
            cellView.setImage(nil, failed: false)
            return
        }
        if let image = loader.cached(info.displayFile) {
            cellView.setImage(image, failed: false)
            return
        }
        cellView.setImage(nil, failed: false)
        let file = info.displayFile
        loadTask = Task { [weak self] in
            let image = await loader.image(for: file, kind: info.displayKind)
            // A reused cell never shows another photo's thumbnail: the task is cancelled on reuse, and the file must match.
            guard !Task.isCancelled, let self, self.info?.displayFile == file else { return }
            self.cellView.setImage(image, failed: image == nil)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        photoID = nil
        info = nil
        cellView.setImage(nil, failed: false)
        cellView.show(nil)
    }
}

/// The cell's view; lays out its layers and badges by hand (no Auto Layout per cell while scrolling).
final class PhotoCellView: NSView {
    private let imageLayer = CALayer()
    private let selectionLayer = CALayer()
    private let kinds = PhotoCellView.label()
    private let rating = PhotoCellView.label()
    private let heart = PhotoCellView.symbol("heart.fill")
    private let edits = PhotoCellView.symbol("slider.horizontal.3")
    private let placeholder = NSImageView()

    var isSelected = false {
        didSet { selectionLayer.isHidden = !isSelected }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.18).cgColor
        let noAnimation: [String: any CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.actions = noAnimation
        layer?.addSublayer(imageLayer)

        placeholder.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.isHidden = true
        addSubview(placeholder)
        for v in [kinds, rating, heart, edits] as [NSView] { addSubview(v) }

        selectionLayer.borderWidth = 3
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        selectionLayer.isHidden = true
        selectionLayer.actions = noAnimation
        selectionLayer.zPosition = 10
        layer?.addSublayer(selectionLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setImage(_ image: CGImage?, failed: Bool) {
        imageLayer.contents = image
        placeholder.isHidden = !failed
    }

    func show(_ info: CellInfo?) {
        kinds.stringValue = info?.badges.joined(separator: " ") ?? ""
        rating.stringValue = (info?.rating ?? 0) > 0 ? "★\(info!.rating)" : ""
        heart.isHidden = info?.isFavorite != true
        edits.isHidden = info?.hasLightCraftEdits != true
        setAccessibilityLabel(info?.displayFile.url.deletingPathExtension().lastPathComponent)
        needsLayout = true
    }

    override func updateLayer() {
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        selectionLayer.frame = bounds
        CATransaction.commit()

        let inset: CGFloat = 5, icon: CGFloat = 13
        let tiny = bounds.width < 56
        for v in [kinds, rating] { v.isHidden = tiny || v.stringValue.isEmpty }
        kinds.sizeToFit()
        rating.sizeToFit()
        kinds.frame.origin = CGPoint(x: inset, y: bounds.height - inset - kinds.frame.height)
        kinds.frame.size.width = min(kinds.frame.width, bounds.width - 2 * inset)
        rating.frame.origin = CGPoint(x: bounds.width - inset - rating.frame.width, y: bounds.height - inset - rating.frame.height)
        heart.frame = CGRect(x: bounds.width - inset - icon, y: inset, width: icon, height: icon)
        edits.frame = CGRect(x: inset, y: inset, width: icon, height: icon)
        let side = min(32, bounds.width / 3)
        placeholder.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    private static let badgeShadow: NSShadow = {
        let s = NSShadow()
        s.shadowBlurRadius = 2
        s.shadowOffset = .zero
        s.shadowColor = NSColor.black.withAlphaComponent(0.7)
        return s
    }()

    private static func label() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .white
        l.shadow = badgeShadow
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private static func symbol(_ name: String) -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        v.contentTintColor = .white
        v.shadow = badgeShadow
        v.imageScaling = .scaleProportionallyUpOrDown
        v.isHidden = true
        return v
    }
}
