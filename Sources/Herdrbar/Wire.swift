import Foundation

// herdr's newline-delimited JSON API. Decoding is tolerant: herdr's docs ask clients to ignore unknown
// fields, and new states must not break an old Herdrbar.

enum AgentStatus: String, Sendable, Equatable, CaseIterable {
    case blocked, working, done, idle, unknown

    /// Blocked agents wait for an answer; done agents finished work nobody has looked at yet.
    var needsYou: Bool { self == .blocked || self == .done }
}

extension AgentStatus: Decodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

struct AgentInfo: Decodable, Sendable, Equatable {
    var terminalID: String
    var paneID: String
    var workspaceID: String
    var tabID: String
    var status: AgentStatus
    var agent: String?
    var displayAgent: String?
    var name: String?
    var title: String?
    var terminalTitleStripped: String?
    var cwd: String?
    var focused: Bool
    var stateChangeSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id", paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id"
        case status = "agent_status", agent, displayAgent = "display_agent", name, title
        case terminalTitleStripped = "terminal_title_stripped", cwd, focused
        case stateChangeSeq = "state_change_seq"
    }
}

struct WorkspaceInfo: Decodable, Sendable, Equatable {
    var workspaceID: String
    var label: String
    var number: Int

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", label, number
    }
}

struct TabInfo: Decodable, Sendable, Equatable {
    var tabID: String
    var number: Int

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id", number
    }
}

struct PaneRef: Decodable, Sendable, Equatable {
    var paneID: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
    }
}

struct Snapshot: Decodable, Sendable, Equatable {
    var version: String
    var focusedPaneID: String?
    var workspaces: [WorkspaceInfo]
    var tabs: [TabInfo]
    var panes: [PaneRef]
    var agents: [AgentInfo]

    var paneIDs: Set<String> { Set(panes.map(\.paneID)) }

    enum CodingKeys: String, CodingKey {
        case version, focusedPaneID = "focused_pane_id", workspaces, tabs, panes, agents
    }
}

struct HerdrError: Error, Decodable, Sendable, Equatable {
    var code: String
    var message: String
}

struct Pong: Decodable, Sendable, Equatable {
    var version: String
}

struct TitleReply: Decodable, Sendable, Equatable {
    var changed: Bool
    var reason: String
}

private struct Reply<Result: Decodable>: Decodable {
    var result: Result?
    var error: HerdrError?
}

private struct SnapshotResult: Decodable {
    var snapshot: Snapshot
}

/// Decodes `{"id","result"}` into `Result`, or throws the `{"id","error"}` herdr sent instead.
func decodeReply<Result: Decodable>(_ line: Data, as type: Result.Type = Result.self) throws -> Result {
    let reply = try JSONDecoder().decode(Reply<Result>.self, from: line)
    if let error = reply.error { throw error }
    guard let result = reply.result else { throw HerdrError(code: "empty_reply", message: "herdr sent no result") }
    return result
}

/// The socket's `session.snapshot` and the CLI's `herdr api snapshot` print the same envelope.
func decodeSnapshotReply(_ line: Data) throws -> Snapshot {
    try decodeReply(line, as: SnapshotResult.self).snapshot
}

struct Request<Params: Encodable & Sendable>: Encodable, Sendable {
    var id: String
    var method: String
    var params: Params
}

struct SubscribeParams: Encodable, Sendable {
    struct Subscription: Encodable, Sendable, Equatable {
        var type: String
        var paneID: String?

        enum CodingKeys: String, CodingKey {
            case type, paneID = "pane_id"
        }
    }

    var subscriptions: [Subscription]

    /// Status changes only arrive per pane, so every pane gets its own subscription. Structural events
    /// tell us when the pane set changed and the subscription must be rebuilt. `pane.updated` is left out:
    /// a blinking codex title would fire it every second.
    init(paneIDs: Set<String>) {
        let structural = ["pane.created", "pane.closed", "pane.exited", "pane.moved", "pane.agent_detected",
                          "workspace.renamed", "workspace.closed"]
        subscriptions = structural.map { Subscription(type: $0) }
            + paneIDs.sorted().map { Subscription(type: "pane.agent_status_changed", paneID: $0) }
    }
}

/// Compares dotted numeric versions such as "0.9.1". A pre-release suffix ("1.0.0-beta") is ignored.
func isVersion(_ version: String, atLeast minimum: String) -> Bool {
    func parts(_ text: String) -> [Int] {
        let core = text.split(separator: "-", maxSplits: 1).first ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
    let lhs = parts(version), rhs = parts(minimum)
    for index in 0..<max(lhs.count, rhs.count) {
        let a = index < lhs.count ? lhs[index] : 0
        let b = index < rhs.count ? rhs[index] : 0
        if a != b { return a > b }
    }
    return true
}
