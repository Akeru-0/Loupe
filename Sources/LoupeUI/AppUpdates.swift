import SwiftUI

/// Updates for the installed app, provided by the app target (Sparkle) and shown in Settings ▸ Updates and the
/// app menu. Absent in development builds.
@MainActor public protocol AppUpdater: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

/// Settings ▸ Updates.
struct UpdatesSection: View {
    var model: AppModel
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let automatic: State<Bool>

    init(model: AppModel) {
        self.model = model
        automatic = State(initialValue: model.updater?.automaticallyChecksForUpdates ?? true)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: version)
            if let updater = model.updater {
                Toggle("Check for updates automatically", isOn: automatic.projectedValue)
                    .onChange(of: automatic.wrappedValue) { _, on in updater.automaticallyChecksForUpdates = on }
                HStack {
                    Text("New versions are downloaded from GitHub and checked against Loupe's signing key before "
                        + "they're installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                }
            } else {
                Text("Updates work in the installed app (Applications), not in development builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
