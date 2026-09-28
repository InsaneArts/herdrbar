import Foundation
import Synchronization
import Testing
@testable import Herdrbar

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

/// A compact way to describe an agent in a synthetic snapshot.
struct TestAgent {
    var terminal: String
    var pane: String
    var workspace = "w1"
    var tab = "w1:t1"
    var status: AgentStatus
    var agent: String? = "claude"
    var title: String?
    var seq: UInt64 = 0

    var info: AgentInfo {
        AgentInfo(terminalID: terminal, paneID: pane, workspaceID: workspace, tabID: tab, status: status,
                  agent: agent, displayAgent: nil, name: nil, title: nil, terminalTitleStripped: title,
                  cwd: nil, focused: false, stateChangeSeq: seq)
    }

    var json: [String: Any] {
        var object: [String: Any] = ["terminal_id": terminal, "pane_id": pane, "workspace_id": workspace, "tab_id": tab,
                                     "agent_status": status.rawValue, "focused": false, "revision": 0,
                                     "state_change_seq": seq]
        if let agent { object["agent"] = agent }
        if let title { object["terminal_title_stripped"] = title }
        return object
    }
}

func makeSnapshot(_ agents: [TestAgent], extraPanes: [String] = [], version: String = "0.9.1",
                  workspaces: [WorkspaceInfo] = [WorkspaceInfo(workspaceID: "w1", label: "api", number: 1)]) -> Snapshot {
    Snapshot(version: version, focusedPaneID: nil, workspaces: workspaces,
             tabs: Set(agents.map(\.tab)).sorted().enumerated().map { TabInfo(tabID: $1, number: $0 + 1) },
             panes: (agents.map(\.pane) + extraPanes).map { PaneRef(paneID: $0) },
             agents: agents.map(\.info))
}

/// The `session.snapshot` reply line for a synthetic snapshot, as herdr would send it.
func snapshotReplyLine(_ agents: [TestAgent], extraPanes: [String] = [], version: String = "0.9.1") -> Data {
    let panes = (agents.map(\.pane) + extraPanes).map { ["pane_id": $0, "terminal_id": "t-\($0)", "workspace_id": "w1",
                                                         "tab_id": "w1:t1", "focused": false, "agent_status": "unknown",
                                                         "revision": 0] as [String: Any] }
    let snapshot: [String: Any] = [
        "version": version, "protocol": 22, "focused_pane_id": NSNull(),
        "workspaces": [["workspace_id": "w1", "label": "api", "number": 1, "focused": true, "pane_count": 1,
                        "tab_count": 1, "active_tab_id": "w1:t1", "agent_status": "idle"]],
        "tabs": [["tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1", "focused": true,
                  "pane_count": 1, "agent_status": "idle"]],
        "panes": panes, "layouts": [], "agents": agents.map(\.json),
    ]
    let reply: [String: Any] = ["id": "session.snapshot", "result": ["type": "session_snapshot", "snapshot": snapshot]]
    return try! JSONSerialization.data(withJSONObject: reply)
}

/// Collects what a source publishes, for assertions from test code.
actor Recorder {
    private(set) var results: [Result<Snapshot, any Error>] = []

    func append(_ result: Result<Snapshot, any Error>) { results.append(result) }

    var snapshots: [Snapshot] { results.compactMap { try? $0.get() } }
    var failures: Int { results.filter { if case .failure = $0 { true } else { false } }.count }
    var latest: Snapshot? { snapshots.last }
}

/// Polls `condition` until it holds or the timeout passes.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// A thread-safe flag for tests that watch other threads.
final class Flag: Sendable {
    private let value = Atomic(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}
