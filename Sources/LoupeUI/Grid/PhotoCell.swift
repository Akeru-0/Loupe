import AppKit
import LoupeCore
import LoupeIndex
import LoupeMedia

/// Thumbnails for the grid: an in-memory cache in front of the library's disk cache, plus prefetching.
/// Decoding happens off the main thread (in `ThumbnailCache`); this class only hands out finished images.
/// Tiny thumbnails (`ThumbnailCache.microPixelSize`) are kept apart and many more of them: a tile shows its tiny one
/// at once while the thumbnail loads, so fast scrolling never shows empty tiles.
@MainActor final class ThumbnailLoader {
    private let thumbnails: ThumbnailCache
    private let cache = NSCache<NSString, CGImage>()
    private let microCache = NSCache<NSString, CGImage>()
    private var prefetches: [NSString: (token: UUID, task: Task<CGImage?, Never>)] = [:]
    private var microLoads: [NSString: Task<CGImage?, Never>] = [:]

    init(thumbnails: ThumbnailCache) {
        self.thumbnails = thumbnails
        cache.countLimit = 1000
        cache.totalCostLimit = 320 << 20  // decoded bytes; the count alone allowed about 1 GB
        microCache.countLimit = 50_000
        microCache.totalCostLimit = 288 << 20  // ~150 KB each at most: 2,000 at the least, far more for landscape ones
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

    func cachedMicro(_ file: MediaFile, rotation: Int?) -> CGImage? {
        microCache.object(forKey: Self.key(file, rotation))
    }

    /// The small thumbnail. Without `make`, nil until the thumbnail was made once (cheap); with it, made now when
    /// missing (a far zoomed-out tile, which loads nothing else). Never cancelled, loaded once.
    func micro(for file: MediaFile, kind: VersionKind, rotation: Int?, make: Bool = false) async -> CGImage? {
        let key = Self.key(file, rotation)
        if let image = microCache.object(forKey: key) { return image }
        return await loadMicro(key, file, kind, rotation, make: make, priority: .userInitiated).value
    }

    /// Loads small thumbnails ahead of the scroll (`make`: making the missing ones).
    func prefetchMicro(_ file: MediaFile, kind: VersionKind, rotation: Int?, make: Bool = false) {
        let key = Self.key(file, rotation)
        guard microCache.object(forKey: key) == nil, cache.object(forKey: key) == nil else { return }
        _ = loadMicro(key, file, kind, rotation, make: make, priority: .utility)
    }

    private func loadMicro(
        _ key: NSString, _ file: MediaFile, _ kind: VersionKind, _ rotation: Int?, make: Bool, priority: TaskPriority
    ) -> Task<CGImage?, Never> {
        let pendingKey = (make ? "make|" : "read|") + (key as String) as NSString
        if let pending = microLoads[pendingKey] { return pending }
        let thumbnails = thumbnails
        let task = Task(priority: priority) { [weak self] () -> CGImage? in
            let image = await thumbnails.microThumbnail(for: file, kind: kind, rotation: rotation, make: make)
            if let self {
                if let image { self.microCache.setObject(image, forKey: key, cost: Self.cost(image)) }
                self.microLoads[pendingKey] = nil
            }
            return image
        }
        microLoads[pendingKey] = task
        return task
    }

    // MARK: The mosaic's

    private let mosaicCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 128 << 20  // 96 px pictures: about 5,000; 128 px ones: 2,500
        return cache
    }()
    private var mosaicLoads: [NSString: Task<CGImage?, Never>] = [:]

    func cachedMosaic(_ file: MediaFile, rotation: Int?, pixels: Int) -> CGImage? {
        pixels >= ThumbnailCache.microPixelSize
            ? cachedMicro(file, rotation: rotation) : mosaicCache.object(forKey: Self.mosaicKey(file, rotation, pixels))
    }

    /// A mosaic tile's picture, `pixels` across at most: the small thumbnail, read smaller when the tiles are; made
    /// when missing.
    func mosaic(for file: MediaFile, kind: VersionKind, rotation: Int?, pixels: Int, priority: TaskPriority = .userInitiated) async -> CGImage? {
        if pixels >= ThumbnailCache.microPixelSize { return await micro(for: file, kind: kind, rotation: rotation, make: true) }
        let key = Self.mosaicKey(file, rotation, pixels)
        if let image = mosaicCache.object(forKey: key) { return image }
        if let pending = mosaicLoads[key] { return await pending.value }
        let thumbnails = thumbnails
        let task = Task(priority: priority) { [weak self] () -> CGImage? in
            let image = await thumbnails.microThumbnail(for: file, kind: kind, rotation: rotation, make: true, maxPixelSize: pixels)
            if let self {
                if let image { self.mosaicCache.setObject(image, forKey: key, cost: Self.cost(image)) }
                self.mosaicLoads[key] = nil
            }
            return image
        }
        mosaicLoads[key] = task
        return await task.value
    }

