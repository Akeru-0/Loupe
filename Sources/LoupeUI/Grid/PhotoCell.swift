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
        cache.totalCostLimit = 320 << 20  // decoded bytes; the count alone allowed about 1 GB
    }

    private static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    /// `rotation` is the photo's extra turn (`CellInfo.rotation`): a rotated photo is a different image.
    private static func key(_ file: MediaFile, _ rotation: Int?) -> NSString {
        "\(file.url.path)|\(file.size)|\(file.modified.timeIntervalSince1970)|\(rotation ?? 0)" as NSString
    }

    func cached(_ file: MediaFile, rotation: Int?) -> CGImage? { cache.object(forKey: Self.key(file, rotation)) }

    /// Cancelling the calling task stops the load if it hasn't started decoding yet.
    func image(for file: MediaFile, kind: VersionKind, rotation: Int?) async -> CGImage? {
        let key = Self.key(file, rotation)
        if let image = cache.object(forKey: key) { return image }
        if let pending = prefetches[key] {
            if let image = await pending.task.value { return image }
            // The prefetch was cancelled (or failed); load it for this cell instead.
            if Task.isCancelled { return nil }
        }
        guard !Task.isCancelled else { return nil }
        let image = await thumbnails.thumbnail(for: file, kind: kind, rotation: rotation)
        if let image { cache.setObject(image, forKey: key, cost: Self.cost(image)) }
        return image
    }

    func prefetch(_ file: MediaFile, kind: VersionKind, rotation: Int?) {
        let key = Self.key(file, rotation)
        guard cache.object(forKey: key) == nil, prefetches[key] == nil else { return }
        let token = UUID()
        let thumbnails = thumbnails
        let task = Task(priority: .utility) { [weak self] () -> CGImage? in
            let image = await thumbnails.thumbnail(for: file, kind: kind, rotation: rotation)
            if let self {
                if let image { self.cache.setObject(image, forKey: key, cost: Self.cost(image)) }
                if self.prefetches[key]?.token == token { self.prefetches[key] = nil }
            }
            return image
        }
        prefetches[key] = (token, task)
    }

    func cancelPrefetch(_ file: MediaFile, rotation: Int?) {
        let key = Self.key(file, rotation)
        prefetches[key]?.task.cancel()
        prefetches[key] = nil
    }
}

/// One square grid slot showing the whole photo (aspect-fit, rounded corners) with badges on the photo itself.
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

    /// Shows `info` for `id`. The thumbnail is reloaded only if the display file or its orientation changed.
    func configure(id: Int64, info: CellInfo?, loader: ThumbnailLoader?) {
        let sameFile = photoID == id && info != nil && info?.displayFile == self.info?.displayFile
            && info?.rotation == self.info?.rotation
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
        if let image = loader.cached(info.displayFile, rotation: info.rotation) {
            cellView.setImage(image, failed: false)
            return
        }
        cellView.setImage(nil, failed: false)
        let file = info.displayFile, rotation = info.rotation
        loadTask = Task { [weak self] in
            let image = await loader.image(for: file, kind: info.displayKind, rotation: rotation)
            // A reused cell never shows another photo's thumbnail: the task is cancelled on reuse, and the file must match.
            guard !Task.isCancelled, let self, self.info?.displayFile == file, self.info?.rotation == rotation
            else { return }
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
    /// Pixel size of the shown thumbnail; nil until it loads (a rounded square placeholder until then).
    private var imageSize: CGSize?

    var isSelected = false {
        didSet { selectionLayer.isHidden = !isSelected }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let noAnimation: [String: any CAAction] = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(),
        ]
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerCurve = .continuous
        imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.18).cgColor
        imageLayer.actions = noAnimation
        layer?.addSublayer(imageLayer)

        placeholder.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.isHidden = true
        addSubview(placeholder)
        for v in [kinds, rating, heart, edits] as [NSView] { addSubview(v) }

        selectionLayer.borderWidth = 3
        selectionLayer.cornerCurve = .continuous
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
        let size = image.map { CGSize(width: $0.width, height: $0.height) }
        if size != imageSize {
            imageSize = size
            needsLayout = true
        }
        placeholder.isHidden = !failed
    }

    /// Where the photo sits in the slot: its own aspect ratio fitted inside the square and centred, so portrait
    /// photos read as slim tiles and landscape ones as wide tiles. A square until the thumbnail is known.
    static func photoRect(for imageSize: CGSize?, in bounds: CGRect) -> CGRect {
        guard let size = imageSize, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        return CGRect(x: bounds.minX + ((bounds.width - w) / 2).rounded(),
                      y: bounds.minY + ((bounds.height - h) / 2).rounded(), width: w, height: h)
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
        let photo = Self.photoRect(for: imageSize, in: bounds)
        let radius = min(10, max(3, min(photo.width, photo.height) * 0.05))
        imageLayer.frame = photo
        imageLayer.cornerRadius = radius
        selectionLayer.frame = photo
        selectionLayer.cornerRadius = radius
        CATransaction.commit()

        // Badges sit in the photo's own corners, not the slot's.
        let inset: CGFloat = 5, icon: CGFloat = 13
        let tiny = photo.width < 56
        for v in [kinds, rating] { v.isHidden = tiny || v.stringValue.isEmpty }
        kinds.sizeToFit()
        rating.sizeToFit()
        kinds.frame.origin = CGPoint(x: photo.minX + inset, y: photo.maxY - inset - kinds.frame.height)
        kinds.frame.size.width = min(kinds.frame.width, photo.width - 2 * inset)
        rating.frame.origin = CGPoint(x: photo.maxX - inset - rating.frame.width, y: photo.maxY - inset - rating.frame.height)
        heart.frame = CGRect(x: photo.maxX - inset - icon, y: photo.minY + inset, width: icon, height: icon)
        edits.frame = CGRect(x: photo.minX + inset, y: photo.minY + inset, width: icon, height: icon)
        let side = min(32, photo.width / 3)
        placeholder.frame = CGRect(x: photo.midX - side / 2, y: photo.midY - side / 2, width: side, height: side)
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
