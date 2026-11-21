import AppKit
import SwiftUI

/// Places a SwiftUI view at the horizontal centre of the window's title bar, on the same row as the traffic
/// lights. SwiftUI's `.principal` toolbar placement centres in the detail column of a split view instead, which
/// shifts with the sidebar width. `offset` moves it off centre (negative: left).
struct TitlebarCenterAccessory<Content: View>: NSViewRepresentable {
    var offset: CGFloat = 0
    let content: Content

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            context.coordinator.attach(to: view?.window, content: content, offset: offset)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let hosting = context.coordinator.hosting {
            hosting.rootView = AnyView(content)
            context.coordinator.centerX?.constant = offset
        } else {
            DispatchQueue.main.async { [weak nsView] in
                context.coordinator.attach(to: nsView?.window, content: content, offset: offset)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.hosting?.removeFromSuperview()
        coordinator.hosting = nil
        coordinator.centerX = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var hosting: NSHostingView<AnyView>?
        var centerX: NSLayoutConstraint?

        func attach(to window: NSWindow?, content: Content, offset: CGFloat) {
            guard hosting == nil, let window,
                  let closeButton = window.standardWindowButton(.closeButton),
                  let titlebar = closeButton.superview else { return }
            let hosting = NSHostingView(rootView: AnyView(content))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(hosting)
            let centerX = hosting.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor, constant: offset)
            NSLayoutConstraint.activate([centerX, hosting.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)])
            self.centerX = centerX
            self.hosting = hosting
        }
    }
}
