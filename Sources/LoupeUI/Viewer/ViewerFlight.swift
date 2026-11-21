import AppKit
import SwiftUI

/// A photo flying between its grid tile and the viewer as the viewer opens or closes. Rects are in the window's
/// content coordinates with the origin at the top left, as SwiftUI's global coordinate space.
struct ViewerFlight {
    let id = UUID()
    let photoID: Int64
    /// What flies; nil (a video, a photo still loading) only fades the viewer.
    let image: CGImage?
    let from: CGRect
    /// Where a flight back to the grid lands: the tile's photo, or nil to fade out in place.
    var to: CGRect?
    /// The grid has set `to` (or found no tile to land on).
    var isAimed = false

    static let duration = 0.3
    static let animation = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: duration)

    /// Off under Reduce Motion: the viewer then opens and closes at once.
    @MainActor static var isEnabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Where the viewer draws a photo of `pixelSize` at fit in `area`: centred and never above 100 %, as
    /// `ZoomScrollView` does.
    static func fitRect(pixelSize: CGSize, in area: CGRect, scale: CGFloat) -> CGRect {
        let doc = CGSize(width: max(1, pixelSize.width / scale), height: max(1, pixelSize.height / scale))
        let fit = min(1, area.width / doc.width, area.height / doc.height)
        let size = CGSize(width: doc.width * fit, height: doc.height * fit)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }
}

extension NSView {
    /// `rect` (in this view) in the window's content coordinates with the origin at the top left (`ViewerFlight`).
    func flightRect(_ rect: CGRect) -> CGRect? {
        guard let content = window?.contentView else { return nil }
        var r = content.convert(rect, from: self)
        if !content.isFlipped { r.origin.y = content.bounds.height - r.maxY }
        return r
    }
}

/// The flying photo at `rect`, given in global coordinates; place it in a view that fills its container.
struct FlightImage: View {
    let image: CGImage
    let rect: CGRect
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .position(x: rect.midX - origin.x, y: rect.midY - origin.y)
        }
        .allowsHitTesting(false)
    }
}

/// After the viewer closed itself: its photo flying back to the tile over a fading copy of the viewer's background.
/// Shown while `AppModel.viewerClosing` is set; the grid aims it.
struct ViewerLanding: View {
    var model: AppModel
    let flight: ViewerFlight
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let landed = State(initialValue: false)

    var body: some View {
        let landed = landed.wrappedValue
        let rect = landed ? (flight.to ?? flight.from) : flight.from
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(landed ? 0 : 1)
            if let image = flight.image {
                FlightImage(
                    image: image, rect: rect,
                    cornerRadius: landed && flight.to != nil ? PhotoCellView.cornerRadius(for: rect) : 0)
                    .opacity(landed && flight.to == nil ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: flight.isAimed, initial: true) { _, aimed in if aimed { land() } }
        .task {
            // The grid aims it within a turn; should it not (the photo left the grid), it just fades.
            try? await Task.sleep(for: .milliseconds(200))
            land()
        }
    }

    private func land() {
        guard !landed.wrappedValue else { return }
        withAnimation(ViewerFlight.animation) {
            landed.wrappedValue = true
        } completion: {
            if model.viewerClosing?.id == flight.id { model.viewerClosing = nil }
        }
    }
}
