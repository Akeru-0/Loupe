import AppKit
import LoupeCore
import LoupeIndex
import Observation
import SwiftUI

/// Utilities ▸ Duplicates: the duplicate sets, the copy the user keeps per set, and moving the other copies that
/// are fully redundant to the Trash (through `Library.trashRedundantCopies`, which checks again on disk).
@MainActor @Observable final class DuplicatesModel {
    enum CopyStatus: Equatable {
        /// No copy kept yet in this set.
        case undecided
        case kept
        /// Every media file has an identical copy in the kept photo: goes with "Move Other Copies to Trash".
        case removable
        /// Has a media file with no identical copy (in the kept photo, or in any one other copy): never trashed here.
        case notRemovable
    }

    let app: AppModel
    private(set) var sets: [DuplicateSet] = []
    private(set) var cells: [Int64: CellInfo] = [:]
    private(set) var isLoading = true
    /// Files hashed so far by the running duplicate check, while there is one.
    private(set) var progress: (done: Int, total: Int)?
    /// The photo kept per set (set id → photo id).
    var kept: [Int64: Int64] = [:]
    /// The set whose other copies wait for the confirmation.
    var confirming: DuplicateSet?

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false

    init(app: AppModel) { self.app = app }

    /// Loads now and again whenever the library or its duplicates change, until `stop()`.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Library.didChange, Library.duplicatesDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.load() }
            })
        }
        observers.append(center.addObserver(forName: Library.duplicatesProgress, object: nil, queue: .main) {
            [weak self] note in
            let done = note.userInfo?["done"] as? Int ?? 0, total = note.userInfo?["total"] as? Int ?? 0
            MainActor.assumeIsolated {
                guard let self, let library = self.app.library, note.object as AnyObject? === library else { return }
                self.progress = done < total ? (done, total) : nil
            }
        })
        load()
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        loadTask?.cancel()
        loadTask = nil
    }

    /// Reads the sets and their cells off the main actor; coalesces bursts.
    func load() {
        guard let library = app.library else { return }
        if loadTask != nil {
            reloadPending = true
            return
        }
        let index = library.index, root = library.location.rootURL
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> ([DuplicateSet], [Int64: CellInfo]) in
                    let sets = try index.duplicateSets()
                    return (sets, try index.cellInfo(ids: sets.flatMap { $0.copies.map(\.photoId) }, root: root))
                }
            }.value
            guard let self else { return }
            loadTask = nil
            if app.library === library {
                switch result {
                case .success(let (sets, cells)):
                    self.sets = sets
                    self.cells = cells
                    // A kept photo that left its set (trashed, moved away) is forgotten.
                    kept = kept.filter { setID, photo in sets.contains { $0.id == setID && $0.copies.contains { $0.photoId == photo } } }
                case .failure(let error):
                    app.log("Could not load the duplicates: \(error.localizedDescription)")
                }
                isLoading = false
            }
            if reloadPending {
                reloadPending = false
                load()
            }
        }
    }

    func status(of copy: DuplicateSet.Copy, in set: DuplicateSet) -> CopyStatus {
        Self.status(of: copy, in: set, kept: kept[set.id])
    }

    nonisolated static func status(of copy: DuplicateSet.Copy, in set: DuplicateSet, kept: Int64?) -> CopyStatus {
        guard let kept else { return copy.redundant ? .undecided : .notRemovable }
        if copy.photoId == kept { return .kept }
        return set.removable(keeping: kept).contains(copy.photoId) ? .removable : .notRemovable
    }

    var reclaimableBytes: Int64 { sets.reduce(0) { $0 + $1.reclaimableBytes } }

    /// Asks before moving the set's removable copies to the Trash.
    func askToTrash(_ set: DuplicateSet) {
        guard let keptID = kept[set.id], !set.removable(keeping: keptID).isEmpty else { return }
        confirming = set
    }

    /// After the confirmation. The library checks every copy again on disk and refuses any with files of its own.
    func trashConfirmed() {
        guard let set = confirming, let keptID = kept[set.id], let library = app.library else { return }
        confirming = nil
        let ids = set.removable(keeping: keptID)
        let names = Dictionary(uniqueKeysWithValues: set.copies.map { ($0.photoId, $0.stem) })
        Task {
            let errors = await library.trashRedundantCopies(keeping: keptID, others: ids)
            PhotoGridController.presentErrors(errors, "Couldn't move to the Trash", names: names, model: app)
            load()
        }
    }

    // MARK: - Texts

    nonisolated static func summary(sets: Int, reclaimable: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)
        return "\(sets) duplicate set\(sets == 1 ? "" : "s"), \(size) reclaimable"
    }

    /// A folder path as the sidebar shows it: `""` is the top of the library, ":" on disk is "/" in Finder.
    nonisolated static func folderName(_ folder: String) -> String {
        guard !folder.isEmpty else { return "Library" }
        return folder.split(separator: "/").map { $0.replacingOccurrences(of: ":", with: "/") }.joined(separator: " ▸ ")
    }

    nonisolated static func trashQuestion(count: Int) -> String {
        "Move \(count) photo\(count == 1 ? "" : "s") to Trash?"
    }

    nonisolated static func trashDetail(kept: DuplicateSet.Copy, count: Int) -> String {
        let what = count == 1 ? "It's an identical copy" : "They're identical copies"
        let back = count == 1 ? "it" : "them"
        return "\(what) of “\(kept.stem)” in \(folderName(kept.folder)), which stays. "
            + "You can put \(back) back from the Trash in Finder."
    }
}

