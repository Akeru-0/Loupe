import Foundation
import SwiftUI

/// The viewer's (i) panel. Everything shown was loaded off the main thread by `PhotoViewerModel`.
struct InfoPanel: View {
    var viewer: PhotoViewerModel

    var body: some View {
        Form {
            if let records = viewer.records {
                Section {
                    Text(records.photo.stem).font(.headline)
                    if let date = records.photo.captureDate {
                        LabeledContent("Taken", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if !viewer.exifLines.isEmpty {
                    Section("Camera") {
                        ForEach(Array(viewer.exifLines.enumerated()), id: \.offset) { _, line in
                            LabeledContent(line.label, value: line.value)
                        }
                    }
                }
                if let version = viewer.focusedVersion {
                    Section("File") {
                        if let w = version.pixelWidth, let h = version.pixelHeight {
                            LabeledContent("Dimensions", value: "\(w) × \(h)")
                        }
                        LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
                        if let url = viewer.url(of: version) {
                            LabeledContent("Path") {
                                Text(url.path)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                Section("Library") {
                    let rating = records.metadata.rating
                    LabeledContent("Rating", value: rating > 0 ? String(repeating: "★", count: rating) : "None")
                    LabeledContent("Tags", value: records.metadata.tags.isEmpty ? "None" : records.metadata.tags.joined(separator: ", "))
                    LabeledContent("Albums", value: records.metadata.albums.isEmpty ? "None" : records.metadata.albums.joined(separator: ", "))
                }
            }
        }
        .formStyle(.grouped)
    }
}
