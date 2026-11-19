import LoupeCore
import LoupeIndex
import SwiftUI

/// What several photos have in common, for the Info popover.
struct InfoSummary: Equatable {
    var count = 0
    /// nil when they differ.
    var rating: Int?
    var sharedTags: [String] = []

    init(metadata: [PhotoMetadata]) {
        count = metadata.count
        let ratings = Set(metadata.map(\.rating))
        rating = ratings.count == 1 ? ratings.first : nil
        sharedTags = TagEditorModel.tokens(perPhoto: metadata.map(\.tags)).filter(\.onAll).map(\.name)
    }
}

/// The toolbar's Info popover: the photo's `InfoPanel`, or for several photos their count with the rating and
/// tags they share. It follows the targets while open.
struct InfoPopover: View {
    var model: AppModel

    var body: some View {
        let ids = model.actionTargetIDs
        Group {
            if ids.count == 1, let id = ids.first {
                let focused = model.viewerFocusedVersion.flatMap { $0.photoId == id ? $0.id : nil }
                InfoPanel(model: model, photoID: id, versionID: focused)
            } else if ids.count > 1 {
                InfoSummaryView(model: model, ids: ids)
            } else {
                Text("No photos selected").foregroundStyle(.secondary)
            }
        }
        .frame(width: 320, height: ids.count > 1 ? 200 : 440)
    }
}

private struct InfoSummaryView: View {
    var model: AppModel
    var ids: [Int64]
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let summary: State<InfoSummary?>
    private let revision: State<Int>

    init(model: AppModel, ids: [Int64]) {
        self.model = model
        self.ids = ids
        summary = State(initialValue: nil)
        revision = State(initialValue: 0)
    }

    private struct Request: Equatable {
        var ids: [Int64]
        var revision: Int
    }

    var body: some View {
        Form {
            Section {
                Text("\(ids.count.formatted()) photos").font(.headline)
            }
            if let summary = summary.wrappedValue {
                Section("Library") {
                    LabeledContent("Rating", value: summary.rating.map { $0 > 0 ? String(repeating: "★", count: $0) : "None" } ?? "Mixed")
                    LabeledContent("Tags", value: summary.sharedTags.isEmpty ? "None in common" : summary.sharedTags.joined(separator: ", "))
                }
            }
        }
        .formStyle(.grouped)
        .task(id: Request(ids: ids, revision: revision.wrappedValue)) {
            guard let index = model.library?.index else { return }
            let loaded = await Self.read(ids, index: index)
            guard !Task.isCancelled, let loaded else { return }
            summary.wrappedValue = loaded
        }
        .onReceive(NotificationCenter.default.publisher(for: Library.didChange)) { _ in revision.wrappedValue += 1 }
    }

    @concurrent nonisolated private static func read(_ ids: [Int64], index: LibraryIndex) async -> InfoSummary? {
        var metadata: [PhotoMetadata] = []
        metadata.reserveCapacity(ids.count)
        for id in ids {
            guard !Task.isCancelled else { return nil }
            if let m = try? index.metadata(ofPhoto: id) { metadata.append(m) }
        }
        return InfoSummary(metadata: metadata)
    }
}