    private static func mosaicKey(_ file: MediaFile, _ rotation: Int?, _ pixels: Int) -> NSString {
        "\(key(file, rotation))|m\(pixels)" as NSString
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
    /// The tile is small enough for the small thumbnail alone (the grid zoomed far out): no full one is loaded.
    private var smallOnly = false
    private var loadTask: Task<Void, Never>?
    private var cellView: PhotoCellView { view as! PhotoCellView }

    override func loadView() { view = PhotoCellView() }

    /// The thumbnail the tile shows and where it sits in the item's view, for the viewer's opening flight.
    var shownImage: CGImage? { cellView.image }
    var photoFrame: CGRect { cellView.photoFrame }

    override var isSelected: Bool {
        didSet { cellView.isSelected = isSelected }
    }

    /// Shows `info` for `id`. The thumbnail is reloaded only if the display file or its orientation changed, or the
    /// tile grew past what the small thumbnail covers. `smallOnly`: the small thumbnail is all this tile needs.
    func configure(id: Int64, info: CellInfo?, loader: ThumbnailLoader?, smallOnly: Bool = false) {
        let sameFile = photoID == id && info != nil && info?.displayFile == self.info?.displayFile
            && info?.rotation == self.info?.rotation
        let grew = sameFile && self.smallOnly && !smallOnly
        photoID = id
        self.info = info
        self.smallOnly = smallOnly
        cellView.show(info)
        guard !sameFile || grew else { return }
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
        // The small thumbnail at once, the thumbnail when it's loaded (unless the small one is all the tile needs).
        let micro = loader.cachedMicro(info.displayFile, rotation: info.rotation)
        if !grew { cellView.setImage(micro, failed: false) }  // growing: the small one stays up until the big one is in
        let file = info.displayFile, rotation = info.rotation
        loadTask = Task { [weak self] in
            if micro == nil {
                let tiny = await loader.micro(for: file, kind: info.displayKind, rotation: rotation, make: smallOnly)
                if !Task.isCancelled, let self, self.info?.displayFile == file, self.info?.rotation == rotation,
                    self.cellView.image == nil
                {
                    // Far out, the small one is all there is: none means the photo can't be shown.
                    if tiny != nil || smallOnly { self.cellView.setImage(tiny, failed: tiny == nil) }
                }
            }
            guard !Task.isCancelled, !smallOnly else { return }
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

/// The cell's view: one view of plain layers, laid out by hand (no Auto Layout, no subviews, no live shadows per
/// cell while scrolling). The badges are pictures drawn once with their shadow (`BadgeImages`).
final class PhotoCellView: NSView {
    private let imageLayer = CALayer()
    private let selectionLayer = CALayer()
    private let kinds = CALayer()
    private let rating = CALayer()
    private let heart = CALayer()
    private let edits = CALayer()
    private let placeholder = CALayer()
    private var kindsText = ""
    private var ratingText = ""
    private var failed = false
    /// Pixel size of the shown thumbnail; nil until it loads (a rounded square placeholder until then).
    private var imageSize: CGSize?
    private(set) var image: CGImage?

    var photoFrame: CGRect { Self.photoRect(for: imageSize, in: bounds) }

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
            "hidden": NSNull(), "frame": NSNull(),
        ]
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerCurve = .continuous
        imageLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.18).cgColor
        imageLayer.actions = noAnimation
        layer?.addSublayer(imageLayer)

        for badge in [placeholder, kinds, rating, heart, edits] {
            badge.actions = noAnimation
            badge.contentsGravity = .center
            badge.isHidden = true
            layer?.addSublayer(badge)
        }

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
        self.image = image
        imageLayer.contents = image
        let size = image.map { CGSize(width: $0.width, height: $0.height) }
        if size != imageSize || failed != self.failed {
            imageSize = size
            self.failed = failed
            needsLayout = true
        }
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

    static func cornerRadius(for photo: CGRect) -> CGFloat {
        min(10, max(3, min(photo.width, photo.height) * 0.05))
    }

    func show(_ info: CellInfo?) {
        let kindsText = info?.badges.joined(separator: " ") ?? ""
        let ratingText = (info?.rating ?? 0) > 0 ? "★\(info!.rating)" : ""
        let favorite = info?.isFavorite == true, edited = info?.hasLightCraftEdits == true
        if kindsText != self.kindsText || ratingText != self.ratingText || favorite == heart.isHidden
            || edited == edits.isHidden
        {
            self.kindsText = kindsText
            self.ratingText = ratingText
            heart.isHidden = !favorite
            edits.isHidden = !edited
            needsLayout = true
        }
        setAccessibilityLabel(info?.displayFile.url.deletingPathExtension().lastPathComponent)
    }

    override func updateLayer() {
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let photo = Self.photoRect(for: imageSize, in: bounds)
        let radius = Self.cornerRadius(for: photo)
        imageLayer.frame = photo
        imageLayer.cornerRadius = radius
        selectionLayer.frame = photo
        selectionLayer.cornerRadius = radius

        // Badges sit in the photo's own corners, not the slot's. Their pictures carry a margin for the shadow.
        let scale = window?.backingScaleFactor ?? 2
        let inset: CGFloat = 5 - BadgeImages.margin
        let tiny = photo.width < 56
        func place(_ layer: CALayer, _ picture: BadgeImages.Picture?, _ origin: (CGSize) -> CGPoint) {
            guard let picture else { return layer.isHidden = true }
            layer.contents = picture.image
            layer.contentsScale = scale
            layer.frame = CGRect(origin: origin(picture.size), size: picture.size)
        }
        place(kinds, tiny || kindsText.isEmpty ? nil : BadgeImages.text(kindsText, scale: scale)) {
            CGPoint(x: photo.minX + inset, y: photo.maxY - inset - $0.height)
        }
        if !tiny, !kindsText.isEmpty { kinds.isHidden = false }
        place(rating, tiny || ratingText.isEmpty ? nil : BadgeImages.text(ratingText, scale: scale)) {
            CGPoint(x: photo.maxX - inset - $0.width, y: photo.maxY - inset - $0.height)
        }
        if !tiny, !ratingText.isEmpty { rating.isHidden = false }
        if !heart.isHidden {
            place(heart, BadgeImages.symbol("heart.fill", scale: scale)) { CGPoint(x: photo.maxX - inset - $0.width, y: photo.minY + inset) }
        }
        if !edits.isHidden {
            place(edits, BadgeImages.symbol("slider.horizontal.3", scale: scale)) { _ in CGPoint(x: photo.minX + inset, y: photo.minY + inset) }
        }
        placeholder.isHidden = !failed
        if failed {
            place(placeholder, BadgeImages.placeholder(scale: scale)) {
                CGPoint(x: photo.midX - $0.width / 2, y: photo.midY - $0.height / 2)
            }
        }
    }
}

/// The badges' pictures, drawn once per text or symbol and screen scale, white with a soft dark shadow, so a tile
/// shows them without laying out text or rendering a shadow every frame.
@MainActor enum BadgeImages {
    struct Picture {
        var image: CGImage
        /// In points, shadow margin included.
        var size: CGSize
    }

    /// Room around each picture for its shadow.
    static let margin: CGFloat = 3
    private static var cache: [String: Picture] = [:]

    static func text(_ text: String, scale: CGFloat) -> Picture? {
        picture("t|\(text)|\(scale)", scale: scale) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            return (string.size(), { string.draw(at: $0) })
        }
    }

    static func symbol(_ name: String, scale: CGFloat) -> Picture? {
        picture("s|\(name)|\(scale)", scale: scale) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            else { return (.zero, { _ in }) }
            let side: CGFloat = 13
            let size = image.size.width > image.size.height
                ? CGSize(width: side, height: side * image.size.height / image.size.width)
                : CGSize(width: side * image.size.width / image.size.height, height: side)
            return (size, { image.draw(in: CGRect(origin: $0, size: size)) })
        }
    }