/// Shown for Utilities ▸ Duplicates instead of the grid.
struct DuplicatesView: View {
    var model: AppModel
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let duplicates: State<DuplicatesModel>

    init(model: AppModel) {
        self.model = model
        duplicates = State(initialValue: DuplicatesModel(app: model))
    }

    var body: some View {
        let duplicates = duplicates.wrappedValue
        Group {
            if duplicates.sets.isEmpty {
                ContentUnavailableView {
                    Label("No Duplicates", systemImage: "square.on.square")
                } description: {
                    Text(duplicates.isLoading || duplicates.progress != nil
                        ? "Checking for identical copies…" : "No photo has an identical copy in the library.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(duplicates.sets) { set in
                            DuplicateSetView(set: set, duplicates: duplicates)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) { header(duplicates) }
        .confirmationDialog(
            DuplicatesModel.trashQuestion(count: confirmCount(duplicates)),
            isPresented: Binding(get: { duplicates.confirming != nil }, set: { if !$0 { duplicates.confirming = nil } }),
            presenting: duplicates.confirming
        ) { _ in
            Button("Move to Trash", role: .destructive) { duplicates.trashConfirmed() }
            Button("Cancel", role: .cancel) { duplicates.confirming = nil }
        } message: { set in
            if let keptID = duplicates.kept[set.id], let kept = set.copies.first(where: { $0.photoId == keptID }) {
                Text(DuplicatesModel.trashDetail(kept: kept, count: set.removable(keeping: keptID).count))
            }
        }
        .onAppear { duplicates.start() }
        .onDisappear { duplicates.stop() }
        .onChange(of: model.library === nil) { duplicates.load() }
    }

    private func confirmCount(_ duplicates: DuplicatesModel) -> Int {
        guard let set = duplicates.confirming, let keptID = duplicates.kept[set.id] else { return 0 }
        return set.removable(keeping: keptID).count
    }

    private func header(_ duplicates: DuplicatesModel) -> some View {
        HStack(spacing: 8) {
            if !duplicates.sets.isEmpty {
                Text(DuplicatesModel.summary(sets: duplicates.sets.count, reclaimable: duplicates.reclaimableBytes))
                    .font(.headline)
            }
            Spacer(minLength: 0)
            if let p = duplicates.progress {
                ProgressView().controlSize(.small)
                Text("Checking \(p.done.formatted()) of \(p.total.formatted()) files…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// One set: a card per copy, then the action.
private struct DuplicateSetView: View {
    let set: DuplicateSet
    let duplicates: DuplicatesModel

    var body: some View {
        let keptID = duplicates.kept[set.id]
        let removable = keptID.map { set.removable(keeping: $0) } ?? []
        VStack(alignment: .leading, spacing: 10) {
            Text("\(set.copies.first?.stem ?? "") · \(set.copies.count) copies")
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(set.copies, id: \.photoId) { copy in
                        DuplicateCopyView(
                            copy: copy, cell: duplicates.cells[copy.photoId], library: duplicates.app.library,
                            status: duplicates.status(of: copy, in: set)
                        ) {
                            duplicates.kept[set.id] = copy.photoId
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            HStack {
                Button("Move Other Copies to Trash") { duplicates.askToTrash(set) }
                    .disabled(removable.isEmpty)
                if keptID == nil {
                    Text("Choose the copy to keep.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DuplicateCopyView: View {
    let copy: DuplicateSet.Copy
    let cell: CellInfo?
    let library: Library?
    let status: DuplicatesModel.CopyStatus
    let keep: () -> Void
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let image: State<CGImage?>

    init(
        copy: DuplicateSet.Copy, cell: CellInfo?, library: Library?, status: DuplicatesModel.CopyStatus,
        keep: @escaping () -> Void
    ) {
        self.copy = copy
        self.cell = cell
        self.library = library
        self.status = status
        self.keep = keep
        image = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
            Text(DuplicatesModel.folderName(copy.folder)).font(.callout.weight(.medium)).lineLimit(1)
            Text(copy.stem).font(.caption).lineLimit(1)
            Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            footer.font(.caption)
        }
        .frame(width: 180, alignment: .leading)
        .help(DuplicatesModel.folderName(copy.folder) + " ▸ " + copy.stem)
        .task(id: cell) { await loadImage() }
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: copy.bytes, countStyle: .file)
        guard let date = copy.captureDate else { return size }
        return size + " · " + date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let cg = image.wrappedValue {
                Image(decorative: cg, scale: 1).resizable().scaledToFit()
            }
        }
        .frame(width: 180, height: 135)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if status == .kept { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3) }
        }
    }

    @ViewBuilder private var footer: some View {
        switch status {
        case .kept:
            Label("Kept", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        case .removable:
            Button("Keep this one", action: keep)
            Text("Moves to the Trash").foregroundStyle(.secondary)
        case .undecided:
            Button("Keep this one", action: keep)
        case .notRemovable:
            Button("Keep this one", action: keep)
            Text("Has its own files — not removable here").foregroundStyle(.secondary)
        }
    }

    private func loadImage() async {
        guard let cell, let library else { return }
        let loaded = await library.thumbnails.thumbnail(for: cell.displayFile, kind: cell.displayKind, rotation: cell.rotation)
        if !Task.isCancelled { image.wrappedValue = loaded }
    }
}
