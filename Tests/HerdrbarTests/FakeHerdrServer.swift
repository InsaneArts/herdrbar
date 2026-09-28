import Foundation
@testable import Herdrbar

/// A stand-in herdr server on a Unix socket. It answers `session.snapshot` and `events.subscribe`,
/// and pushes events to its subscribers when a test asks.
final class FakeHerdrServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var snapshotLine: Data
    private var allowedPanes: Set<String>?
    private var subscribers: [LineSocket] = []
    private var requests: [Set<String>] = []
    private var stopped = false

    init(path: String? = nil, snapshot: Data) throws {
        self.path = path ?? FileManager.default.temporaryDirectory
            .appending(path: "hb-\(UUID().uuidString.prefix(8)).sock").path
        snapshotLine = snapshot
        unlink(self.path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(self.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw SocketError.io(errno: errno) }
        Thread { [self] in acceptLoop() }.start()
    }

    /// The pane ids of every accepted subscription, oldest first.
    var subscribeRequests: [Set<String>] { lock.withLock { requests } }

    func setSnapshot(_ line: Data) { lock.withLock { snapshotLine = line } }

    /// Subscriptions naming any other pane fail with `pane_not_found`. nil accepts every pane.
    func allowPanes(_ panes: Set<String>?) { lock.withLock { allowedPanes = panes } }

    func push(_ line: String = #"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1"}}"#) {
        for subscriber in lock.withLock({ subscribers }) { try? subscriber.send(Data((line + "\n").utf8)) }
    }

    func stop() {
        let open = lock.withLock {
            stopped = true
            defer { subscribers = [] }
            return subscribers
        }
        for subscriber in open { subscriber.shutdown() }
        _ = try? LineSocket(path: path, timeout: 1)  // wakes the blocked accept()
        close(listener)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 || lock.withLock({ stopped }) {
                if fd >= 0 { close(fd) }
                return
            }
            let connection = LineSocket(fd: fd)
            Thread { [self] in serve(connection) }.start()
        }
    }

    private func serve(_ connection: LineSocket) {
        guard let line = try? connection.readLine(),
              let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = request["method"] as? String else { return }
        let id = request["id"] as? String ?? ""
        switch method {
        case "session.snapshot":
            try? connection.send(lock.withLock { snapshotLine } + Data("\n".utf8))
        case "events.subscribe":
            let subscriptions = (request["params"] as? [String: Any])?["subscriptions"] as? [[String: Any]] ?? []
            let panes = Set(subscriptions.compactMap { $0["pane_id"] as? String })
            if let allowed = lock.withLock({ allowedPanes }), let missing = panes.subtracting(allowed).first {
                reply(connection, #"{"id":"\#(id)","error":{"code":"pane_not_found","message":"pane \#(missing) not found"}}"#)
                return
            }
            lock.withLock {
                requests.append(panes)
                subscribers.append(connection)
            }
            reply(connection, #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#)
        default:
            reply(connection, #"{"id":"","error":{"code":"invalid_request","message":"unknown method"}}"#)
        }
    }

    private func reply(_ connection: LineSocket, _ json: String) {
        try? connection.send(Data((json + "\n").utf8))
    }
}
