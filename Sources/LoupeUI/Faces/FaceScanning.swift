import AppKit
import Foundation
import GRDB
import LoupeFaces
import LoupeIndex

/// What face recognition is doing, for Settings ▸ Faces.
enum FaceScanStatus: Equatable {
    /// Waiting for the model or ONNX Runtime.
    case unavailable
    case scanning(done: Int, total: Int)
    case finished(FaceScanner.Report, at: Date)
    case failed(String)
}

/// Background face recognition: once the model is downloaded and ONNX Runtime installed, the library's photos are
/// scanned after it has started and after changes (a burst makes one pass), and People is refreshed afterwards.
extension AppModel {
    static let groupPetsKey = "faces.groupPets"

    var groupsPets: Bool { preferences.bool(forKey: Self.groupPetsKey) ?? true }

    func scheduleFaceScan() {
        guard faceModel.isInstalled, FaceScanner.runtimeInstalled, let library, !isScanning else {
            if faceScanTask == nil { faceScanStatus = .unavailable }
            return
        }
        if faceScanTask != nil {
            faceScanPending = true
            return
        }
        let model = faceModel.file, pets = groupsPets
        faceScanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))  // a burst of changes makes one pass
            guard !Task.isCancelled else { return }
            let result: Result<FaceScanner.Report, any Error>
            do {
                let scanner = try FaceScanner(
                    index: library.index, root: library.location.rootURL, model: model, pets: pets)
                result = .success(try await scanner.run { done, total in
                    guard done % 5 == 0 || done == total else { return }
                    Task { @MainActor in
                        guard let self, self.library === library, self.faceScanTask != nil else { return }
                        self.faceScanStatus = .scanning(done: done, total: total)
                    }
                })
            } catch { result = .failure(error) }
            guard let self, self.library === library, !Task.isCancelled else { return }
            faceScanTask = nil
            switch result {
            case .success(let report): faceScanStatus = .finished(report, at: Date())
            case .failure(let error) where error is CancellationError: faceScanStatus = .unavailable
            case .failure(let error): faceScanStatus = .failed(error.localizedDescription)
            }
            refreshSidebar()  // People's count
            refreshFaceGroups()
            if faceScanPending {
                faceScanPending = false
                scheduleFaceScan()
            }
        }
    }

    // MARK: - People

    /// Reads the people and pets People shows, off the main thread.
    func refreshFaceGroups() {
        guard let library else { return faceGroups = [] }
        Task {
            let groups = await Task.detached { (try? library.index.faceGroups()) ?? [] }.value
            guard self.library === library else { return }
            faceGroups = groups
            if let opened = openedFaceGroup, !groups.contains(where: { $0.id == opened }) { closeFaceGroup() }
        }
    }

    /// The name given in People, else "Person 1", "Cat 2": the unnamed are numbered within their kind, the most
    /// photographed first.
    func faceGroupTitle(_ group: LibraryIndex.FaceGroup) -> String {
        if let name = shownName(group) { return name }
        let number = faceGroups.filter { $0.kind == group.kind && shownName($0) == nil }.firstIndex { $0.id == group.id }
            .map { $0 + 1 } ?? 1
        switch group.kind {
        case "cat": return "Cat \(number)"
        case "dog": return "Dog \(number)"
        default: return "Person \(number)"
        }
    }

    /// The name the user gave, if any (not a hidden one given so corrections can point at an unnamed group).
    func shownName(_ group: LibraryIndex.FaceGroup) -> String? {
        group.name.flatMap { PeopleNames.isShown($0) ? $0 : nil }
    }

    /// People ▸ Rename…: asks for the name (a name another person has merges them into one).
    func renameFaceGroup(_ group: LibraryIndex.FaceGroup) async {
        guard let name = await Self.askName(
            title: "Rename “\(faceGroupTitle(group))”",
            message: "Photos of them found later get this name too. Giving two people the same name makes them one.",
            button: "Rename", initial: shownName(group) ?? "")
        else { return }
        await setFaceGroupName(group, to: name)
    }

    /// nil or empty removes the name.
    func setFaceGroupName(_ group: LibraryIndex.FaceGroup, to name: String?) async {
        guard let library else { return }
        do {
            try await FaceScanner.rename(group: group.id, to: name, index: library.index, root: library.location.rootURL)
        } catch {
            present(error)
        }
        refreshFaceGroups()
        refreshSidebar()
    }

    /// A correction in a person's photos: in `photos`, their face moves to `target`. The person shown stays open
    /// (under their new id if their first face moved).
    func moveFaces(in photos: [Int64], to target: FaceScanner.Target) async {
        guard let library, let group = openedFaceGroup, !photos.isEmpty else { return }
        do {
            let now = try await FaceScanner.move(
                photos: photos, from: group, to: target, index: library.index, root: library.location.rootURL)
            if let now, now != group, openedFaceGroup == group {
                openedFaceGroup = now
                query.scope = .faceGroup(now)
            }
        } catch {
            present(error)
        }
        refreshFaceGroups()  // closes the person if nobody is left
        refreshSidebar()
    }

    /// Change Person ▸ New Person…: asks for the name, then moves the faces to that new person.
    func moveFacesToNewPerson(in photos: [Int64], kind: String) async {
        let noun = kind == "person" ? "person" : "pet"
        guard let name = await Self.askName(
            title: "New \(noun.capitalized)", message: "The \(noun) in the selected photos gets this name.",
            button: "Move", initial: "")
        else { return }
        await moveFaces(in: photos, to: .name(name))
    }

    /// A person or pet clicked in People: their photos, like an album. Back returns to People.
    func openFaceGroup(_ id: Int64) {
        selection = []
        openedFaceGroup = id
        query.scope = .faceGroup(id)
    }

    func closeFaceGroup() {
        openedFaceGroup = nil
        selection = []
        if case .faceGroup = query.scope { query.scope = .people }
    }

    func cancelFaceScan() {
        faceScanTask?.cancel()
        faceScanTask = nil
        faceScanPending = false
    }

    /// Group pets turned on: every photo is scanned again for cats and dogs. Off: the pets found are dropped.
    func setGroupsPets(_ on: Bool) {
        preferences.set(on, forKey: Self.groupPetsKey)
        guard let library else { return }
        cancelFaceScan()
        Task {
            try? await library.index.dbPool.write { db in
                if on {
                    try db.execute(sql: "DELETE FROM face_scan")
                } else {
                    try db.execute(sql: "DELETE FROM face WHERE kind != 'person'")
                    try db.execute(sql: "DELETE FROM face_group WHERE kind != 'person'")
                }
            }
            refreshSidebar()
            scheduleFaceScan()
        }
    }

    // MARK: - ONNX Runtime

    /// Installs ONNX Runtime with Homebrew (`brew install onnxruntime`), then scans.
    func installOnnxRuntime() {
        guard runtimeInstall != .installing else { return }
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            runtimeInstall = .failed("Homebrew isn't installed. Get it from brew.sh, then try again.")
            return
        }
        runtimeInstall = .installing
        Task {
            let status = await Task.detached { () -> Int32 in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brew)
                process.arguments = ["install", "onnxruntime"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return -1 }
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            if status == 0, FaceScanner.runtimeInstalled {
                runtimeInstall = .idle
                scheduleFaceScan()
            } else {
                runtimeInstall = .failed("Homebrew couldn't install ONNX Runtime. Try in Terminal: brew install onnxruntime")
            }
        }
    }
}

enum RuntimeInstall: Equatable {
    case idle
    case installing
    case failed(String)
}
