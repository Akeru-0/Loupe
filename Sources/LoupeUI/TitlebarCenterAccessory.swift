import AppKit
import SwiftUI

/// Places a SwiftUI view at the horizontal centre of the window's title bar, on the same row as the traffic
/// lights. SwiftUI's `.principal` toolbar placement centres in the detail column of a split view instead, which
/// shifts with the sidebar width.
struct TitlebarCenterAccessory<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in context.coordinator.attach(to: view?.window, content: content) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let hosting = context.coordinator.hosting {
            hosting.rootView = AnyView(content)
        } else {
            DispatchQueue.main.async { [weak nsView] in context.coordinator.attach(to: nsView?.window, content: content) }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.hosting?.removeFromSuperview()
        coordinator.hosting = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var hosting: NSHostingView<AnyView>?

        func attach(to window: NSWindow?, content: Content) {
            guard hosting == nil, let window,
                  let closeButton = window.standardWindowButton(.closeButton),
                  let titlebar = closeButton.superview else { return }
            let hosting = NSHostingView(rootView: AnyView(content))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
                hosting.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            ])
            self.hosting = hosting
        }
    }
}
