import AppKit
import LoupeCore
import LoupeFeatures
import SwiftUI

public struct SettingsView: View {
    var model: AppModel
    // `@State` is a macro in this SDK and its plugin ships only with Xcode, so the `State` values are spelled out.
    /// One entry per line; edits take effect on Apply, since they rescan the library.
    private let markers: State<String>
    private let exclusions: State<String>
    private let editor: State<URL?>
    private let removeLocation: State<Bool>

    public init(model: AppModel) {
        self.model = model
        markers = State(initialValue: model.settings.editMarkers.joined(separator: "\n"))
        exclusions = State(initialValue: model.settings.excludedFolderNames.joined(separator: "\n"))
        editor = State(initialValue: EditorPreferences.defaultEditor)
        removeLocation = State(initialValue: SharePreferences.removeLocation)
    }

    public var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Root folder") {
                    HStack {
                        Text(model.settings.rootPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.settings.rootPath)
                        Button("Choose…", action: chooseRoot)
                    }
                }
                if let override = model.rootOverride {
                    Text("This launch uses \(override) (-LoupeRoot).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Edit markers") { lines(markers.projectedValue) }
                LabeledContent("Excluded folders") { lines(exclusions.projectedValue) }
                HStack {
                    Text("One per line. Applying rescans the library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply", action: applyLibrary)
                        .disabled(edited == model.settings)
                }
            }
            Section("Editing") {
                LabeledContent("Default editor") {
                    HStack {
                        Text(editor.wrappedValue.map { FileManager.default.displayName(atPath: $0.path) } ?? "None")
                        Button("Choose…") {
                            Task {
                                guard let app = await model.chooseApplication() else { return }
                                EditorPreferences.defaultEditor = app
                                editor.wrappedValue = app
                            }
                        }
                        if editor.wrappedValue != nil {
                            Button("Clear") {
                                EditorPreferences.defaultEditor = nil
                                editor.wrappedValue = nil
                            }
                        }
                    }
                }
            }
            Section("Sharing") {
                Toggle("Remove location when sharing", isOn: removeLocation.projectedValue)
                    .onChange(of: removeLocation.wrappedValue) { _, on in SharePreferences.removeLocation = on }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lines(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body.monospaced())
            .frame(height: 64)
    }

    /// The settings with the edited markers and exclusions; spaces are kept (" (edited" starts with one).
    private var edited: LibrarySettings {
        var s = model.settings
        s.editMarkers = markers.wrappedValue.components(separatedBy: .newlines).filter { !$0.isEmpty }
        s.excludedFolderNames = exclusions.wrappedValue.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return s
    }

    private func applyLibrary() {
        model.updateSettings(edited)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: model.settings.rootPath, isDirectory: true)
        panel.message = "Choose the folder Loupe shows."
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            var s = model.settings
            s.rootPath = url.path
            model.updateSettings(s)
        }
    }
}
