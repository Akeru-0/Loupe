import LoupeUI
import SwiftUI

@main
struct LoupeApp: App {
    private let model: AppModel

    init() {
        model = AppModel()
        model.launch()
    }

    var body: some Scene {
        Window("Loupe", id: "main") {
            RootView(model: model)
        }
        .commands { LoupeCommands(model: model) }
        Settings {
            SettingsView(model: model)
        }
    }
}
