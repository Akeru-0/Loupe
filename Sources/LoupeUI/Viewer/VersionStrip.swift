import Foundation
import LoupeCore
import SwiftUI

/// One button per version of the viewed photo, e.g. "RAW CR2 23.6 MB"; the focused one is highlighted.
struct VersionStrip: View {
    var viewer: PhotoViewerModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(viewer.records?.versions ?? []) { version in
                if version.id == viewer.focusedVersion?.id {
                    Button(Self.label(for: version)) {}
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(Self.label(for: version)) { viewer.focus(version) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.small)
    }

    /// "<KIND> <EXT> <size>", with the file's own extension.
    static func label(for version: VersionRecord) -> String {
        let ext = (version.path as NSString).pathExtension.uppercased()
        return "\(kindLabel(version.kind)) \(ext) \(ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))"
    }

    static func kindLabel(_ kind: VersionKind) -> String {
        switch kind {
        case .raw: "RAW"
        case .jpeg: "JPG"
        case .heic: "HEIC"
        case .image: "IMAGE"
        case .video: "VIDEO"
        case .live: "LIVE"
        case .edit: "EDIT"
        }
    }
}
