import AppKit
import Foundation
import LoupeCore
import LoupeImport
import Observation

/// Settings ▸ Import ▸ Import from Apple Photos: installs osxphotos into Loupe's support folder the first time (a
/// Python virtual environment; Python 3.10+ must be on the Mac), then runs `osxphotos export` into the library's
/// Photos folder and reports progress. The Photos library is only read.
@MainActor @Observable final class ApplePhotosImport {
    enum Phase: Equatable {
        case idle
        /// Installing osxphotos, or starting the export.
        case preparing(String)
        case exporting(ApplePhotosExport.Progress?)
        case finished(ApplePhotosExport.Summary, at: Date)
        case failed(String, needsFullDiskAccess: Bool)
    }

    private(set) var phase: Phase = .idle
    /// The last lines osxphotos printed, for the details.
    private(set) var recentOutput: [String] = []
    var isRunning: Bool {
        switch phase {
        case .preparing, .exporting: true
        default: false
        }
    }

    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var cancelled = false

    init(supportDirectory: URL) { self.supportDirectory = supportDirectory }

    private var environment: URL { supportDirectory.appendingPathComponent("osxphotos", isDirectory: true) }
    private var osxphotos: URL { environment.appendingPathComponent("bin/osxphotos") }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: osxphotos.path) }

    /// Copies the Photos library's photos into `destination` (the library's Photos folder).
    func start(library: URL, destination: URL) {
        guard !isRunning else { return }
        cancelled = false
        recentOutput = []
        Task {
            do {
                if !isInstalled { try await install() }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                phase = .preparing("Reading the Photos library…")
                var summary: ApplePhotosExport.Summary?
                let arguments = ApplePhotosExport.arguments(
                    library: library, destination: destination,
                    exportDB: supportDirectory.appendingPathComponent("apple-photos-export.db"))
                // The task holds the importer until the export ends; the closure needn't (and can't) be weaker.
                let status = try await run(osxphotos, arguments) { line in
                    if let progress = ApplePhotosExport.progress(in: line) { self.phase = .exporting(progress) }
                    if let found = ApplePhotosExport.summary(in: line) { summary = found }
                }
                if cancelled { phase = .idle; return }
                if status == 0, let summary {
                    phase = .finished(summary, at: Date())
                } else {
                    fail("osxphotos stopped (exit status \(status)).")
                }
            } catch {
                if cancelled { phase = .idle; return }
                fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    // MARK: - Steps

    private func install() async throws {
        guard let python = await Self.findPython() else {
            throw ImportUIError("Importing from Apple Photos needs Python 3.10 or later, which isn't on this Mac. "
                + "Install it with Homebrew (brew install python) and try again.")
        }
        phase = .preparing("Installing osxphotos (first time only)…")
        try? FileManager.default.removeItem(at: environment)
        guard try await run(python, ["-m", "venv", environment.path]) == 0,
            try await run(environment.appendingPathComponent("bin/pip"), ["install", "--upgrade", "osxphotos"]) == 0,
            isInstalled
        else { throw ImportUIError("Couldn't install osxphotos. Is the Mac online?") }
    }

    /// The first Python 3.10+ among the usual places.
    private static func findPython() async -> URL? {
        await Task.detached {
            for path in ApplePhotosExport.pythonCandidates where FileManager.default.isExecutableFile(atPath: path) {
                let check = Process()
                check.executableURL = URL(fileURLWithPath: path)
                check.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"]
                check.standardOutput = FileHandle.nullDevice
                check.standardError = FileHandle.nullDevice
                guard (try? check.run()) != nil else { continue }
                check.waitUntilExit()
                if check.terminationStatus == 0 { return URL(fileURLWithPath: path) }
            }
            return nil
        }.value
    }

    /// Runs a tool, handing each line it prints (stdout and stderr) to `line` on the main actor; returns its exit
    /// status. Cancel terminates it.
    private func run(
        _ tool: URL, _ arguments: [String], line: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"  // lines as they happen
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.process = process
        defer { self.process = nil }
        let lines = AsyncStream<String> { continuation in
            let splitter = LineSplitter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    if let rest = splitter.rest() { continuation.yield(rest) }
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                for line in splitter.feed(data) { continuation.yield(line) }
            }
        }
        try process.run()
        for await text in lines {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            recentOutput = Array((recentOutput + [text]).suffix(8))
            line(text)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func fail(_ message: String) {
        let output = recentOutput.joined(separator: "\n")
        let needsAccess = ApplePhotosExport.isPermissionError(output)
        phase = .failed(
            needsAccess ? "Loupe can't read the Photos library without Full Disk Access." : message,
            needsFullDiskAccess: needsAccess)
    }

    /// System Settings ▸ Privacy & Security ▸ Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Splits a pipe's bytes into lines. The pipe's readability handler calls it one read at a time, never concurrently.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    func rest() -> String? { buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
}
