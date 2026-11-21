import CryptoKit
import Foundation
import Observation

/// The face recognition model Loupe downloads on request: SFace from OpenCV's model zoo (Apache 2.0), which turns an
/// aligned face into a vector so faces of one person can be grouped. Faces, cats and dogs are found with macOS's own
/// Vision framework; nothing leaves the Mac. The download is checked against a pinned SHA-256 before it is kept.
@MainActor @Observable final class FaceRecognitionModel {
    enum State: Equatable {
        case notInstalled
        case downloading
        case installed(bytes: Int64)
        case failed(String)
    }

    static let name = "SFace"
    static let source = URL(string:
        "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx")!
    static let sha256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
    static let expectedBytes: Int64 = 38_696_353
    static let license = "Apache License 2.0"

    private(set) var state: State = .notInstalled
    /// Where the model is kept: `<support>/Models/sface.onnx`.
    let file: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    init(supportDirectory: URL) {
        file = supportDirectory.appendingPathComponent("Models/sface.onnx")
        refresh()
    }

    var isInstalled: Bool { if case .installed = state { true } else { false } }

    func refresh() {
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 {
            state = .installed(bytes: size)
        } else if case .installed = state {
            state = .notInstalled
        }
    }

    func download() {
        guard task == nil else { return }
        state = .downloading
        let file = file
        task = Task {
            defer { task = nil }
            do {
                let (temp, response) = try await URLSession.shared.download(from: Self.source)
                defer { try? FileManager.default.removeItem(at: temp) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ModelError("The download server answered with an error.")
                }
                let digest = try await Task.detached { try Self.digest(of: temp) }.value
                guard digest == Self.sha256 else {
                    throw ModelError("The downloaded model didn't match the expected file, so it wasn't kept.")
                }
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: temp, to: file)
                refresh()
            } catch is CancellationError {
                refresh()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        task?.cancel()
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
        state = .notInstalled
    }

    /// Streamed, so the 39 MB file isn't read into memory at once.
    nonisolated private static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct ModelError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
