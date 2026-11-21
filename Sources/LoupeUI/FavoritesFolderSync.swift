import Foundation
import LoupeCore
import LoupeIndex

/// Keeps the library's Favorites folder (`FavoritesFolder`) in step: a pass after the library's scan, after every
/// change to the library, and whenever something in the folder changes (an editor saved an edit there).
extension AppModel {
    /// Starts a pass, or queues one more after the running pass. Not during the library's initial scan: a pass
    /// follows it.
    func scheduleFavoritesSync() {
        guard let library, !isScanning else { return }
        if favoritesTask != nil {
            favoritesPending = true
            return
        }
        let folder = FavoritesFolder(index: library.index, root: library.location.rootURL)
        favoritesTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))  // a burst of changes makes one pass
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) { Result { try folder.sync() } }.value
            guard let self, self.library === library, !Task.isCancelled else { return }
            favoritesTask = nil
            switch result {
            case .success(let report):
                if report.copiedBack > 0 {
                    log("Favorites folder: \(report.copiedBack) edited file(s) copied back to the library")
                }
                for failure in report.failures.prefix(20) { log("Favorites folder: couldn't copy \(failure)") }
            case .failure(let error):
                log("Favorites folder: \(error.localizedDescription)")
            }
            if favoritesPending {
                favoritesPending = false
                scheduleFavoritesSync()
            }
        }
    }

    /// Watches the library for changes inside the Favorites folder (the library's own watcher skips it).
    func watchFavoritesFolder() {
        favoritesWatcher?.stop()
        favoritesWatcher = nil
        guard let library else { return }
        let root = library.location.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(LibrarySettings.favoritesFolderName).path.lowercased()
        let watcher = FolderWatcher(root: root, latency: 0.5) { [weak self] changes in
            let paths = (changes.folders.union(changes.directories)).map { $0.resolvingSymlinksInPath().path.lowercased() }
            guard paths.contains(where: { $0 == folder || $0.hasPrefix(folder + "/") }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleFavoritesSync() } }
        }
        if watcher.start() { favoritesWatcher = watcher }
    }

    func stopFavoritesSync() {
        favoritesTask?.cancel()
        favoritesTask = nil
        favoritesPending = false
        favoritesWatcher?.stop()
        favoritesWatcher = nil
    }
}
