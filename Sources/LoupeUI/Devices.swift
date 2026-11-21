import AppKit
import LoupeImport
import LoupeIndex
import SwiftUI

/// Devices in the sidebar: camera cards (they open the import window) and other drives, each with an eject button.
extension AppModel {
    static func driveItemID(_ drive: ExternalDrive) -> String { "drive:" + drive.volumeURL.path }

    func drive(forItemID id: String) -> ExternalDrive? {
        guard id.hasPrefix("drive:") else { return nil }
        return drives.first { Self.driveItemID($0) == id }
    }

    /// A card or drive row: it gets an eject button.
    func isDevice(_ item: SidebarItem) -> Bool { card(forItemID: item.id) != nil || drive(forItemID: item.id) != nil }

    /// Not while an import reads from that card.
    func canEject(_ item: SidebarItem) -> Bool {
        if let card = card(forItemID: item.id) {
            return ![importModel, backgroundImport].contains { $0?.card == card && $0?.phase.isImporting == true }
        }
        return drive(forItemID: item.id) != nil
    }

    func eject(_ item: SidebarItem) {
        guard canEject(item) else { return }
        if let card = card(forItemID: item.id) {
            eject(card)
        } else if let drive = drive(forItemID: item.id) {
            eject(volumeURL: drive.volumeURL, name: drive.name)
        }
    }
}

/// A selected drive that isn't a camera card: nothing to import, so its name with Show in Finder and Eject.
struct DriveView: View {
    var model: AppModel
    var drive: ExternalDrive

    var body: some View {
        ContentUnavailableView {
            Label(drive.name, systemImage: "externaldrive")
        } description: {
            Text("This drive has no camera photos to import (no DCIM folder).")
        } actions: {
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([drive.volumeURL]) }
                Button("Eject") { model.eject(volumeURL: drive.volumeURL, name: drive.name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
