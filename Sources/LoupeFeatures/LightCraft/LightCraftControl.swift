import Darwin
import Foundation

/// A client for LightCraft's control channel: the JSON-lines server LightCraft runs on `127.0.0.1:PORT` when started
/// with `--control PORT` (LightCraft's `docs/control-protocol.md`). One request per line, one reply per line, in
/// order: `{"id", "method", "params"}` → `{"id", "ok", "result"}` or `{"id", "ok": false, "error"}`.
/// Blocking with short timeouts, so it can run from synchronous code (`MetadataStore.push`); never on the main thread.
/// Requests on one connection run one at a time (`lock`).
public final class LightCraftControl: @unchecked Sendable {
    public static let defaultPort: UInt16 = 7980

    public enum ControlError: LocalizedError {
        /// Nothing listens on the port: LightCraft isn't running, or runs without `--control`.
        case notListening
        case timedOut
        case failed(String)
        case badReply

        public var errorDescription: String? {
            switch self {
            case .notListening: "LightCraft isn't reachable on its control port."
            case .timedOut: "LightCraft didn't answer in time."
            case .failed(let message): "LightCraft: \(message)"
            case .badReply: "LightCraft sent a reply Loupe can't read."
            }
        }
    }

    private let fd: Int32
    private let lock = NSLock()
    private var nextID = 1
    private var buffer = Data()

    /// Connects, or throws `notListening` within `timeout`.
    public init(port: UInt16 = defaultPort, timeout: TimeInterval = 0.5) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.notListening }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS, Self.wait(fd, events: Int16(POLLOUT), timeout: timeout) else {
                close(fd)
                throw ControlError.notListening
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else {
                close(fd)
                throw ControlError.notListening
            }
        }
        self.fd = fd
    }

    deinit { close(fd) }

    /// Runs an engine or UI command (`engine.execute`) and returns its `result`.
    @discardableResult
    public func execute(_ command: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) throws -> Any? {
        try request("engine.execute", ["command": command, "params": params], timeout: timeout)
    }

    /// Sends one request and waits for its reply.
    @discardableResult
    public func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) throws -> Any? {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        line.append(0x0A)
        try send(line, timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let reply = try readLine(until: deadline)
            guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                throw ControlError.badReply
            }
            // A reply without an id is the server closing the connection (idle, junk); one for another id is stale.
            guard let replyID = object["id"] as? Int else {
                throw ControlError.failed(object["error"] as? String ?? "the connection was closed")
            }
            guard replyID == id else { continue }
            if object["ok"] as? Bool == true { return object["result"] }
            throw ControlError.failed(object["error"] as? String ?? "the command failed")
        }
    }

    // MARK: - Socket

    private func send(_ data: Data, timeout: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            guard Self.wait(fd, events: Int16(POLLOUT), timeout: timeout) else { throw ControlError.timedOut }
            let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, data.count - offset, 0) }
            if sent < 0 {
                if errno == EAGAIN { continue }
                throw ControlError.notListening
            }
            offset += sent
        }
    }

    private func readLine(until deadline: Date) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
                return Data(line)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, Self.wait(fd, events: Int16(POLLIN), timeout: remaining) else { throw ControlError.timedOut }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0 {
                if errno == EAGAIN { continue }
                throw ControlError.notListening
            }
            guard count > 0 else { throw ControlError.failed("the connection was closed") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private static func wait(_ fd: Int32, events: Int16, timeout: TimeInterval) -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, Int32(max(0, timeout) * 1000))
        return result > 0 && descriptor.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0
    }
}
