import Foundation

/// What one agent's notification says. Decided without touching the notification center, for tests.
struct AgentNotice: Equatable, Sendable {
    var key: AgentKey
    var identifier: String
    var title: String
    var body: String
    var playsSound: Bool

    init(agent: Agent) {
        key = agent.key
        identifier = Self.identifier(agent.key)
        let name = MenuRows.agentName(agent)
        let place = agent.key.machine == Fleet.local ? agent.workspaceLabel : "\(agent.workspaceLabel) on \(agent.key.machine)"
        let task = MenuRows.title(for: agent)
        let blocked = agent.status == .blocked
        if task == name {
            // No usable task title: say who and where instead.
            title = "\(name) in \(place)"
            body = blocked ? "Needs you." : "Finished."
        } else {
            title = task
            body = blocked ? "\(name) needs you in \(place)." : "\(name) finished in \(place)."
        }
        playsSound = blocked
    }

    /// One notification per agent: a newer one replaces the older one.
    static func identifier(_ key: AgentKey) -> String { "\(key.machine)/\(key.terminalID)" }
}

/// Posts a notification when an agent starts needing you and takes it back when that ends, so
/// Notification Center always matches the Needs You section.
@MainActor
final class Notifier {
    struct Environment {
        var post: (AgentNotice) -> Void
        var remove: ([String]) -> Void
        var currentAgent: (AgentKey) -> Agent?
        /// True while herdr's window is in front: herdr's own UI shows the change.
        var herdrIsFrontmost: () async -> Bool
        var notifyDone: () -> Bool
        /// herdr waits a second before its own alerts; a state that flickers never notifies.
        var confirmDelay: Duration = .seconds(1)
    }

    private let environment: Environment
    private var pending: [AgentKey: Task<Void, Never>] = [:]

    init(_ environment: Environment) {
        self.environment = environment
    }

    func handle(_ transitions: Transitions) {
        for key in transitions.resolved { withdraw(key) }
        for agent in transitions.needsYou where agent.status == .blocked || environment.notifyDone() {
            let key = agent.key, status = agent.status
            pending[key]?.cancel()
            pending[key] = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: environment.confirmDelay)
                guard !Task.isCancelled else { return }
                pending[key] = nil
                guard let current = environment.currentAgent(key), current.status == status,
                      await !environment.herdrIsFrontmost() else { return }
                environment.post(AgentNotice(agent: current))
            }
        }
    }

    /// Takes back a waiting or delivered notification: the agent no longer needs you, or you went to it.
    func withdraw(_ key: AgentKey) {
        pending.removeValue(forKey: key)?.cancel()
        environment.remove([AgentNotice.identifier(key)])
    }
}
