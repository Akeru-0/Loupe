import AppKit
import LoupeIndex

/// What the cloud upload is doing, for the settings.
enum CloudUploadStatus: Equatable {
    /// No upload folder chosen.
    case off
    case running(done: Int, total: Int)
    /// The last pass finished.
    case finished(CloudUploadReport, at: Date)
    /// The folder couldn't be used (not mounted, inside the library…); nothing was recorded per photo.
    case unavailable(String)
}

/// Uploading the library to the cloud through a synced folder (`CloudUploader`): the folder is chosen per library;
/// a pass runs after the library has started, after changes (coalesced) and on demand. Files that fail are listed
/// under Unable to Upload.
extension AppModel {
    private static let uploadFoldersKey = "upload.folders"

    var uploadFolder: URL? {
        uploadFoldersByRoot[effectiveSettings.rootPath].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `nil` turns the upload off (what was uploaded stays in the folder).
    func setUploadFolder(_ url: URL?) {
        uploadFoldersByRoot[effectiveSettings.rootPath] = url?.path
        if let data = try? JSONEncoder().encode(uploadFoldersByRoot) {
            preferences.set(String(decoding: data, as: UTF8.self), forKey: Self.uploadFoldersKey)
        }
        cancelUpload()
        uploadStatus = .off
        scheduleUpload()
    }

    func loadUploadFolders() {
        uploadFoldersByRoot = preferences.string(forKey: Self.uploadFoldersKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
    }

    /// Starts a pass, or queues one more after the running pass. Not during the library's initial scan: a pass
    /// follows it.
    func scheduleUpload() {
        guard let folder = uploadFolder, let library, !isScanning else { return }
        if uploadTask != nil {
            uploadPending = true
            return
        }
        let uploader = CloudUploader(index: library.index, root: library.location.rootURL, destination: folder)
        uploadStatus = .running(done: 0, total: 0)
        uploadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))  // a burst of changes makes one pass
            guard !Task.isCancelled else { return }
            // Not detached: cancelling this task (upload turned off, library replaced) stops the pass.
            let report: Result<CloudUploadReport, any Error>
            do {
                report = .success(try await uploader.run { done, total in
                    guard done % 25 == 0 || done == total else { return }
                    Task { @MainActor in
                        guard let self, self.library === library, case .running = self.uploadStatus else { return }
                        self.uploadStatus = .running(done: done, total: total)
                    }
                })
            } catch { report = .failure(error) }
            guard let self, self.library === library, !Task.isCancelled else { return }
            uploadTask = nil
            switch report {
            case .success(let report): uploadStatus = .finished(report, at: Date())
            case .failure(let error) where error is CancellationError: uploadStatus = .off
            case .failure(let error): uploadStatus = .unavailable(error.localizedDescription)
            }
            refreshSidebar()  // Unable to Upload comes and goes with failures
            if uploadPending {
                uploadPending = false
                scheduleUpload()
            }
        }
    }

    func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
        uploadPending = false
    }
}
