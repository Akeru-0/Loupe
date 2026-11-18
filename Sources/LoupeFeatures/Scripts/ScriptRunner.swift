import Foundation
import LoupeCore

public struct ScriptResult: Sendable {
    public var exitCode: Int32
    public var output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public enum ScriptRunner {
    /// Runs `/usr/bin/shortcuts` with the given arguments (injectable so tests never run a real Shortcut).
    public typealias ShortcutRunner = @Sendable (_ arguments: [String]) async throws -> ScriptResult

    public static let liveShortcutRunner: ShortcutRunner = { arguments in
        try await launch(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: arguments, environment: nil, directory: nil)
    }

    /// Runs the script on `files`. A non-zero exit is reported in the result; only a failure to launch throws.
    public static func run(
        _ item: ScriptItem, files: [URL], photoKeys: [String], kinds: [VersionKind],
        shortcutRunner: ShortcutRunner = liveShortcutRunner
    ) async throws -> ScriptResult {
        switch item.kind {
        case .executable:
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            env["LOUPE_PHOTO_IDS"] = photoKeys.joined(separator: "\n")
            env["LOUPE_VERSION_KINDS"] = kinds.map(\.rawValue).joined(separator: "\n")
            return try await launch(
                item.url, arguments: files.map(\.path), environment: env,
                directory: item.url.deletingLastPathComponent())
        case .shortcut:
            var exitCode: Int32 = 0
            var output = ""
            for file in files {
                let result = try await shortcutRunner(["run", item.title, "--input-path", file.path])
                if exitCode == 0 { exitCode = result.exitCode }
                output += result.output
            }
            return ScriptResult(exitCode: exitCode, output: output)
        }
    }

    /// Never goes through a shell; waits off the calling actor, stdout and stderr merged.
    private static func launch(
        _ executable: URL, arguments: [String], environment: [String: String]?, directory: URL?
    ) async throws -> ScriptResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                if let directory { process.currentDirectoryURL = directory }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ScriptResult(
                    exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
