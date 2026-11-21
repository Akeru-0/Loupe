import AppKit
import SwiftUI

/// Keeps the sidebar's list from taking keyboard focus, so its selection always shows the quiet grey highlight
/// rather than the accent-blue one a focused list draws. Clicks still select; the keyboard stays with the grid.
/// Placed inside a row, it finds the list's table among its ancestors.
struct SidebarFocusRefuser: NSViewRepresentable {
    func makeNSView(context: Context) -> RefuserView { RefuserView() }
    func updateNSView(_ view: RefuserView, context: Context) {}

    final class RefuserView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView, !table.refusesFirstResponder else { return }
            table.refusesFirstResponder = true
            if let window, window.firstResponder === table { window.makeFirstResponder(nil) }
        }
    }
}
