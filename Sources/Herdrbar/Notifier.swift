import Foundation

/// What one agent's notification says. Decided without touching the notification center, for tests.
struct AgentNotice: Equatable, Sendable {
    var key: AgentKey
    var identifier: String
    var title: String
    var body: String
    var playsSound: Bool

    /// `reminder` is the one follow-up for an agent that has been waiting a long time.
    init(agent: Agent, reminder: Bool = false) {
        key = agent.key
        identifier = Self.identifier(agent.key)
        let name = MenuRows.agentName(agent)
        let place = agent.key.machine == Fleet.local ? agent.workspaceLabel : "\(agent.workspaceLabel) on \(agent.key.machine)"
        let task = MenuRows.title(for: agent)
        let blocked = agent.status == .blocked
        if task == name {
            // No usable task title: say who and where instead.
            title = "\(name) in \(place)"
            body = reminder ? "Still waiting." : blocked ? "Needs you." : "Finished."
        } else {
            title = task
            body = reminder ? "\(name) is still waiting in \(place)."
                : blocked ? "\(name) needs you in \(place)." : "\(name) finished in \(place)."
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
        var herdrIsFrontmost: @MainActor () async -> Bool
        var notifyDone: () -> Bool
        /// True while the user paused notifications from the menu.
        var paused: () -> Bool = { false }
        /// herdr waits a second before its own alerts; a state that flickers never notifies.
        var confirmDelay: Duration = .seconds(1)
    }

    /// An agent blocked this long gets one reminder.
    static let reminderDelay: TimeInterval = 15 * 60

    private let environment: Environment
    private var pending: [AgentKey: Task<Void, Never>] = [:]
    private var reminded: Set<AgentKey> = []

    init(_ environment: Environment) {
        self.environment = environment
    }

    func handle(_ transitions: Transitions) {
        for key in transitions.resolved {
            reminded.remove(key)
            withdraw(key)
        }
        for agent in transitions.needsYou {
            reminded.remove(agent.key)
            guard agent.status == .blocked || environment.notifyDone() else { continue }
            let key = agent.key, status = agent.status
            pending[key]?.cancel()
            pending[key] = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: environment.confirmDelay)
                guard !Task.isCancelled else { return }
                pending[key] = nil
                guard let current = environment.currentAgent(key), current.status == status,
                      !environment.paused(), await !environment.herdrIsFrontmost() else { return }
                environment.post(AgentNotice(agent: current))
            }
        }
    }

    /// Reminds once about each agent that has been blocked for `reminderDelay`: the first banner may have
    /// been dismissed and forgotten. Only waits Herdrbar saw begin count; a wait that started before
    /// launch has no known length.
    func remind(_ agents: [Agent], now: Date) async {
        for agent in agents where agent.status == .blocked && !reminded.contains(agent.key) {
            guard let since = agent.since, now.timeIntervalSince(since) >= Self.reminderDelay else { continue }
            reminded.insert(agent.key)
            guard !environment.paused(), await !environment.herdrIsFrontmost() else { continue }
            environment.post(AgentNotice(agent: agent, reminder: true))
        }
    }

    /// Takes back a waiting or delivered notification: the agent no longer needs you, or you went to it.
    func withdraw(_ key: AgentKey) {
        pending.removeValue(forKey: key)?.cancel()
        environment.remove([AgentNotice.identifier(key)])
    }
}
