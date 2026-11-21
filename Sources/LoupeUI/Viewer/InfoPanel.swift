import Foundation
import LoupeCore
import LoupeIndex
import LoupeMedia
import LoupeXMP
import Observation
import SwiftUI

/// The (i) panel for one photo, laid out like Photos' Info window: file name, date and favorite; the title and
/// caption (as Photos gave them); a card with the camera, lens, file facts and exposure; then rating, tags (opens the tag editor), albums and the file's path.
/// Used by the viewer and by the toolbar's Info popover. Everything is loaded off the main thread, again whenever
/// the library changes.
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
        ScrollView {
            if let content = info.content {
                VStack(alignment: .leading, spacing: 0) {
                    header(content)
                    Divider()
                    if content.title != nil || content.caption != nil {
                        row {
                            VStack(alignment: .leading, spacing: 4) {
                                if let title = content.title { Text(title).fontWeight(.semibold) }
                                if let caption = content.caption { Text(caption).foregroundStyle(.secondary) }
                            }
                            .textSelection(.enabled)
                        }
                        Divider()
                    }
                    if content.version != nil {
                        cameraCard(content).padding(12)
                        Divider()
                    }
                    if content.metadata.rating > 0 {
                        row { Text(String(repeating: "★", count: content.metadata.rating)) }
                        Divider()
                    }
                    Button { model.tagEditorPhotoIDs = [photoID] } label: {
                        row {
                            if content.metadata.tags.isEmpty {
                                Text("Add a Keyword").foregroundStyle(.tertiary)
                            } else {
                                Text(content.metadata.tags.joined(separator: ", "))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit Tags (⌘T)")
                    Divider()
                    if !content.metadata.albums.isEmpty {
                        row {
                            Label(content.metadata.albums.joined(separator: ", "), systemImage: "rectangle.stack")
                        }
                        Divider()
                    }
                    row {
                        Text(content.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 14))
            } else if info.isMissing {
                Text("Photo unavailable").foregroundStyle(.secondary).padding()
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: InfoPanelModel.Request(photoID: photoID, versionID: versionID, revision: info.revision)) {
            await info.load(photoID: photoID, versionID: versionID, library: model.library)
        }
        .onReceive(NotificationCenter.default.publisher(for: Library.didChange)) { _ in info.revision += 1 }
    }

    private func header(_ content: InfoPanelModel.Content) -> some View {
        let isFavorite = content.metadata.isFavorite
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(content.version == nil ? content.photo.stem : content.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button { setFavorite(!isFavorite) } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart").font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(isFavorite ? "Unfavorite" : "Favorite")
            }
            if let date = content.photo.captureDate {
                HStack(spacing: 14) {
                    Text(date.formatted(date: .long, time: .omitted))
                    Text(date.formatted(date: .omitted, time: .standard))
                }
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func cameraCard(_ content: InfoPanelModel.Content) -> some View {
        let exif = content.exif
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exif.camera ?? "Unknown Camera")
                        if let lens = exif.lens { Text(lens) }
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        if exif.flashFired { Image(systemName: "bolt.fill").help("Flash Fired") }
                        if let metering = exif.metering { Image(systemName: metering.symbol).help(metering.name) }
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    ForEach(Array(fileFacts(content).enumerated()), id: \.offset) { i, fact in
                        if i > 0 { Spacer(minLength: 10) }
                        Text(fact)
                    }
                    Spacer(minLength: 10)
                    Text(badge(content))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(12)
            if !exif.exposure.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    ForEach(Array(exif.exposure.enumerated()), id: \.offset) { i, value in
                        if i > 0 { Spacer(minLength: 6) }
                        Text(value)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    /// "18 MP", "3456 × 5184", "20.9 MB" (and a video's length).
    private func fileFacts(_ content: InfoPanelModel.Content) -> [String] {
        guard let version = content.version else { return [] }
        var facts: [String] = []
        if let w = version.pixelWidth, let h = version.pixelHeight, w > 0, h > 0 {
            let megapixels = Double(w * h) / 1_000_000
            if version.kind != .video, megapixels >= 1 { facts.append("\(Int(megapixels.rounded())) MP") }
            facts.append("\(w) × \(h)")
        }
        if let duration = version.duration {
            facts.append(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
        }
        facts.append(ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
        return facts
    }

    /// "RAW", or the file's extension ("JPG", "HEIC", "MOV").
    private func badge(_ content: InfoPanelModel.Content) -> String {
        content.version?.kind == .raw ? "RAW" : content.url.pathExtension.uppercased()
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
    }

    private func setFavorite(_ value: Bool) {
        guard let library = model.library else { return }
        let id = photoID
        Task {
            let errors = await library.apply([.setFavorite(value)], to: [id])
            if let error = errors.values.first { model.present(error) }
        }
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
        var exif: ExifSummary
        /// The sidecar's title and caption.
        var title: String?
        var caption: String?
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
        let sidecar = (try? index.groupFiles(ofPhoto: id, root: root))?.sidecar
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? XMPDocument(data: $0) }
        return Content(
            photo: photo, metadata: (try? index.metadata(ofPhoto: id)) ?? PhotoMetadata(), version: version, url: url,
            exif: version == nil ? ExifSummary() : ExifSummary(url: url), title: sidecar?.title, caption: sidecar?.caption)
    }
}