    /// A month's label in the mosaic: "Jun 2019", white on a dark capsule.
    static func pill(_ text: String, scale: CGFloat) -> Picture? {
        picture("m|\(text)|\(scale)", scale: scale, shadow: false) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            let size = CGSize(width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 8)
            return (size, { origin in
                let capsule = NSBezierPath(roundedRect: CGRect(origin: origin, size: size), xRadius: size.height / 2, yRadius: size.height / 2)
                NSColor.black.withAlphaComponent(0.55).setFill()
                capsule.fill()
                string.draw(at: CGPoint(x: origin.x + 10, y: origin.y + 4))
            })
        }
    }

    static func placeholder(scale: CGFloat) -> Picture? {
        picture("p|\(scale)", scale: scale, shadow: false) {
            guard let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 24, weight: .regular).applying(.init(paletteColors: [.tertiaryLabelColor])))
            else { return (.zero, { _ in }) }
            return (image.size, { image.draw(in: CGRect(origin: $0, size: image.size)) })
        }
    }

    private static func picture(
        _ key: String, scale: CGFloat, shadow: Bool = true, make: () -> (CGSize, (CGPoint) -> Void)
    ) -> Picture? {
        if let cached = cache[key] { return cached }
        let (content, draw) = make()
        guard content.width > 0, content.height > 0 else { return nil }
        let size = CGSize(width: ceil(content.width) + 2 * margin, height: ceil(content.height) + 2 * margin)
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if shadow {
            let s = NSShadow()
            s.shadowBlurRadius = 2
            s.shadowOffset = .zero
            s.shadowColor = NSColor.black.withAlphaComponent(0.7)
            s.set()
        }
        draw(CGPoint(x: margin, y: margin))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        let picture = Picture(image: image, size: size)
        cache[key] = picture
        return picture
    }
}
