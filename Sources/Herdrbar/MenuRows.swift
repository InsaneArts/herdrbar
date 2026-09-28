import Foundation

/// The local herdr server as the menu presents it.
enum LocalState: Equatable, Sendable {
    case connecting
    case live
    case notRunning
    case notInstalled
    case tooOld(version: String)
}

struct AgentRow: Equatable, Sendable {
    var key: AgentKey
    var status: AgentStatus
    var title: String
    var subtitle: String
}

/// A saved machine that could not be read for a while.
struct MachineProblem: Equatable, Sendable {
    var label: String
    var detail: String
}

struct MenuModel: Equatable, Sendable {
    enum Notice: Equatable, Sendable {
        case connecting, nothingNeedsYou, noAgents, notRunning, notInstalled, tooOld(version: String)

        var text: String {
            switch self {
            case .connecting: "Connecting to Herdr…"
            case .nothingNeedsYou: "Nothing Needs You"
            case .noAgents: "No Agents Running"
            case .notRunning: "Herdr Isn't Running"
            case .notInstalled: "Herdr Isn't Installed"
            case .tooOld(let version): "Herdr \(version) Is Too Old"
            }
        }
    }

    var notice: Notice?
    var needsYou: [AgentRow] = []
    var working: [AgentRow] = []
    var idle: [AgentRow] = []
    var problems: [MachineProblem] = []
    /// Blocked plus done agents: the number next to the menu bar icon.
    var attention = 0
    var anyBlocked = false
    /// herdr can't be used: the menu bar icon shows its unavailable variant.
    var herdrDown = false
    var tooltip = ""
    /// Set while notifications are paused from the menu.
    var pausedUntil: Date?
}

enum MenuRows {
    /// Remote machines need 0.9.1 for `--machine`; that is checked per machine.
    static let minimumHerdrVersion = "0.9.0"
    static let titleLimit = 44
    /// `herdr update` restarts the server; a short outage should not flash the unavailable icon.
    static let downGrace: TimeInterval = 3

    static func localState(machine: Machine?, herdrInstalled: Bool, now: Date,
                           minimumVersion: String = minimumHerdrVersion) -> LocalState {
        guard let machine else { return .connecting }
        if let firstFailure = machine.firstFailure, now.timeIntervalSince(firstFailure) >= downGrace {
            return herdrInstalled ? .notRunning : .notInstalled
        }
        guard machine.lastSuccess != nil else { return .connecting }
        if let version = machine.serverVersion, !isVersion(version, atLeast: minimumVersion) {
            return .tooOld(version: version)
        }
        return .live
    }

    /// While the local herdr can't be used, the menu says why and still lists the saved machines' agents.
    static func model(fleet: Fleet, local: LocalState, now: Date) -> MenuModel {
        var model = MenuModel()
        switch local {
        case .connecting:
            model.notice = .connecting
            model.tooltip = "Connecting to Herdr"
        case .notRunning:
            model.notice = .notRunning
            model.herdrDown = true
            model.tooltip = "Herdr isn't running"
        case .notInstalled:
            model.notice = .notInstalled
            model.herdrDown = true
            model.tooltip = "Herdr isn't installed"
        case .tooOld(let version):
            model.notice = .tooOld(version: version)
            model.herdrDown = true
            model.tooltip = "Herdr \(version) is too old"
        case .live:
            break
        }

        let agents = fleet.agents.filter { local == .live || $0.key.machine != Fleet.local }
        let rows = Dictionary(uniqueKeysWithValues: rows(for: agents, now: now).map { ($0.key, $0) })
        let waiting = agents.filter(\.status.needsYou).sorted(by: needsYouOrder)
        let working = agents.filter { $0.status == .working }.sorted(by: workspaceOrder)
        let idle = agents.filter { $0.status == .idle || $0.status == .unknown }.sorted(by: idleOrder)

        model.needsYou = waiting.compactMap { rows[$0.key] }
        model.working = working.compactMap { rows[$0.key] }
        model.idle = idle.compactMap { rows[$0.key] }
        model.attention = waiting.count
        model.anyBlocked = waiting.contains { $0.status == .blocked }
        model.problems = problems(fleet, now: now)
        if local == .live {
            model.notice = agents.isEmpty ? .noAgents : waiting.isEmpty ? .nothingNeedsYou : nil
            model.tooltip = tooltip(needsYou: waiting.count, working: working.count, idle: idle.count)
        }
        for problem in model.problems {
            model.tooltip += problem.detail == RemoteFailure.needsNewerHerdr.description
                ? " · \(problem.label) needs herdr 0.9.1" : " · \(problem.label) can't connect"
        }
        return model
    }

    /// Saved machines whose last few checks failed. Their agents are hidden and not counted: you can't
    /// reach them anyway.
    static func problems(_ fleet: Fleet, now: Date) -> [MachineProblem] {
        fleet.machines.values
            .filter { $0.label != Fleet.local && $0.failures > Fleet.toleratedFailures }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            .map { machine in
                var detail = machine.lastError ?? RemoteFailure.cantConnect.description
                if detail == RemoteFailure.cantConnect.description, let seen = machine.lastSuccess {
                    let ago = duration(since: seen, now: now)
                    detail += ago == "now" ? " · last seen just now" : " · last seen \(ago) ago"
                }
                return MachineProblem(label: machine.label, detail: detail)
            }
    }

    // MARK: Rows

