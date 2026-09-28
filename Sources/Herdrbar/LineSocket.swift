import Foundation

enum SocketError: Error, Equatable {
    case pathTooLong
    case connect(errno: Int32)
    case io(errno: Int32)
    case closed
    case timedOut
    case frameTooLarge
}

/// A blocking Unix-socket connection that reads newline-delimited frames.
///
/// Frames split on byte 0x0A only. Foundation's `AsyncLineSequence` also splits on U+2028, which herdr
/// does not escape inside JSON strings. One thread reads at a time; `shutdown()` may be called from any
/// thread to wake a blocked reader.
final class LineSocket: @unchecked Sendable {
    static let frameLimit = 16 << 20

    private let fd: Int32
    private var buffer: [UInt8] = []
    private var scanned = 0

    init(path: String, timeout: TimeInterval? = 2) throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.io(errno: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(timeout)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError.connect(errno: code)
        }
    }

    /// Wraps a descriptor that is already connected (tests, and the fake server's accepted peers).
    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    /// nil means no timeout: reads block until data, EOF, or `shutdown()`.
    func setTimeout(_ seconds: TimeInterval?) {
        var value = timeval()
        if let seconds {
            value.tv_sec = Int(seconds)
            value.tv_usec = Int32((seconds - Double(Int(seconds))) * 1_000_000)
        }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw SocketError.timedOut }
                throw SocketError.io(errno: errno)
            }
        }
    }

    func sendLine(_ value: some Encodable) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try send(data)
    }

    func readLine(limit: Int = LineSocket.frameLimit) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeFirst(newline + 1)
                scanned = 0
                return line
            }
            scanned = buffer.count
            guard buffer.count <= limit else { throw SocketError.frameTooLarge }
            let count = read(fd, &chunk, chunk.count)
            if count > 0 { buffer.append(contentsOf: chunk[..<count]); continue }
            if count == 0 { throw SocketError.closed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
            throw SocketError.io(errno: errno)
        }
    }

    func shutdown() {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }
}

enum Herdr {
    /// One request per connection: send a line, read one reply line, close. herdr answers an unknown
    /// method with an empty id, so matching ids across a shared connection would not work anyway.
    static func call(_ method: String, _ params: some Encodable & Sendable = [String: String](),
                     socket path: String, timeout: TimeInterval = 2) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let socket = try LineSocket(path: path, timeout: timeout)
                    try socket.sendLine(Request(id: method, method: method, params: params))
                    continuation.resume(returning: try socket.readLine())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func snapshot(socket path: String) async throws -> Snapshot {
        try decodeSnapshotReply(try await call("session.snapshot", socket: path))
    }
}
