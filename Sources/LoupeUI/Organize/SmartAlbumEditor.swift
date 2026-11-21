import AppKit
import LoupeCore
import LoupeIndex
import SwiftUI

/// A smart album being made or changed (`AppModel.smartAlbumEditing`).
struct SmartAlbumEditing: Identifiable {
    var album: SmartAlbum
    var isNew: Bool
    var id: String { album.id }
}

/// File ▸ New Smart Album, and Edit Smart Album / Delete Smart Album in the sidebar. Smart albums are kept with the
/// library (`SmartAlbumStore`), so the sidebar is rebuilt after each change.
extension AppModel {
    var canMakeSmartAlbum: Bool { library != nil }

    func newSmartAlbum() {
        guard library != nil else { return }
        smartAlbumEditing = SmartAlbumEditing(
            album: SmartAlbum(name: "", rules: [SmartRule.starting(.photo)]), isNew: true)
    }

    func editSmartAlbum(_ item: SidebarItem) {
        guard case .smartAlbum(let album) = item.scope else { return }
        smartAlbumEditing = SmartAlbumEditing(album: album, isNew: false)
    }

    /// Saves the album and shows it.
    func saveSmartAlbum(_ album: SmartAlbum) {
        guard let root = library?.location.rootURL else { return }
        do {
            try SmartAlbumStore.upsert(album, root: root)
        } catch {
            return present(OrganizeError("Couldn't save the smart album “\(album.name)”: \(error.localizedDescription)"))
        }
        smartAlbumEditing = nil
        refreshSidebar()
        let id = "smart:\(album.id)"
        if selectedItemID?.hasSuffix(id) != true { selectedItemID = id }
    }

    /// Asks, then deletes the smart album (never its photos).
    func deleteSmartAlbum(_ item: SidebarItem) async {
        guard case .smartAlbum(let album) = item.scope, let root = library?.location.rootURL,
            let window = NSApp.keyWindow
        else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the smart album “\(album.name)”?"
        alert.informativeText = "Its photos stay in the library."
        alert.addButton(withTitle: "Delete Smart Album")
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
        do {
            try SmartAlbumStore.delete(id: album.id, root: root)
            refreshSidebar()
        } catch {
            present(OrganizeError("Couldn't delete “\(album.name)”: \(error.localizedDescription)"))
        }
    }
}

/// The smart album sheet, laid out like Photos': the name, "Match any/all of the following conditions", one row per
/// condition (field, comparison, value, − and +), and how many photos match as it stands.
struct SmartAlbumEditor: View {
    let model: AppModel
    let isNew: Bool
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let draft: State<SmartAlbum>
    private let choices: State<Choices>
    private let matching: State<Int?>

    /// The values the pickers offer, read from the index when the sheet opens.
    struct Choices: Sendable {
        var albums: [String] = []
        var keywords: [String] = []
        var people: [String] = []
    }

    init(model: AppModel, editing: SmartAlbumEditing) {
        self.model = model
        isNew = editing.isNew
        draft = State(initialValue: editing.album)
        choices = State(initialValue: Choices())
        matching = State(initialValue: nil)
    }

    private var album: Binding<SmartAlbum> { draft.projectedValue }

