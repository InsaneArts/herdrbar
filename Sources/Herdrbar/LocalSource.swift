import Foundation
import Synchronization

/// Keeps a live view of the local herdr server. Events only nudge; each nudge takes a fresh
/// `session.snapshot` (10 ms), and the snapshot is the single source of truth.
final class LocalSource: Sendable {
    let socketPath: String
    private let wakes: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation

    init(socketPath: String) {
        self.socketPath = socketPath
        // Holding only the newest wake collapses a burst of events into one snapshot.
        (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Asks for a fresh snapshot soon.
    func refresh() { wake.yield() }

    /// Runs until the calling task is cancelled.
    func run(publish: @escaping @Sendable (Result<Snapshot, any Error>) async -> Void) async {
        var subscription: Subscription?
        var failures = 0
        let wake = self.wake
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                wake.yield()
            }
        }
        defer {
            ticker.cancel()
            subscription?.close()
        }

        refresh()
        for await _ in wakes {
            do {
                let snapshot = try await Herdr.snapshot(socket: socketPath)
                failures = 0
                await publish(.success(snapshot))
                if let subscription, subscription.isOpen, subscription.paneIDs == snapshot.paneIDs { continue }

                subscription?.close()
                subscription = nil
                do {
                    subscription = try await Subscription.open(socketPath, paneIDs: snapshot.paneIDs) { wake.yield() }
                    // Changes between the snapshot and the ack are covered by one more snapshot.
                    refresh()
                } catch let error as HerdrError where error.code == "pane_not_found" {
                    // A pane closed between the snapshot and the subscribe.
                    await sleepThenRefresh(.milliseconds(200))
                } catch {
                    // Without events, this loop still snapshots every 3 s.
                    await sleepThenRefresh(.seconds(3))
                }
            } catch {
                subscription?.close()
                subscription = nil
                failures += 1
                await publish(.failure(error))
                await sleepThenRefresh(Self.backoff(afterFailures: failures))
            }
        }
    }

    static func backoff(afterFailures failures: Int) -> Duration {
        [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3)][min(max(failures, 1), 4) - 1]
    }

    private func sleepThenRefresh(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
        refresh()
    }
}

/// One `events.subscribe` connection. A dedicated thread reads it, because a blocking read must not
/// hold a thread from Swift's cooperative pool.
final class Subscription: Sendable {
    let paneIDs: Set<String>
    private let socket: LineSocket
    private let open = Atomic(true)

    var isOpen: Bool { open.load(ordering: .relaxed) }

    private init(socket: LineSocket, paneIDs: Set<String>) {
        self.socket = socket
        self.paneIDs = paneIDs
    }

    /// Returns after herdr acknowledges the subscription, or throws its error (such as `pane_not_found`).
    static func open(_ path: String, paneIDs: Set<String>,
                     onEvent: @escaping @Sendable () -> Void) async throws -> Subscription {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let socket = try LineSocket(path: path, timeout: 2)
                    try socket.sendLine(Request(id: "herdrbar-events", method: "events.subscribe",
                                                params: SubscribeParams(paneIDs: paneIDs)))
                    _ = try decodeReply(try socket.readLine(), as: SubscriptionStarted.self)
                    socket.setTimeout(nil)
                    let subscription = Subscription(socket: socket, paneIDs: paneIDs)
                    subscription.startReading(onEvent)
                    continuation.resume(returning: subscription)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        open.store(false, ordering: .relaxed)
        socket.shutdown()
    }

    private func startReading(_ onEvent: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            while (try? socket.readLine()) != nil { onEvent() }
            open.store(false, ordering: .relaxed)
            onEvent()  // wake the loop so it notices the dead subscription
        }
        thread.name = "herdrbar.events"
        thread.start()
    }

    private struct SubscriptionStarted: Decodable {}
}
