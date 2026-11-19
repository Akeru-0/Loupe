import Foundation
import LoupeCore
import LoupeIndex
import LoupeMedia
import Observation
import SwiftUI

/// The (i) panel for one photo: name, date, camera, the file, rating, tags and albums. Used by the viewer and by
/// the toolbar's Info popover. Everything is loaded off the main thread, again whenever the library changes.
struct InfoPanel: View {
    var model: AppModel
    var photoID: Int64
    /// The version whose file is described; nil for the photo's display version.
    var versionID: Int64?
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let info: State<InfoPanelModel>

    init(model: AppModel, photoID: Int64, versionID: Int64? = nil) {
        self.model = model
        self.photoID = photoID
        self.versionID = versionID
        info = State(initialValue: InfoPanelModel())
    }

    var body: some View {
        let info = info.wrappedValue
        Form {
            if let content = info.content {
                Section {
                    Text(content.photo.stem).font(.headline)
                    if let date = content.photo.captureDate {
                        LabeledContent("Taken", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if !content.exifLines.isEmpty {
                    Section("Camera") {
                        ForEach(Array(content.exifLines.enumerated()), id: \.offset) { _, line in
                            LabeledContent(line.label, value: line.value)
                        }
                    }
                }
                if let version = content.version {
                    Section("File") {
                        if let w = version.pixelWidth, let h = version.pixelHeight {
                            LabeledContent("Dimensions", value: "\(w) × \(h)")
                        }
                        LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
                        LabeledContent("Path") {
                            Text(content.url.path)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section("Library") {
                    let rating = content.metadata.rating
                    LabeledContent("Rating", value: rating > 0 ? String(repeating: "★", count: rating) : "None")
                    LabeledContent("Tags", value: content.metadata.tags.isEmpty ? "None" : content.metadata.tags.joined(separator: ", "))
                    LabeledContent("Albums", value: content.metadata.albums.isEmpty ? "None" : content.metadata.albums.joined(separator: ", "))
                }
            } else if info.isMissing {
                Text("Photo unavailable").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: InfoPanelModel.Request(photoID: photoID, versionID: versionID, revision: info.revision)) {
            await info.load(photoID: photoID, versionID: versionID, library: model.library)
        }
        .onReceive(NotificationCenter.default.publisher(for: Library.didChange)) { _ in info.revision += 1 }
    }
}

/// `InfoPanel`'s state. The previous photo's content stays up until the next one is loaded.
@MainActor @Observable final class InfoPanelModel {
    struct Request: Equatable {
        var photoID: Int64
        var versionID: Int64?
        var revision: Int
    }

    struct Content: Sendable {
        var photo: PhotoRecord
        var metadata: PhotoMetadata
        var version: VersionRecord?
        var url: URL
        var exifLines: [(label: String, value: String)]
    }

    private(set) var content: Content?
    private(set) var isMissing = false
    /// Bumped on `Library.didChange` to load again.
    var revision = 0

    func load(photoID: Int64, versionID: Int64?, library: Library?) async {
        guard let library else { return }
        let loaded = await Self.read(photoID, versionID: versionID, index: library.index, root: library.location.rootURL)
        guard !Task.isCancelled else { return }
        content = loaded
        isMissing = loaded == nil
    }

    @concurrent nonisolated private static func read(
        _ id: Int64, versionID: Int64?, index: LibraryIndex, root: URL
    ) async -> Content? {
        guard let photo = try? index.photo(id: id), let versions = try? index.versions(ofPhoto: id) else { return nil }
        let version = versions.first { $0.id == versionID && versionID != nil }
            ?? versions.first(where: \.isDisplay) ?? versions.first
        guard !Task.isCancelled else { return nil }
        let url = version?.url(in: root) ?? root
        return Content(
            photo: photo, metadata: (try? index.metadata(ofPhoto: id)) ?? PhotoMetadata(), version: version, url: url,
            exifLines: version == nil ? [] : ExifSummary.lines(for: url))
    }
}
