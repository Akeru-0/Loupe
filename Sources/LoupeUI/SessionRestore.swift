import Foundation

/// Where the user was when the app last ran, per library: the sidebar item, the zoom, the photo at the top of the
/// grid and the photo open in the viewer. Saved as it changes, so a rebuild or a crash keeps it too; restored at
/// launch once the item's photos are loaded.
extension AppModel {
    struct Session: Codable, Equatable {
        var item: String?
        var columns: Int?
        var topPhotoID: Int64?
        var viewerPhotoID: Int64?
    }

    private static let sessionsKey = "session.byLibrary"

    /// At launch: the remembered item and zoom now; the scroll position and the viewer once the photos are in.
    func restoreSession() {
        guard let session = sessions[effectiveSettings.rootPath] else { return }
        restoringSession = session
        // Nothing is saved while restoring; the item is shown once the sidebar lists it.
        if let item = session.item { select(withoutHistory: item) }
        if let columns = session.columns, GridLayout.columnRange.contains(columns) { self.columns = columns }
        topPhotoID = session.topPhotoID
    }

    /// Called with every batch of photos for the current query: the first one for the restored item finishes it.
    func finishRestoringSession() {
        guard let session = restoringSession, let id = selectedItemID, id == session.item,
            let item = item(withID: id), query.scope == item.scope
        else { return }
        restoringSession = nil
        let shown = Set(photoSections.flatMap(\.photoIDs))
        if let top = session.topPhotoID, shown.contains(top) { pendingTopPhotoID = top }
        // A locked view's photo isn't opened before it is unlocked.
        if let viewer = session.viewerPhotoID, shown.contains(viewer), !isLocked { viewerPhotoID = viewer }
    }

    /// The grid scrolled: remembers the photo now at its top.
    func noteTopPhoto(_ id: Int64?) {
        guard id != topPhotoID else { return }
        topPhotoID = id
        saveSession()
    }

    func saveSession() {
        // Until the restore is done, what is on screen is not what the user left.
        guard restoringSession == nil else { return }
        let item = selectedItemID.flatMap { $0.hasPrefix("device:") ? nil : $0 }
        var all = sessions
        let session = Session(item: item, columns: columns, topPhotoID: topPhotoID, viewerPhotoID: viewerPhotoID)
        guard all[effectiveSettings.rootPath] != session else { return }
        all[effectiveSettings.rootPath] = session
        if let data = try? JSONEncoder().encode(all) {
            preferences.set(String(decoding: data, as: UTF8.self), forKey: Self.sessionsKey)
        }
    }

    private var sessions: [String: Session] {
        preferences.string(forKey: Self.sessionsKey)
            .flatMap { try? JSONDecoder().decode([String: Session].self, from: Data($0.utf8)) } ?? [:]
    }
}
