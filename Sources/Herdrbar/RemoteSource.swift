import Foundation
import Synchronization

/// A saved SSH machine from `herdr machine list --json`.
struct SavedMachine: Decodable, Sendable, Equatable {
    var id: String
    var label: String
    var enabled: Bool
}

/// Why a remote machine could not be read, in words the menu shows.
struct RemoteFailure: Error, Equatable, CustomStringConvertible {
    var description: String

    static let needsNewerHerdr = RemoteFailure(description: "Needs herdr 0.9.1 or later")
    static let cantConnect = RemoteFailure(description: "Can't connect")

    /// herdr 0.9.0 does not know `--machine`; anything else that fails is a connection problem.
    init(_ error: any Error) {
        if let failure = error as? CLI.Failure, failure.message.contains("unknown option: --machine") {
            self = .needsNewerHerdr
        } else {
            self = .cantConnect
        }
    }

    init(description: String) {
        self.description = description
    }
}

/// Saved machines are read through `herdr --machine <id>`, which sends herdr's JSON API over SSH.
/// SSH has no event stream, so each machine is polled.
enum RemoteSource {
    static let timeout: Duration = .seconds(12)

    static func machines(herdr: String) async throws -> [SavedMachine] {
        let data = try await CLI.run([herdr, "machine", "list", "--json"], timeout: .seconds(5))
        return try JSONDecoder().decode([SavedMachine].self, from: data).filter(\.enabled)
    }

    static func snapshot(of machine: SavedMachine, herdr: String) async throws -> Snapshot {
        do {
            return try decodeSnapshotReply(try await CLI.run([herdr, "--machine", machine.id, "api", "snapshot"], timeout: timeout))
        } catch {
            throw RemoteFailure(error)
        }
    }

    /// 15 s, doubling after each failure, at most 5 minutes: a machine that is off stays quiet.
    static func delay(afterFailures failures: Int) -> Duration {
        .seconds(min(300, 15 << min(failures, 5)))
    }
}

/// Polls one saved machine until cancelled. `refresh()` polls again at once, when the menu opens or
/// after a jump to one of its agents.
final class RemotePoller: Sendable {
    let machine: SavedMachine
    private let herdr: String
    private let wakes: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private let failures = Atomic(0)

    init(machine: SavedMachine, herdr: String) {
        self.machine = machine
        self.herdr = herdr
        (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func refresh() { wake.yield() }

    func run(publish: @escaping @Sendable (Result<Snapshot, any Error>) async -> Void) async {
        let ticker = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RemoteSource.delay(afterFailures: failures.load(ordering: .relaxed)))
                wake.yield()
            }
        }
        defer { ticker.cancel() }
        refresh()
        for await _ in wakes {
            do {
                let snapshot = try await RemoteSource.snapshot(of: machine, herdr: herdr)
                failures.store(0, ordering: .relaxed)
                await publish(.success(snapshot))
            } catch {
                failures.add(1, ordering: .relaxed)
                await publish(.failure(error))
            }
        }
    }
}