    var body: some View {
        let current = draft.wrappedValue
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Smart Album" : "Edit Smart Album").font(.headline)
            HStack {
                Text("Smart Album Name:")
                TextField("Name", text: album.name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Text("Match")
                Picker("Match", selection: album.matchAll) {
                    Text("any").tag(false)
                    Text("all").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                Text("of the following conditions:")
            }
            VStack(spacing: 8) {
                ForEach(current.rules.indices, id: \.self) { i in
                    RuleRow(
                        rule: Binding(
                            get: { draft.wrappedValue.rules.indices.contains(i) ? draft.wrappedValue.rules[i] : .starting(.photo) },
                            set: { if draft.wrappedValue.rules.indices.contains(i) { draft.wrappedValue.rules[i] = $0 } }),
                        choices: choices.wrappedValue, cameras: model.cameras, lenses: model.lenses,
                        canRemove: current.rules.count > 1,
                        remove: { draft.wrappedValue.rules.remove(at: i) },
                        add: { draft.wrappedValue.rules.insert(.starting(.photo), at: i + 1) })
                }
            }
            HStack {
                Text(countText(current)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { model.smartAlbumEditing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave(current))
            }
        }
        .padding(20)
        .frame(minWidth: 620)
        .task { await loadChoices() }
        .task(id: current) { await count(current) }
    }

    private func canSave(_ album: SmartAlbum) -> Bool {
        !album.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && album.rules.contains(where: \.isComplete)
    }

    private func save() {
        var album = draft.wrappedValue
        album.name = album.name.trimmingCharacters(in: .whitespacesAndNewlines)
        album.rules = album.rules.filter(\.isComplete)
        model.saveSmartAlbum(album)
    }

    private func countText(_ album: SmartAlbum) -> String {
        guard album.rules.contains(where: \.isComplete) else { return "Add a condition" }
        guard let n = matching.wrappedValue else { return "" }
        return n == 1 ? "1 photo matches" : "\(n.formatted()) photos match"
    }

    private func loadChoices() async {
        guard let index = model.library?.index else { return }
        choices.wrappedValue = await Task.detached(priority: .userInitiated) {
            Choices(albums: (try? index.albumRuleChoices()) ?? [], keywords: (try? index.allTags()) ?? [],
                    people: (try? index.personNames()) ?? [])
        }.value
    }

    private func count(_ album: SmartAlbum) async {
        guard let index = model.library?.index else { return }
        try? await Task.sleep(for: .milliseconds(200))  // typing a name or a number
        guard !Task.isCancelled else { return }
        let n = await Task.detached(priority: .userInitiated) {
            (try? index.sections(for: PhotoQuery(scope: .smartAlbum(album))))?.reduce(0) { $0 + $1.photoIDs.count }
        }.value
        if !Task.isCancelled { matching.wrappedValue = n }
    }
}

/// One condition: field, comparison, value, and − / + to remove it or add one after it.
private struct RuleRow: View {
    @Binding var rule: SmartRule
    let choices: SmartAlbumEditor.Choices
    let cameras: [String]
    let lenses: [String]
    let canRemove: Bool
    let remove: () -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: Binding(get: { rule.field }, set: { setField($0) })) {
                ForEach(SmartRule.Field.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: 120, alignment: .leading)
            Picker("Comparison", selection: $rule.op) {
                ForEach(SmartRule.operators(for: rule.field), id: \.self) { Text(Self.title($0, rule.field)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: 160, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Remove this condition")
            Button(action: add) { Image(systemName: "plus") }
                .help("Add a condition")
        }
    }

    @ViewBuilder private var value: some View {
        switch rule.field {
        case .album: menu(choices.albums, empty: "No albums") { $0.replacingOccurrences(of: "/", with: " › ") }
        case .keyword: menu(choices.keywords, empty: "No keywords")
        case .person: menu(choices.people, empty: "Name people in People first")
        case .camera where rule.op != .contains: menu(cameras, empty: "No cameras")
        case .lens where rule.op != .contains: menu(lenses, empty: "No lenses")
        case .photo:
            Picker("Value", selection: $rule.value) {
                ForEach(SmartRule.Kind.allCases, id: \.self) { Text(Self.title($0)).tag($0.rawValue) }
            }
            .labelsHidden()
        case .rating:
            Picker("Value", selection: $rule.value) {
                Text("No stars").tag("0")
                ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag(String($0)) }
            }
            .labelsHidden()
        case .date where rule.op == .isInTheLast:
            HStack(spacing: 6) {
                TextField("30", text: $rule.value).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("days")
            }
        case .date:
            DatePicker("Date", selection: Binding(
                get: { SmartRule.day(rule.value) ?? .now },
                set: { rule.value = SmartRule.dayString($0) }), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .onAppear { if SmartRule.day(rule.value) == nil { rule.value = SmartRule.dayString(.now) } }
        case .camera, .lens, .filename:
            TextField("Text", text: $rule.value).textFieldStyle(.roundedBorder)
        }
    }

    /// A pop-up of the known values, or a note when there are none.
    @ViewBuilder private func menu(
        _ values: [String], empty: String, title: @escaping (String) -> String = { $0 }
    ) -> some View {
        if values.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            Picker("Value", selection: $rule.value) {
                if !values.contains(rule.value) { Text(rule.value.isEmpty ? "Choose…" : rule.value).tag(rule.value) }
                ForEach(values, id: \.self) { Text(title($0)).tag($0) }
            }
            .labelsHidden()
        }
    }

    /// Another field: its first comparison, and the first of its known values (or its usual one).
    private func setField(_ field: SmartRule.Field) {
        guard field != rule.field else { return }
        var new = SmartRule.starting(field)
        let known: [String] = switch field {
        case .album: choices.albums
        case .keyword: choices.keywords
        case .person: choices.people
        case .camera: cameras
        case .lens: lenses
        default: []
        }
        if let first = known.first { new.value = first }
        if field == .date { new.value = SmartRule.dayString(.now) }
        rule = new
    }

    static func title(_ field: SmartRule.Field) -> String {
        switch field {
        case .album: "Album"
        case .date: "Date"
        case .keyword: "Keyword"
        case .person: "Person"
        case .photo: "Photo"
        case .rating: "Rating"
        case .camera: "Camera"
        case .lens: "Lens"
        case .filename: "Filename"
        }
    }

    static func title(_ op: SmartRule.Operator, _ field: SmartRule.Field) -> String {
        switch op {
        case .is: field == .person ? "includes" : "is"
        case .isNot: field == .person ? "does not include" : "is not"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .isBefore: "is before"
        case .isAfter: "is after"
        case .isInTheLast: "is in the last"
        case .isAtLeast: "is at least"
        case .isAtMost: "is at most"
        }
    }

    static func title(_ kind: SmartRule.Kind) -> String {
        switch kind {
        case .favorite: "Favorite"
        case .edited: "Edited"
        case .raw: "RAW"
        case .video: "Video"
        case .panorama: "Panorama"
        }
    }
}
