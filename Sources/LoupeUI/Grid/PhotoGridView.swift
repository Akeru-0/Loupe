import SwiftUI

/// Hosts the AppKit photo grid; all state flows through `AppModel`.
struct PhotoGridView: NSViewControllerRepresentable {
    let model: AppModel

    func makeNSViewController(context: Context) -> PhotoGridController {
        PhotoGridController(model: model)
    }

    func updateNSViewController(_ controller: PhotoGridController, context: Context) {}
}