    /// Rows that would read the same get their tab number, so they can be told apart.
    static func rows(for agents: [Agent], now: Date) -> [AgentRow] {
        var rows = agents.map { AgentRow(key: $0.key, status: $0.status, title: title(for: $0), subtitle: subtitle(for: $0, now: now)) }
        let counts = Dictionary(rows.map { ("\($0.title)\n\($0.subtitle)", 1) }, uniquingKeysWith: +)
        for index in rows.indices where counts["\(rows[index].title)\n\(rows[index].subtitle)", default: 0] > 1 {
            rows[index].subtitle += " · tab \(agents[index].tabNumber)"
        }
        return rows
    }

    static func title(for agent: Agent) -> String {
        for candidate in [agent.name, agent.metadataTitle] {
            if let text = candidate?.trimmingCharacters(in: .whitespaces), !text.isEmpty { return truncate(text) }
        }
        if let raw = agent.terminalTitle,
           let cleaned = cleanTitle(raw, workspace: agent.workspaceLabel, folder: agent.cwd.map(folderName)),
           !isNoise(cleaned, kind: agent.kind) {
            return truncate(cleaned)
        }
        return agentName(agent)
    }

    private static let statusPhrases: Set<String> = ["action required", "working", "thinking", "ready", "done"]

    /// Removes what the row already shows elsewhere: a leading spinner such as `[ . ]`, a leading status
    /// phrase, and a trailing project name.
    static func cleanTitle(_ raw: String, workspace: String, folder: String?) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let spinner = text.firstMatch(of: /^\[\s*\S?\s*\]\s*/) { text.removeSubrange(spinner.range) }
        var parts = text.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 1, statusPhrases.contains(parts[0].lowercased()) { parts.removeFirst() }
        if parts.count > 1, let last = parts.last?.lowercased(),
           last == workspace.lowercased() || last == folder?.lowercased() {
            parts.removeLast()
        }
        let result = parts.joined(separator: " | ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    /// A shell prompt ("dev@devbox:~") or the bare agent kind says nothing about the task.
    private static func isNoise(_ title: String, kind: String?) -> Bool {
        if let kind, title.lowercased() == kind.lowercased() { return true }
        return title.firstMatch(of: /^[\w.-]+@[\w.-]+:/) != nil
    }

    static func truncate(_ text: String, limit: Int = titleLimit) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit - 1)
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space]) + "…"
        }
        return String(head) + "…"
    }

    static func agentName(_ agent: Agent) -> String {
        if let display = agent.displayAgent?.trimmingCharacters(in: .whitespaces), !display.isEmpty { return display }
        guard let kind = agent.kind, let first = kind.first else { return "Agent" }
        return first.uppercased() + kind.dropFirst()
    }

    static func subtitle(for agent: Agent, now: Date) -> String {
        var parts = [agent.key.machine == Fleet.local ? agent.workspaceLabel : "\(agent.workspaceLabel) on \(agent.key.machine)",
                     agentName(agent)]
        if let since = agent.since { parts.append(duration(since: since, now: now)) }
        return parts.joined(separator: " · ")
    }

    static func duration(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    static func tooltip(needsYou: Int, working: Int, idle: Int) -> String {
        if needsYou + working + idle == 0 { return "No agents running" }
        var parts = [needsYou == 0 ? "Nothing needs you" : needsYou == 1 ? "1 needs you" : "\(needsYou) need you"]
        if working > 0 { parts.append("\(working) working") }
        if idle > 0 { parts.append("\(idle) idle") }
        return parts.joined(separator: " · ")
    }

    /// Where the "next agent that needs you" hotkey goes: the top of Needs You, or the agent after the one
    /// it went to last, wrapping around.
    static func nextWaiting(in model: MenuModel, after last: AgentKey?) -> AgentKey? {
        let keys = model.needsYou.map(\.key)
        guard let first = keys.first else { return nil }
        guard let last, let index = keys.firstIndex(of: last) else { return first }
        return keys[(index + 1) % keys.count]
    }

    // MARK: Ordering

    /// Blocked before done. Oldest first: agents that were already waiting when Herdrbar started come
    /// first, in herdr's server-wide `state_change_seq` order.
    static func needsYouOrder(_ a: Agent, _ b: Agent) -> Bool {
        if a.status != b.status { return a.status == .blocked }
        switch (a.since, b.since) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(x), .some(y)) where x != y: return x < y
        default: break
        }
        if a.stateChangeSeq != b.stateChangeSeq { return a.stateChangeSeq < b.stateChangeSeq }
        return a.key.terminalID < b.key.terminalID
    }

    /// herdr's own order: machine (local first), workspace, then tab.
    static func workspaceOrder(_ a: Agent, _ b: Agent) -> Bool {
        let machineA = a.key.machine == Fleet.local ? "" : a.key.machine
        let machineB = b.key.machine == Fleet.local ? "" : b.key.machine
        if machineA != machineB { return machineA < machineB }
        if a.workspaceNumber != b.workspaceNumber { return a.workspaceNumber < b.workspaceNumber }
        if a.tabNumber != b.tabNumber { return a.tabNumber < b.tabNumber }
        return a.key.terminalID < b.key.terminalID
    }

    static func idleOrder(_ a: Agent, _ b: Agent) -> Bool {
        let byWorkspace = a.workspaceLabel.localizedStandardCompare(b.workspaceLabel)
        if byWorkspace != .orderedSame { return byWorkspace == .orderedAscending }
        return workspaceOrder(a, b)
    }

    private static func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
