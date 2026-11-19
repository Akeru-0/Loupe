import LoupeCore
import LoupeIndex
import Observation
import SwiftUI

/// A tag in the editor: on every edited photo, or (dimmed) only on some.
struct TagToken: Hashable, Identifiable {
    var name: String
    var onAll: Bool
    var id: String { name }
}

/// The tag editor's state for a fixed set of photos. Every change goes to all of them through `Library.apply`.
@MainActor @Observable final class TagEditorModel {
    let app: AppModel
    let photoIDs: [Int64]
    private(set) var tokens: [TagToken] = []
    private(set) var isLoading = true
    var draft = ""

    init(app: AppModel, photoIDs: [Int64]) {
        self.app = app
        self.photoIDs = photoIDs
    }

    static func tokens(perPhoto: [[String]]) -> [TagToken] {
        var counts: [String: Int] = [:]
        for tags in perPhoto { for tag in Set(tags) { counts[tag, default: 0] += 1 } }
        return counts
            .map { TagToken(name: $0.key, onAll: $0.value == perPhoto.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Favorite" and album keywords mean something else in the sidecar, so they can't be tags; nor can a name
    /// with `|`, which is a keyword path separator there.
    static func isValidTag(_ name: String) -> Bool {
        !name.isEmpty && name != Keywords.favorite && name != "Albums" && !name.hasPrefix(Keywords.albumPrefix)
            && !name.contains("|")
    }

    func load() {
        guard let index = app.library?.index else { return }
        let ids = photoIDs
        Task {
            let perPhoto = await Task.detached(priority: .userInitiated) {
                ids.map { (try? index.metadata(ofPhoto: $0).tags) ?? [] }
            }.value
            tokens = Self.tokens(perPhoto: perPhoto)
            isLoading = false
        }
    }

    func addDraft() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTag(name) else { return NSSound.beep() }
        draft = ""
        tokens.removeAll { $0.name == name }
        tokens.append(TagToken(name: name, onAll: true))
        tokens.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        apply(.addTag(name), "Couldn't add the tag “\(name)”")
    }

    func remove(_ token: TagToken) {
        tokens.removeAll { $0.name == token.name }
        apply(.removeTag(token.name), "Couldn't remove the tag “\(token.name)”")
    }

    /// Shows the change at once; on errors the tokens are reloaded from the index.
    private func apply(_ change: MetadataChange, _ failure: String) {
        guard let library = app.library else { return }
        let ids = photoIDs
        Task {
            let errors = await library.apply([change], to: ids)
            guard !errors.isEmpty else { return }
            let index = library.index
            let names = await Task.detached(priority: .userInitiated) {
                var names: [Int64: String] = [:]
                for id in errors.keys { if let photo = try? index.photo(id: id) { names[id] = photo.stem } }
                return names
            }.value
            PhotoGridController.presentErrors(errors, failure, names: names, model: app)
            load()
        }
    }
}

/// ⌘T: the tags of the selected photos as tokens. Tags on only some of them are dimmed; adding or removing a tag
/// changes every selected photo.
struct TagEditorView: View {
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let editor: State<TagEditorModel>
    private let dismiss: () -> Void

    init(model: AppModel, photoIDs: [Int64], dismiss: @escaping () -> Void) {
        editor = State(initialValue: TagEditorModel(app: model, photoIDs: photoIDs))
        self.dismiss = dismiss
    }

    var body: some View {
        let editor = editor.wrappedValue
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.photoIDs.count == 1 ? "Tags" : "Tags of \(editor.photoIDs.count) Photos")
                .font(.headline)
            Group {
                if editor.isLoading {
                    ProgressView().controlSize(.small)
                } else if editor.tokens.isEmpty {
                    Text("No tags").foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(editor.tokens) { token in
                            TagTokenView(token: token) { editor.remove(token) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            TextField("Add a tag and press Return", text: Binding(get: { editor.draft }, set: { editor.draft = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { editor.addDraft() }
                .disabled(editor.isLoading)
            if editor.tokens.contains(where: { !$0.onAll }) {
                Text("Dimmed tags are on some of the selected photos. Removing one removes it from all of them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { editor.load() }
    }
}

private struct TagTokenView: View {
    let token: TagToken
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(token.name).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove “\(token.name)”")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(token.onAll ? 0.25 : 0.08)))
        .opacity(token.onAll ? 1 : 0.5)
        .help(token.onAll ? token.name : "\(token.name) (on some of the selected photos)")
    }
}

/// Lays its subviews out in rows, wrapping at the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
        let width = frames.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(frames(width: bounds.width, subviews: subviews), subviews) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
