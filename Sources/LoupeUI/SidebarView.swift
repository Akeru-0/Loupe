import LoupeIndex
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedItemID) {
            ForEach(model.sidebar.filter { !$0.items.isEmpty }) { group in
                if let title = group.title {
                    Section(title) { rows(group.items) }
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
