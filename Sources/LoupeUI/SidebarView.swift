import LoupeIndex
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedItemID) {
            // Albums stays even when empty: its header's menu creates the first album.
            ForEach(model.sidebarGroups.filter { !$0.items.isEmpty || $0.id == "albums" }) { group in
                if let title = group.title {
                    Section {
                        if group.id == "pinned" {
                            ForEach(group.items) { SidebarRow(item: $0, model: model) }
                                .onMove { model.movePinned(from: $0, to: $1) }
                        } else {
                            SidebarRows(items: group.items, parent: group.id, model: model)
                        }
                    } header: {
                        header(title, group: group)
                    }
                } else {
                    // Untitled (the top section): its rows go straight into the list. Inside a Section the list
                    // squared off the first row's selection at the top.
                    SidebarRows(items: group.items, parent: group.id, model: model)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }


    /// A section's header: dragged onto another header, the section takes that one's place.
    private func header(_ title: String, group: SidebarGroup) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                if group.id == "albums" {
                    Button("New Album…") { Task { await model.newAlbum(in: "", select: true) } }
                }
            }
            .onDrag {
                model.draggedSectionID = group.id
                return NSItemProvider(object: (SectionDropDelegate.prefix + group.id) as NSString)
            }
            .onDrop(of: [.plainText], delegate: SectionDropDelegate(target: group.id, model: model))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isScanning { ProgressView().controlSize(.small) }
            Text(model.isLocked ? "Locked" : model.scanStatus)  // a locked view's count stays private
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The items of a section or album group, each level reorderable by dragging; groups disclose their albums.
private struct SidebarRows: View {
    let items: [SidebarItem]
    /// The section's or group's id, under which the order is saved.
    let parent: String
    let model: AppModel

    var body: some View {
        ForEach(items) { item in
            if item.children.isEmpty {
                SidebarRow(item: item, model: model)
            } else {
                DisclosureGroup {
                    SidebarRows(items: item.children, parent: item.id, model: model)
                } label: {
                    SidebarRow(item: item, model: model)
                }
            }
        }
        .onMove { model.moveItems(in: parent, shown: items.map(\.id), from: $0, to: $1) }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Label(item.title, systemImage: item.systemImage)
                .lineLimit(1)
                .help(item.title)
            Spacer(minLength: 0)
            if item.scope == .hidden || item.scope == .recentlyDeleted { padlock }
            if model.isDevice(item) {
                Button { model.eject(item) } label: { Image(systemName: "eject") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!model.canEject(item))
                    .help(model.canEject(item) ? "Eject “\(item.title)”" : "Can't eject while importing from it")
            }
        }
            .badge(item.badge ?? 0)  // 0 shows none
            // The whole row, not just the label, takes drops and opens the context menu.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .sidebarOrganizing(item, model: model)
            .background(SidebarFocusRefuser())  // grey selection, never the focused blue
            .tag(item.id)
            .popover(
                isPresented: Binding(
                    get: { model.iconPickerItemID == item.id },
                    set: { if !$0, model.iconPickerItemID == item.id { model.iconPickerItemID = nil } }),
                arrowEdge: .trailing
            ) { IconPicker(item: item, model: model) }
    }
}

/// Change Icon…: the icons an album or group can have, each shown as it would look in the sidebar.
private struct IconPicker: View {
    let item: SidebarItem
    let model: AppModel

    var body: some View {
        let chosen = model.icon(of: item)
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon for “\(item.title)”").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 6), spacing: 6) {
                ForEach(AppModel.albumIcons, id: \.symbol) { icon in
                    let selected = chosen == icon.symbol
                    Button { choose(icon.symbol) } label: {
                        Image(systemName: icon.symbol)
                            .font(.system(size: 17))
                            .frame(width: 36, height: 32)
                            .foregroundStyle(selected ? Color.white : Color.accentColor)
                            .background(selected ? Color.accentColor : Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(icon.name)
                    .accessibilityLabel(icon.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            HStack {
                Spacer()
                Button("Default") { choose(nil) }.disabled(chosen == nil)
            }
        }
        .padding(14)
    }

    private func choose(_ symbol: String?) {
        model.setIcon(symbol, for: item)
        model.iconPickerItemID = nil
    }
}

extension SidebarRow {
    /// Closed while Hidden and Recently Deleted are locked; open (click to lock) while they're unlocked.
    @ViewBuilder fileprivate var padlock: some View {
        if model.isUnlocked {
            Button { model.lock(byHand: true) } label: { Image(systemName: "lock.open") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Unlocked until \((model.unlockExpiry ?? .now).formatted(date: .omitted, time: .shortened)). "
                    + "Click to lock Hidden and Recently Deleted now.")
        } else {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .help("Locked")
        }
    }
}

/// A section header dropped onto another one. Only Loupe's own header drags are taken (photos and text are not).
struct SectionDropDelegate: DropDelegate {
    static let prefix = "loupe.sidebar-section:"
    let target: String
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        model.draggedSectionID != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = model.draggedSectionID, let provider = info.itemProviders(for: [.plainText]).first
        else { return false }
        model.draggedSectionID = nil
        let model = model, target = target
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            guard (text as? String) == Self.prefix + dragged else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { model.moveSection(dragged, onto: target) } }
        }
        return true
    }
}
