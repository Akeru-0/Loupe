import AppKit
import SwiftUI

/// The viewer's still image in a magnifying scroll view.
struct ZoomableImageView: NSViewRepresentable {
    let image: CGImage?
    /// The focused version's full size in pixels; magnification 1 shows it at 100 %.
    let pixelSize: CGSize
    /// What is shown; when it changes the zoom goes back to fit.
    let content: AnyHashable
    let viewer: PhotoViewerModel

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onZoomBeyondFit = { [weak viewer] in viewer?.requestFullResolution() }
        viewer.zoomView = view
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.show(image, pixelSize: pixelSize, content: content)
    }
}

/// An `NSScrollView` whose document is the image at its full pixel size (in points: pixels / backing scale),
/// so magnification 1 is 100 %. It starts (and, until zoomed, stays across resizes) at fit; double-click toggles
/// fit and 100 %.
final class ZoomScrollView: NSScrollView {
    /// Called when the magnification goes beyond fit, so a full-resolution image can be loaded.
    var onZoomBeyondFit: (() -> Void)?

    private let imageView = ImageLayerView()
    private var pixelSize = CGSize(width: 1, height: 1)
    private var content: AnyHashable?
    private var isAtFit = true

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        documentView = imageView
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: CGImage?, pixelSize: CGSize, content: AnyHashable) {
        imageView.image = image
        let newContent = content != self.content
        guard newContent || pixelSize != self.pixelSize else { return }
        self.content = content
        self.pixelSize = pixelSize
        if newContent { isAtFit = true }
        updateGeometry()
    }

    private var documentSize: CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: max(1, pixelSize.width / scale), height: max(1, pixelSize.height / scale))
    }

    /// The magnification that shows the whole image; never above 100 %.
    private var fitMagnification: CGFloat {
        let doc = documentSize, clip = contentSize
        guard clip.width > 0, clip.height > 0 else { return 1 }
        return min(1, clip.width / doc.width, clip.height / doc.height)
    }

    private func updateGeometry() {
        imageView.frame = CGRect(origin: .zero, size: documentSize)
        let fit = fitMagnification
        minMagnification = fit
        maxMagnification = max(4, fit)
        if isAtFit { magnification = fit }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        let fit = fitMagnification
        if magnification > fit + 0.001 {
            magnification = fit
        } else {
            setMagnification(1, centeredAt: imageView.convert(event.locationInWindow, from: nil))
        }
        magnificationChanged()
    }

    /// ⌘+ / ⌘−: steps around the visible center.
    func zoom(by factor: CGFloat) {
        let target = min(maxMagnification, max(minMagnification, magnification * factor))
        let visible = contentView.documentVisibleRect
        setMagnification(target, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        magnificationChanged()
    }

    @objc private func liveMagnifyEnded(_ note: Notification) { magnificationChanged() }

    private func magnificationChanged() {
        let fit = fitMagnification
        isAtFit = abs(magnification - fit) < 0.001
        if magnification > fit + 0.001 { onZoomBeyondFit?() }
    }
}

/// Keeps the document centered while it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Shows a `CGImage` as its layer's contents, scaled to the view.
final class ImageLayerView: NSView {
    var image: CGImage? {
        didSet { if image !== oldValue { needsDisplay = true } }
    }

    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.contentsGravity = .resizeAspect
        layer?.contents = image
    }
}
