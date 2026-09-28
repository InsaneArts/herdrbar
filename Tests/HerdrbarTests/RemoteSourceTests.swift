import Foundation
import Testing
@testable import Herdrbar

/// A stand-in `herdr` for saved machines: `machine list --json` and `--machine <id> api snapshot`.
/// Every call is appended to `calls.log` next to the script.
struct StubHerdr {
    let directory: URL
    var path: String { directory.appending(path: "herdr").path }
    var calls: [String] {
        ((try? String(contentsOf: directory.appending(path: "calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    init(snapshot: Data) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "hb-stub-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try snapshot.write(to: directory.appending(path: "snapshot.json"))
        let script = """
        #!/bin/bash
        here=$(dirname "$0")
        echo "$*" >> "$here/calls.log"
        case "$*" in
          "machine list --json")
            echo '[{"id":"m1","label":"omarchy","target":"omarchy","session":"default","enabled":true,"selected":false},'
            echo ' {"id":"m2","label":"nas","target":"nas","session":"default","enabled":false,"selected":false}]' ;;
          "--machine m1 api snapshot") cat "$here/snapshot.json" ;;
          "--machine old api snapshot") echo "unknown option: --machine" >&2; exit 2 ;;
          *) echo "ssh: connect to host: No route to host" >&2; exit 255 ;;
        esac
        """
        try Data(script.utf8).write(to: directory.appending(path: "herdr"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct RemoteSourceTests {
    @Test func listsOnlyEnabledMachines() async throws {
        let stub = try StubHerdr(snapshot: snapshotReplyLine([]))
        defer { stub.remove() }
        #expect(try await RemoteSource.machines(herdr: stub.path) == [SavedMachine(id: "m1", label: "omarchy", enabled: true)])
    }

    @Test func readsAMachinesSnapshotOverItsCLI() async throws {
        let stub = try StubHerdr(snapshot: snapshotReplyLine([TestAgent(terminal: "r1", pane: "w1:p1", status: .blocked)]))
        defer { stub.remove() }
        let snapshot = try await RemoteSource.snapshot(of: SavedMachine(id: "m1", label: "omarchy", enabled: true), herdr: stub.path)
        #expect(snapshot.agents.map(\.status) == [.blocked])
    }

    @Test func explainsWhyAMachineCantBeRead() async throws {
        let stub = try StubHerdr(snapshot: snapshotReplyLine([]))
        defer { stub.remove() }
        await #expect(throws: RemoteFailure.needsNewerHerdr) {
            try await RemoteSource.snapshot(of: SavedMachine(id: "old", label: "old", enabled: true), herdr: stub.path)
        }
        await #expect(throws: RemoteFailure.cantConnect) {
            try await RemoteSource.snapshot(of: SavedMachine(id: "gone", label: "gone", enabled: true), herdr: stub.path)
        }
    }

    @Test(arguments: [(0, 15), (1, 30), (2, 60), (3, 120), (4, 240), (5, 300), (12, 300)])
    func backsOffUpToFiveMinutes(failures: Int, seconds: Int) {
        #expect(RemoteSource.delay(afterFailures: failures) == .seconds(seconds))
    }

    @Test func pollsAtOnceAndAgainOnRefresh() async throws {
        let stub = try StubHerdr(snapshot: snapshotReplyLine([TestAgent(terminal: "r1", pane: "w1:p1", status: .working)]))
        defer { stub.remove() }
        let poller = RemotePoller(machine: SavedMachine(id: "m1", label: "omarchy", enabled: true), herdr: stub.path)
        let recorder = Recorder()
        let task = Task { await poller.run { await recorder.append($0) } }
        defer { task.cancel() }
        #expect(await eventually { await recorder.snapshots.count == 1 })
        poller.refresh()
        #expect(await eventually { await recorder.snapshots.count == 2 })
        #expect(stub.calls.filter { $0 == "--machine m1 api snapshot" }.count == 2)
    }
}
