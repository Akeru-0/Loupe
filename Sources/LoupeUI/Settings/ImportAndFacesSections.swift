import AppKit
import LoupeCore
import LoupeFaces
import LoupeImport
import SwiftUI

/// Settings ▸ Import ▸ Apple Photos: which Photos library, where its photos go, and the import itself with its
/// progress and result.
struct ApplePhotosSection: View {
    var model: AppModel
    var importer: ApplePhotosImport
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let library: State<URL>
    private let confirming: State<Bool>

    init(model: AppModel, importer: ApplePhotosImport) {
        self.model = model
        self.importer = importer
        library = State(initialValue: ApplePhotosExport.defaultLibrary)
        confirming = State(initialValue: false)
    }

    private var destination: URL {
        URL(fileURLWithPath: model.effectiveSettings.rootPath, isDirectory: true)
            .appendingPathComponent(LibrarySettings.photosFolderName, isDirectory: true)
    }

    var body: some View {
        Section("Apple Photos") {
            LabeledContent("Photos library") {
                HStack {
                    Text(FileManager.default.displayName(atPath: library.wrappedValue.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(library.wrappedValue.path)
                    Button("Choose…", action: chooseLibrary).disabled(importer.isRunning)
                }
            }
            LabeledContent("Copies to") {
                Text("\(LibrarySettings.photosFolderName) › year › date")
                    .help(destination.path)
            }
            status
            HStack(alignment: .firstTextBaseline) {
                Text("Copies originals, RAW files and edited versions, with favorites, keywords, albums and the "
                    + "people named in them. Running it again copies only what's new. The Photos library isn't changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if importer.isRunning {
                    Button("Cancel") { importer.cancel() }
                } else {
                    Button("Import…") { confirming.wrappedValue = true }
                        .disabled(!FileManager.default.fileExists(atPath: library.wrappedValue.path))
                }
            }
        }
        .alert("Import from Apple Photos?", isPresented: confirming.projectedValue) {
            Button("Import") { importer.start(library: library.wrappedValue, destination: destination) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos are copied into \(destination.path), so this needs about as much free space as the Photos "
                + "library (\(freeSpace) free now). It can take a while; Loupe can be used meanwhile."
                + (importer.isInstalled ? "" : " osxphotos, which does the copying, is installed first (needs "
                    + "Python 3.10 or later)."))
        }
    }

    @ViewBuilder private var status: some View {
        switch importer.phase {
        case .idle:
            EmptyView()
        case .preparing(let message):
            HStack {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case .exporting(let progress):
            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text("Copying \(progress.done.formatted()) of \(progress.total.formatted()) · \(progress.name)")
                        .font(.caption)
                        .monospacedDigit()
                }
            } else {
                ProgressView().controlSize(.small)
            }
        case .finished(let summary, let at):
            Label(Self.summaryText(summary, at: at),
                  systemImage: summary.errors == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout)
        case .failed(let message, let needsAccess):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                if needsAccess {
                    Text("Add Loupe in System Settings ▸ Privacy & Security ▸ Full Disk Access, turn it on, then "
                        + "quit and reopen Loupe and import again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Full Disk Access Settings") { ApplePhotosImport.openFullDiskAccessSettings() }
                } else if !importer.recentOutput.isEmpty {
                    Text(importer.recentOutput.suffix(3).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// "Done at 4:12 PM: 2,410 copied, 30 updated, 70 only in iCloud (not copied)."
    static func summaryText(_ s: ApplePhotosExport.Summary, at: Date) -> String {
        var parts = ["\(s.exported.formatted()) copied"]
        if s.updated > 0 { parts.append("\(s.updated.formatted()) updated") }
        if s.missing > 0 { parts.append("\(s.missing.formatted()) only in iCloud (not copied)") }
        if s.errors > 0 { parts.append("\(s.errors.formatted()) failed") }
        return "Done at \(at.formatted(date: .omitted, time: .shortened)): " + parts.joined(separator: ", ") + "."
    }

    private var freeSpace: String {
        let values = try? destination.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "photoslibrary") ?? .package]
        panel.directoryURL = library.wrappedValue.deletingLastPathComponent()
        panel.message = "Choose the Photos library to import."
        panel.begin { response in
            if response == .OK, let url = panel.url { library.wrappedValue = url }
        }
    }
}

/// Settings ▸ Faces: the downloadable recognition model, ONNX Runtime that runs it, the scan's progress, and whether
/// pets are grouped too.
struct FacesSection: View {
    var model: AppModel
    var faceModel: FaceRecognitionModel
    private let groupPets: State<Bool>

    init(model: AppModel, faceModel: FaceRecognitionModel) {
        self.model = model
        self.faceModel = faceModel
        groupPets = State(initialValue: model.groupsPets)
    }

    var body: some View {
        Section("Faces and Pets") {
            Text("Loupe finds faces, cats and dogs with macOS's built-in Vision, and tells people apart with the "
                + "\(FaceRecognitionModel.name) model (\(FaceRecognitionModel.license)), downloaded once. Everything "
                + "runs on this Mac; no photo or face leaves it. People and pets appear under People in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Recognition model") {
                HStack {
                    switch faceModel.state {
                    case .notInstalled:
                        Text("Not downloaded").foregroundStyle(.secondary)
                        Button("Download (\(ByteCountFormatter.string(fromByteCount: FaceRecognitionModel.expectedBytes, countStyle: .file)))") {
                            faceModel.download()
                        }
                    case .downloading:
                        ProgressView().controlSize(.small)
                        Text("Downloading…").foregroundStyle(.secondary)
                        Button("Cancel") { faceModel.cancelDownload() }
                    case .installed(let bytes):
                        Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            .help(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        Button("Remove") {
                            faceModel.remove()
                            model.cancelFaceScan()
                        }
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).lineLimit(2)
                        Button("Try Again") { faceModel.download() }
                    }
                }
            }
            LabeledContent("ONNX Runtime") {
                HStack {
                    if FaceScanner.runtimeInstalled {
                        Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        switch model.runtimeInstall {
                        case .installing:
                            ProgressView().controlSize(.small)
                            Text("Installing with Homebrew…").foregroundStyle(.secondary)
                        case .failed(let message):
                            Text(message).foregroundStyle(.red).lineLimit(2)
                            Button("Try Again") { model.installOnnxRuntime() }
                        case .idle:
                            Text("Not installed").foregroundStyle(.secondary)
                            Button("Install with Homebrew") { model.installOnnxRuntime() }
                        }
                    }
                }
            }
            .help("Runs the recognition model. Installed with Homebrew: brew install onnxruntime")
            if faceModel.isInstalled, FaceScanner.runtimeInstalled {
                HStack {
                    scanStatus
                    Spacer()
                    Button("Scan Now") { model.scheduleFaceScan() }
                        .disabled({ if case .scanning = model.faceScanStatus { true } else { false } }())
                }
            }
            Toggle("Group pets (cats and dogs)", isOn: groupPets.projectedValue)
                .onChange(of: groupPets.wrappedValue) { _, on in model.setGroupsPets(on) }
        }
        .onChange(of: faceModel.isInstalled) { _, installed in if installed { model.scheduleFaceScan() } }
    }

    @ViewBuilder private var scanStatus: some View {
        switch model.faceScanStatus {
        case .unavailable:
            Text("Not scanned yet").font(.caption).foregroundStyle(.secondary)
        case .scanning(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Scanning \(done.formatted()) of \(total.formatted()) photos…").font(.caption).monospacedDigit()
            }
        case .finished(let report, let at):
            Text("Up to date · \(report.groups.formatted()) people and pets · \(at.formatted(date: .omitted, time: .shortened))"
                + (report.scanned > 0 ? " · \(report.scanned.formatted()) photos scanned" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}
