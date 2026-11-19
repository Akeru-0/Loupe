import AppKit
import LoupeCore
import LoupeImport
import LoupeIndex
import SwiftUI

/// The import window for one card, shown instead of the grid while the card is selected under Devices: the card's
/// photos (those already on the Mac dimmed and badged), the destination, Import All New / Import Selected, the
/// progress and the summary. The card is only read.
struct ImportView: View {
    var model: AppModel
    var importModel: ImportModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if !importModel.photosLibraryChecked {
                notice(
                    "Apple Photos library wasn't checked — give Loupe Full Disk Access in System Settings to include it.",
                    systemImage: "exclamationmark.triangle")
            }
            status
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(importModel.card.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(counts)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            DestinationPicker(model: model, importModel: importModel)
                .disabled(importModel.phase.isImporting)
            Button("Import Selected") { importModel.importSelected() }
                .disabled(!importModel.canImportSelected || model.isImporting)
            Button("Import All New") { importModel.importAllNew() }
                .keyboardShortcut(.defaultAction)
                .disabled(!importModel.canImport || model.isImporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var counts: String {
        switch importModel.phase {
        case .listing:
            return "Reading the card…"
        case .waitingForLibrary:
            return "Waiting for library scan…"
        case .checking(let done, let total):
            return "Looking for photos already on this Mac… \(done.formatted()) of \(total.formatted())"
        case .failed:
            return "The card couldn't be read."
        case .ready, .importing, .done:
            let new = importModel.newGroups
            let files = new.reduce(0) { $0 + $1.allFiles.count }
            let bytes = new.reduce(Int64(0)) { $0 + $1.versions.reduce(0) { $0 + $1.file.size } }
            let onMac = importModel.groups.count - new.count
            var text = new.isEmpty
                ? "No new photos"
                : "\(new.count.formatted()) new \(new.count == 1 ? "photo" : "photos") · \(files.formatted()) "
                    + "\(files == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            if onMac > 0 { text += " · \(onMac.formatted()) already on this Mac" }
            return text
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.15))
    }

    // MARK: - Progress and summary

    @ViewBuilder private var status: some View {
        switch importModel.phase {
        case .importing(let progress):
            HStack(spacing: 12) {
                ProgressView(
                    value: Double(progress.bytesDone), total: Double(max(progress.bytesTotal, 1))
                ) {
                    Text("Importing \(progress.filesDone.formatted()) of \(progress.filesTotal.formatted()) files…")
                        .font(.callout)
                        .monospacedDigit()
                }
                Button("Cancel") { importModel.cancel() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        case .done(let result):
            summary(result)
        default:
            EmptyView()
        }
    }

    private func summary(_ result: ImportResult) -> some View {
        let failures = ImportModel.failures(of: result)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label(
                    ImportModel.summary(of: result),
                    systemImage: failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout)
                Spacer(minLength: 12)
                if !result.imported.isEmpty {
                    Button(result.destinationFolder.isEmpty ? "Show Unsorted" : "Show Album") {
                        model.showImported(folder: result.destinationFolder)
                    }
                }
                Button("Eject") { model.eject(importModel.card) }  // only here: after the import has ended
            }
            if !failures.isEmpty {
                ScrollView {
                    Text(failures.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Grid

    @ViewBuilder private var content: some View {
        switch importModel.phase {
        case .listing:
            ProgressView("Reading “\(importModel.card.name)”…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Read the Card", systemImage: "sdcard")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { importModel.load() }
            }
        default:
            if importModel.groups.isEmpty {
                ContentUnavailableView("No Photos on This Card", systemImage: "sdcard")
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 240), spacing: 10)], spacing: 10) {
                ForEach(importModel.groups, id: \.importID) { group in
                    let onMac = importModel.isOnMac(group)
                    ImportCell(
                        group: group, onMac: onMac, isSelected: importModel.selection.contains(group.importID),
                        loader: importModel.thumbnails
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { if !onMac { toggle(group) } }
                }
            }
            .padding(16)
        }
    }

    private func toggle(_ group: PhotoGroup) {
        let id = group.importID
        if importModel.selection.contains(id) {
            importModel.selection.remove(id)
        } else {
            importModel.selection.insert(id)
        }
    }
}

/// One card photo: its thumbnail (read from the card, cached in the normal thumbnail directory), its name and
/// file types, dimmed and badged "On Mac" when it is already there.
private struct ImportCell: View {
    let group: PhotoGroup
    let onMac: Bool
    let isSelected: Bool
    let loader: ThumbnailLoader?
    // `@State` is a macro whose plugin ships only with Xcode; see SettingsView.
    private let image: State<CGImage?>

    init(group: PhotoGroup, onMac: Bool, isSelected: Bool, loader: ThumbnailLoader?) {
        self.group = group
        self.onMac = onMac
        self.isSelected = isSelected
        self.loader = loader
        image = State(initialValue: loader?.cached(group.displayVersion.file))
    }

    var body: some View {
        let display = group.displayVersion
        VStack(spacing: 4) {
            Color.secondary.opacity(0.12)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let cg = image.wrappedValue {
                        Image(decorative: cg, scale: 1).resizable().scaledToFill()
                    } else {
                        Image(systemName: display.kind == .video ? "video" : "photo")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottomLeading) {
                    if onMac {
                        Text("On Mac")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
            Text(group.stem)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(types)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .opacity(onMac ? 0.45 : 1)
        .help(onMac ? "\(group.stem) is already on this Mac" : group.stem)
        .task(id: display.file) {
            guard image.wrappedValue == nil, let loader else { return }
            image.wrappedValue = await loader.image(for: display.file, kind: display.kind)
        }
    }

    private var types: String {
        group.versions.map { $0.file.url.pathExtension.uppercased() }.joined(separator: " + ")
    }
}
