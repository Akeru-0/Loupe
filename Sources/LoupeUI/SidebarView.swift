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
                        rows(group.items)
                    } header: {
                        if group.id == "albums" {
                            Text(title).contextMenu {
                                Button("New Album…") { Task { await model.newAlbum(in: "", select: true) } }
                            }
                        } else {
                            Text(title)
                        }
                    }
                } else {
                    Section { rows(group.items) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func rows(_ items: [SidebarItem]) -> some View {
        OutlineGroup(items, children: \.childItems) { item in
            Label(item.title, systemImage: item.systemImage)
                .lineLimit(1)
                .help(item.title)
                .sidebarOrganizing(item, model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isScanning { ProgressView().controlSize(.small) }
            Text(model.scanStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension SidebarItem {
    /// `OutlineGroup` treats nil as a leaf (no disclosure triangle).
    var childItems: [SidebarItem]? { children.isEmpty ? nil : children }
}
