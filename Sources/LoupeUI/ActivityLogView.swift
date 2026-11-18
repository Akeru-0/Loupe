import SwiftUI

/// Library messages (scan results, unreadable files, sync failures) and errors shown to the owner.
struct ActivityLogView: View {
    var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            List(model.log) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            .overlay {
                if model.log.isEmpty { ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle") }
            }
            .onChange(of: model.log.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .navigationTitle("Activity")
    }
}
