import Foundation

/// An agent's identity: its machine plus herdr's terminal id, which survives pane moves.
struct AgentKey: Hashable, Sendable {
    var machine: String
    var terminalID: String
}

struct Agent: Equatable, Sendable {
    var key: AgentKey
    var paneID: String
    var status: AgentStatus
    var kind: String?
    var displayAgent: String?
    var name: String?
    var metadataTitle: String?
    var terminalTitle: String?
    var cwd: String?
    var workspaceLabel: String
    var workspaceNumber: Int
    var tabNumber: Int
    var stateChangeSeq: UInt64
    /// When Herdrbar saw the current status begin. nil when it was already so before Herdrbar looked.
    var since: Date?
}

struct Machine: Equatable, Sendable {
    var label: String
    var agents: [AgentKey: Agent] = [:]
    /// Last statuses seen, kept through an outage so a reconnect only notifies about real changes.
    var lastKnown: [AgentKey: AgentStatus] = [:]
    var failures = 0
    var firstFailure: Date?
    var lastSuccess: Date?
    var lastError: String?
    var serverVersion: String?
    var baselined = false
}

/// Agents that newly need you, and agents whose "needs you" state ended.
struct Transitions: Equatable, Sendable {
    var needsYou: [Agent] = []
    var resolved: [AgentKey] = []
}

struct Fleet: Sendable {
    static let local = "local"
    /// A machine keeps showing its last agents through this many failed checks.
    static let toleratedFailures = 2

    private(set) var machines: [String: Machine] = [:]

    var agents: [Agent] { machines.values.flatMap { $0.agents.values } }

    func agent(_ key: AgentKey) -> Agent? { machines[key.machine]?.agents[key] }

    /// Drops a machine that is no longer saved or enabled in herdr.
    mutating func forget(machine label: String) {
        machines[label] = nil
    }

    mutating func apply(_ result: Result<Snapshot, any Error>, machine label: String, now: Date) -> Transitions {
        var machine = machines[label] ?? Machine(label: label)
        defer { machines[label] = machine }
        switch result {
        case .success(let snapshot):
            return Self.apply(snapshot, to: &machine, now: now)
        case .failure(let error):
            machine.failures += 1
            machine.firstFailure = machine.firstFailure ?? now
            machine.lastError = String(describing: error)
            if machine.failures > Self.toleratedFailures { machine.agents = [:] }
            return Transitions()
        }
    }

    private static func apply(_ snapshot: Snapshot, to machine: inout Machine, now: Date) -> Transitions {
        let workspaces = Dictionary(snapshot.workspaces.map { ($0.workspaceID, $0) }, uniquingKeysWith: { a, _ in a })
        let tabs = Dictionary(snapshot.tabs.map { ($0.tabID, $0.number) }, uniquingKeysWith: { a, _ in a })
        let watching = machine.baselined && machine.failures == 0
        var transitions = Transitions()
        var next: [AgentKey: Agent] = [:]

        for info in snapshot.agents {
            let key = AgentKey(machine: machine.label, terminalID: info.terminalID)
            let before = machine.lastKnown[key]
            let changed = before != nil && before != info.status
            let since: Date? = if changed {
                now
            } else if let previous = machine.agents[key] {
                previous.since
            } else {
                // A new agent that appears while we watch started now. After a gap, we can't know.
                before == nil && watching ? now : nil
            }
            let workspace = workspaces[info.workspaceID]
            let agent = Agent(
                key: key, paneID: info.paneID, status: info.status, kind: info.agent,
                displayAgent: info.displayAgent, name: info.name, metadataTitle: info.title,
                terminalTitle: info.terminalTitleStripped, cwd: info.cwd,
                workspaceLabel: workspace?.label ?? info.workspaceID, workspaceNumber: workspace?.number ?? .max,
                tabNumber: tabs[info.tabID] ?? .max, stateChangeSeq: info.stateChangeSeq ?? 0, since: since)
            next[key] = agent

            // The first snapshot is a silent baseline, and an agent seen for the first time never notifies.
            guard machine.baselined, changed, let before else { continue }
            if info.status.needsYou {
                transitions.needsYou.append(agent)
            } else if before.needsYou {
                transitions.resolved.append(key)
            }
        }
        for (key, status) in machine.lastKnown where next[key] == nil && status.needsYou {
            transitions.resolved.append(key)
        }

        machine.agents = next
        machine.lastKnown = next.mapValues(\.status)
        machine.failures = 0
        machine.firstFailure = nil
        machine.lastSuccess = now
        machine.lastError = nil
        machine.serverVersion = snapshot.version
        machine.baselined = true
        return transitions
    }
}
