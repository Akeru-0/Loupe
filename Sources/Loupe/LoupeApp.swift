import LoupeUI
import Sparkle
import SwiftUI

@main
struct LoupeApp: App {
    private let model: AppModel

    init() {
        model = AppModel()
        // Only the installed app updates itself: a development build has no feed and isn't in an app bundle that
        // Sparkle could replace.
        if Bundle.main.bundleURL.pathExtension == "app", Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            model.updater = SparkleUpdater()
        }
        model.launch()
    }

    var body: some Scene {
        Window("Loupe", id: "main") {
            RootView(model: model)
        }
        .commands {
            LoupeCommands(model: model)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updater?.checkForUpdates() }
                    .disabled(model.updater == nil)
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

/// Sparkle's standard updater: checks the appcast on GitHub, shows its own update window, verifies the EdDSA
/// signature and replaces the app.
@MainActor final class SparkleUpdater: AppUpdater {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
