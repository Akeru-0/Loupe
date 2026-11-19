import Foundation
import LoupeCore

/// "Share": renders copies into a temp folder with the chosen preset, then hands them to the share sheet.
public struct ShareAction: PhotoAction {
    public let id = "share"
    private let exporters: [any ShareExporter]
    private let outputDirectory: URL
    private let defaults: any PreferenceStore

    public init(
        exporters: [any ShareExporter],
        outputDirectory: URL = SharePreferences.defaultOutputDirectory,
        defaults: any PreferenceStore = UserDefaultsStore.standard
    ) {
        self.exporters = exporters
        self.outputDirectory = outputDirectory
        self.defaults = defaults
    }

    /// Each file with its photo's orientation override.
    private static func files(for selection: ActionSelection) -> [(url: URL, kind: VersionKind, orientation: Int?)] {
        selection.targets().map { ($0.url, $0.version.kind, $0.photo?.orientationOverride) }
    }

    @MainActor public func entries(for selection: ActionSelection) -> [ActionMenuEntry] {
        let files = Self.files(for: selection)
        guard !files.isEmpty else { return [] }
        let defaults = self.defaults
        let outputDirectory = self.outputDirectory
        let removeLocation = SharePreferences.removeLocation(in: defaults)

        func run(_ exporter: any ShareExporter, _ context: any ActionContext) throws {
            let removeLocation = SharePreferences.removeLocation(in: defaults)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            var urls: [URL] = []
            for file in files {
                do {
                    urls.append(try exporter.export(file.url, kind: file.kind, orientation: file.orientation, removeLocation: removeLocation, into: outputDirectory))
                } catch {
                    context.present(error)
                }
            }
            if !urls.isEmpty { context.share(urls) }
        }

        var children: [ActionMenuEntry] = exporters.map { exporter in
            var title = exporter.title
            // Formats that can't be re-muxed without re-encoding are shared as-is.
            if exporter is OriginalExporter {
                var notes: [String] = []
                if removeLocation, files.contains(where: { !OriginalExporter.canStripLocation($0.url) }) {
                    notes.append("location kept")
                }
                if files.contains(where: { $0.orientation != nil && !OriginalExporter.canSetOrientation($0.url) }) {
                    notes.append("rotation not applied")
                }
                if !notes.isEmpty { title += " (\(notes.joined(separator: ", ")))" }
            }
            return ActionMenuEntry(
                id: "share.\(exporter.id)", title: title,
                isEnabled: files.allSatisfy { exporter.canExport($0.kind) }
            ) { context in try run(exporter, context) }
        }
        children.append(ActionMenuEntry(
            id: "share.removeLocation", title: "Remove Location",
            systemImage: removeLocation ? "checkmark" : nil
        ) { _ in SharePreferences.setRemoveLocation(!SharePreferences.removeLocation(in: defaults), in: defaults) })

        return [ActionMenuEntry(id: "share", title: "Share", systemImage: "square.and.arrow.up", children: children)]
    }
}
