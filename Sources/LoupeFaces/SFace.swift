import COnnxRuntime
import Foundation

public enum FaceRecognitionError: LocalizedError {
    /// ONNX Runtime isn't installed where Loupe looks (Homebrew).
    case runtimeMissing
    case model(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: "ONNX Runtime isn't installed. Install it with Homebrew: brew install onnxruntime"
        case .model(let message): "The face recognition model couldn't run: \(message)"
        }
    }
}

/// SFace (OpenCV model zoo, Apache 2.0): an aligned 112 × 112 face → a 128-number vector; faces of one person have
/// vectors pointing the same way (cosine similarity ≥ 0.363 in OpenCV's tests). Run with ONNX Runtime, loaded from
/// Homebrew. One run at a time.
final class SFace {
    static let dimensions = 128
    private let model: OpaquePointer

    /// Where Homebrew installs ONNX Runtime (Apple silicon, then Intel).
    static let runtimeCandidates = [
        "/opt/homebrew/opt/onnxruntime/lib/libonnxruntime.dylib",
        "/usr/local/opt/onnxruntime/lib/libonnxruntime.dylib",
    ]

    static var installedRuntime: URL? {
        runtimeCandidates.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    init(model url: URL, runtime: URL? = SFace.installedRuntime) throws {
        guard let runtime else { throw FaceRecognitionError.runtimeMissing }
        var error = [CChar](repeating: 0, count: 512)
        guard let model = loupe_ort_open(runtime.path, url.path, &error, error.count) else {
            throw FaceRecognitionError.model(Self.message(error))
        }
        self.model = model
    }

    deinit { loupe_ort_close(model) }

    /// A C error buffer as text, up to its terminating zero.
    private static func message(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The face's vector, scaled to length 1. `input`: `FaceAlignment.input`.
    func vector(_ input: [Float]) throws -> [Float] {
        var output = [Float](repeating: 0, count: Self.dimensions)
        var error = [CChar](repeating: 0, count: 512)
        let side = Int64(FaceAlignment.side)
        let failed = input.withUnsafeBufferPointer { buffer in
            loupe_ort_run(model, buffer.baseAddress, 3, side, side, &output, output.count, &error, error.count)
        }
        guard failed == 0 else { throw FaceRecognitionError.model(Self.message(error)) }
        return Vectors.normalized(output)
    }
}

enum Vectors {
    static func normalized(_ v: [Float]) -> [Float] {
        let length = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? v.map { $0 / length } : v
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    static func data(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
