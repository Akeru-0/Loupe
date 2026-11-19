import CoreServices
import Foundation
import Testing
import LoupeTestSupport
@testable import LoupeIndex

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Set<URL>, Bool)] = []
    func add(_ f: Set<URL>, _ all: Bool) { lock.lock(); events.append((f, all)); lock.unlock() }
    func matches(_ folder: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { $0.1 || $0.0.contains { $0.standardizedFileURL.path == folder.path } }
    }
}

@Suite struct FolderWatcherTests {
    @Test func watcherReportsNewFile() async throws {
        let lib = try TestLibrary()
        try FileManager.default.createDirectory(at: lib.url("sub"), withIntermediateDirectories: true)
        let collector = Collector()
        let watcher = FolderWatcher(root: lib.root, latency: 0.1) { collector.add($0.folders, $0.rescanAll || !$0.directories.isEmpty) }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(500))
        try lib.addJPEG("sub/new.jpg")
        let deadline = Date().addingTimeInterval(5)
        while !collector.matches(lib.url("sub")) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(collector.matches(lib.url("sub")))
    }
}

extension FolderWatcherTests {
    @Test func watcherReplaysEventsFromBeforeStart() async throws {
        let lib = try TestLibrary()
        try FileManager.default.createDirectory(at: lib.url("sub"), withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(300))
        let since = FSEventsGetCurrentEventId()
        try lib.addJPEG("sub/early.jpg")
        try await Task.sleep(for: .milliseconds(500))
        let collector = Collector()
        let watcher = FolderWatcher(root: lib.root, latency: 0.1, sinceWhen: since) { collector.add($0.folders, $0.rescanAll || !$0.directories.isEmpty) }
        watcher.start()
        defer { watcher.stop() }
        let deadline = Date().addingTimeInterval(5)
        while !collector.matches(lib.url("sub")) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(collector.matches(lib.url("sub")))
    }
}
