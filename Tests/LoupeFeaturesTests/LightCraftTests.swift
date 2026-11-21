import Darwin
import Foundation
import LoupeCore
import Testing
@testable import LoupeFeatures

/// A stand-in for LightCraft's control server: JSON lines on a loopback port, answered by `handle`, every request
/// recorded.
private final class FakeLightCraft: @unchecked Sendable {
    typealias Handler = @Sendable (_ command: String, _ params: [String: Any]) -> Result<Any, String>
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var _commands: [(String, [String: Any])] = []
    var commands: [(String, [String: Any])] { lock.withLock { _commands } }
    private let handle: Handler

    init(handle: @escaping Handler) throws {
        self.handle = handle
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(fd, 4)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    deinit { close(listener) }

    private func serve() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            Thread.detachNewThread { [self] in talk(client) }
        }
    }

    private func talk(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
                let id = request["id"] ?? NSNull()
                let outer = request["params"] as? [String: Any] ?? [:]
                let command = (request["method"] as? String == "engine.execute" ? outer["command"] as? String : request["method"] as? String) ?? ""
                let params = request["method"] as? String == "engine.execute" ? outer["params"] as? [String: Any] ?? [:] : outer
                lock.withLock { _commands.append((command, params)) }
                let reply: [String: Any]
                switch handle(command, params) {
                case .success(let result): reply = ["id": id, "ok": true, "result": result]
                case .failure(let error): reply = ["id": id, "ok": false, "error": error]
                }
                var data = try! JSONSerialization.data(withJSONObject: reply)
                data.append(0x0A)
                _ = data.withUnsafeBytes { send(fd, $0.baseAddress!, data.count, 0) }
            }
        }
    }
}

extension String: @retroactive Error {}

@Suite struct LightCraftTests {
    private let folder = URL(fileURLWithPath: "/Pictures/Trip")

    /// LightCraft with IMG_1 (id 11) and a deleted IMG_9 in /Pictures/Trip; `imports` adds IMG_2 as 12.
    private func lightCraft(importing: Bool = true) throws -> FakeLightCraft {
        let imported = NSLock()
        nonisolated(unsafe) var hasImg2 = false
        return try FakeLightCraft { command, params in
            switch command {
            case "catalog.query":
                guard (params["filter"] as? [String: Any])?["folder"] as? String == "/Pictures/Trip" else {
                    return .success(["total": 0, "photos": []])
                }
                var photos: [[String: Any]] = [
                    ["id": 11, "fileName": "IMG_1.CR2"], ["id": 19, "fileName": "IMG_9.CR2", "deleted": true],
                ]
                if imported.withLock({ hasImg2 }) { photos.append(["id": 12, "fileName": "img_2.cr2"]) }
                return .success(["total": photos.count, "photos": photos])
            case "library.import":
                if importing { imported.withLock { hasImg2 = true } }
                return .success(["imported": [], "duplicates": []])
            case "library.select", "photo.readMetadataFromFile": return .success(NSNull())
            case "ui.set": return .success([:])
            default: return .failure("unknown command `\(command)`")
            }
        }
    }

    @Test func findsPhotoIDsByFolderAndNameButNotDeletedOnes() throws {
        let lc = try lightCraft()
        let control = try LightCraftControl(port: lc.port)
        let files = ["IMG_1.CR2", "IMG_2.CR2", "IMG_9.CR2"].map { folder.appendingPathComponent($0) }
        #expect(try LightCraftBridge.ids(for: files, control: control) == [files[0]: 11])
        #expect(throws: LightCraftControl.ControlError.self) { try control.execute("nope") }
    }

    @Test func editImportsWhatLightCraftLacksThenSelectsAndShowsIt() throws {
        let lc = try lightCraft()
        let files = ["IMG_1.CR2", "IMG_2.CR2"].map { folder.appendingPathComponent($0) }
        try LightCraftBridge.edit(files, control: try LightCraftControl(port: lc.port))
        let sent = lc.commands
        let imported = try #require(sent.first { $0.0 == "library.import" })
        #expect(imported.1["paths"] as? [String] == ["/Pictures/Trip/IMG_2.CR2"])
        #expect(imported.1["mode"] as? String == "add")  // in place: nothing copied or moved
        let select = try #require(sent.first { $0.0 == "library.select" })
        #expect(select.1["ids"] as? [Int] == [11, 12])
        #expect(select.1["active"] as? Int == 11)  // the first one is shown, not whichever LightCraft picks
        #expect(sent.last?.0 == "ui.set")
    }

    @Test func reloadAsksOnlyForPhotosLightCraftHas() throws {
        let lc = try lightCraft()
        let control = try LightCraftControl(port: lc.port)
        try LightCraftBridge.reload([folder.appendingPathComponent("IMG_1.CR2"), folder.appendingPathComponent("IMG_2.JPG")],
                                    control: control)
        try LightCraftBridge.reload([folder.appendingPathComponent("IMG_7.CR2")], control: control)
        let reads = lc.commands.filter { $0.0 == "photo.readMetadataFromFile" }
        #expect(reads.count == 1 && reads[0].1["ids"] as? [Int] == [11])
        #expect(!lc.commands.contains { $0.0 == "library.import" })  // syncing never adds photos to LightCraft
    }

    @Test func noLightCraftOnThePortIsReportedNotHung() throws {
        // A port nothing listens on: bound for a moment to get a free number, then closed.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        close(fd)
        let port = UInt16(bigEndian: address.sin_port)
        let started = Date()
        #expect(throws: LightCraftControl.ControlError.self) { try LightCraftControl(port: port, timeout: 0.3) }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func theSyncStoreTellsLightCraftOnlyWhenAValueChanged() throws {
        let reloads = NSLock()
        nonisolated(unsafe) var reloaded: [[URL]] = []
        let store = LightCraftSyncStore { files in reloads.withLock { reloaded.append(files) } }
        let files = [folder.appendingPathComponent("IMG_1.CR2")]
        let first = try store.push(PhotoMetadata(rating: 2), files: files, lastState: nil)
        #expect(reloads.withLock { reloaded.isEmpty })  // LightCraft read the sidecar when it imported the photo
        let same = try store.push(PhotoMetadata(rating: 2), files: files, lastState: first)
        #expect(same == first && reloads.withLock { reloaded.isEmpty })
        _ = try store.push(PhotoMetadata(rating: 4, isFavorite: true), files: files, lastState: same)
        #expect(reloads.withLock { reloaded } == [files])
    }
}
