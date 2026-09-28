import Foundation
import Testing
@testable import Herdrbar

@Suite(.serialized) struct LocalSourceTests {
    private func run(_ server: FakeHerdrServer) -> (Recorder, Task<Void, Never>) {
        let source = LocalSource(socketPath: server.path)
        let recorder = Recorder()
        let task = Task { await source.run { await recorder.append($0) } }
        return (recorder, task)
    }

    private func line(_ status: AgentStatus, panes extra: [String] = []) -> Data {
        snapshotReplyLine([TestAgent(terminal: "a", pane: "w1:p1", status: status)], extraPanes: extra)
    }

    @Test func publishesTheFirstSnapshotAndSubscribesToEveryPane() async throws {
        let server = try FakeHerdrServer(snapshot: line(.working, panes: ["w1:p2"]))
        defer { server.stop() }
        let (recorder, task) = run(server)
        defer { task.cancel() }
        #expect(await eventually { await recorder.latest?.agents.first?.status == .working })
        #expect(await eventually { server.subscribeRequests.last == ["w1:p1", "w1:p2"] })
    }

    @Test func anEventBringsAFreshSnapshot() async throws {
        let server = try FakeHerdrServer(snapshot: line(.working))
        defer { server.stop() }
        let (recorder, task) = run(server)
        defer { task.cancel() }
        #expect(await eventually { !server.subscribeRequests.isEmpty })
        server.setSnapshot(line(.blocked))
        server.push()
        #expect(await eventually(timeout: .seconds(1)) { await recorder.latest?.agents.first?.status == .blocked })
    }

    @Test func aNewPaneRebuildsTheSubscription() async throws {
        let server = try FakeHerdrServer(snapshot: line(.working))
        defer { server.stop() }
        let (_, task) = run(server)
        defer { task.cancel() }
        #expect(await eventually { server.subscribeRequests.last == ["w1:p1"] })
        server.setSnapshot(line(.working, panes: ["w1:p2"]))
        server.push(#"{"event":"pane_created","data":{"type":"pane_created","pane":{"pane_id":"w1:p2"}}}"#)
        #expect(await eventually { server.subscribeRequests.last == ["w1:p1", "w1:p2"] })
    }

    @Test func aPaneThatClosedDuringSubscribeIsRetriedNotReported() async throws {
        let server = try FakeHerdrServer(snapshot: line(.working))
        defer { server.stop() }
        server.allowPanes([])
        let (recorder, task) = run(server)
        defer { task.cancel() }
        #expect(await eventually { await recorder.latest != nil })
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.subscribeRequests.isEmpty)
        server.allowPanes(nil)
        #expect(await eventually { server.subscribeRequests.last == ["w1:p1"] })
        #expect(await recorder.failures == 0)
    }

    @Test func recoversWhenTheServerComesBack() async throws {
        let server = try FakeHerdrServer(snapshot: line(.working))
        let (recorder, task) = run(server)
        defer { task.cancel() }
        #expect(await eventually { !server.subscribeRequests.isEmpty })
        server.stop()
        #expect(await eventually { await recorder.failures > 0 })
        let restarted = try FakeHerdrServer(path: server.path, snapshot: line(.idle))
        defer { restarted.stop() }
        #expect(await eventually(timeout: .seconds(5)) { await recorder.latest?.agents.first?.status == .idle })
        #expect(await eventually { !restarted.subscribeRequests.isEmpty })
    }
}
