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
    private let deleteFromCard: State<Bool>

    public init(model: AppModel) {
        self.model = model
        markers = State(initialValue: model.settings.editMarkers.joined(separator: "\n"))
        exclusions = State(initialValue: model.settings.excludedFolderNames.joined(separator: "\n"))
        editor = State(initialValue: EditorPreferences.defaultEditor)
        removeLocation = State(initialValue: SharePreferences.removeLocation)
        deleteFromCard = State(initialValue: model.preferences.bool(forKey: ImportModel.deleteSourcesKey) ?? false)
    }

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { page { librarySection } }
            Tab("Import", systemImage: "square.and.arrow.down") {
                page {
                    ApplePhotosSection(model: model, importer: model.applePhotosImport)
                    cardsSection
                }
            }
            Tab("Faces", systemImage: "person.crop.square") { page { FacesSection(model: model, faceModel: model.faceModel) } }
            Tab("Cloud", systemImage: "icloud") { page { cloudSection } }
            Tab("Editing", systemImage: "pencil") { page { editingSection } }
            Tab("Sharing", systemImage: "square.and.arrow.up") { page { sharingSection } }
        }
        .frame(width: 560)
    }

    /// One settings tab: a grouped form, as tall as its content.
    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Sections

    @ViewBuilder private var librarySection: some View {
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
    }

    private var cardsSection: some View {
        Section("Camera Cards") {
            Toggle("Delete from card after import", isOn: deleteFromCard.projectedValue)
                .onChange(of: deleteFromCard.wrappedValue) { _, on in
                    model.preferences.set(on, forKey: ImportModel.deleteSourcesKey)
                }
            Text("Each photo is deleted from the card once its copy in the library is verified. Also in the import "
                + "window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var editingSection: some View {
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
    }

    private var cloudSection: some View {
        Section("Cloud Upload") {
            LabeledContent("Upload to") {
                HStack {
                    Text(model.uploadFolder?.path ?? "Off")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.uploadFolder?.path ?? "")
                    Button("Choose…", action: chooseUploadFolder)
                    if model.uploadFolder != nil { Button("Turn Off") { model.setUploadFolder(nil) } }
                }
            }
            if model.uploadFolder != nil {
                HStack {
                    Text(uploadStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Upload Now") { model.scheduleUpload() }
                        .disabled(isUploading)
                }
            }
            Text("Pick a folder your sync app uploads: iCloud Drive, Dropbox, Google Drive, OneDrive or a NAS share. "
                + "Every photo is copied there into its album's folder and checked byte for byte; photos that "
                + "fail show in Unable to Upload. Deleting a photo in Loupe doesn't delete its upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sharingSection: some View {
        Section("Sharing") {
            Toggle("Remove location when sharing", isOn: removeLocation.projectedValue)
                .onChange(of: removeLocation.wrappedValue) { _, on in SharePreferences.removeLocation = on }
        }
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

    private var isUploading: Bool { if case .running = model.uploadStatus { true } else { false } }

    private var uploadStatusText: String {
        switch model.uploadStatus {
        case .off: return ""
        case .running(let done, let total):
            return total == 0 ? "Checking what to upload…" : "Uploading… \(done.formatted()) of \(total.formatted()) files checked"
        case .finished(let report, let at):
            var text = report.failed == 0 ? "Up to date" : "\(report.failed.formatted()) files couldn't be uploaded (see Unable to Upload)"
            if report.uploaded > 0 { text += " · \(report.uploaded.formatted()) uploaded" }
            text += " · \(at.formatted(date: .omitted, time: .shortened))"
            if let first = report.firstFailure { text += "\n" + first }
            return text
        case .unavailable(let message): return message
        }
    }

    private func chooseUploadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        panel.directoryURL = model.uploadFolder
            ?? (FileManager.default.fileExists(atPath: iCloud.path) ? iCloud : nil)
        panel.message = "Choose a folder your sync app uploads (iCloud Drive, Dropbox, a NAS share…)."
        panel.prompt = "Upload Here"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.setUploadFolder(url)
        }
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
