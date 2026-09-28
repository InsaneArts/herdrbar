import AppKit
import Testing
@testable import Herdrbar

@Suite struct NoticeTests {
    private func agent(_ status: AgentStatus, title: String?, kind: String = "codex", machine: String = Fleet.local) -> Agent {
        Agent(key: AgentKey(machine: machine, terminalID: "t1"), paneID: "w1:p1", status: status, kind: kind,
              displayAgent: nil, name: nil, metadataTitle: nil, terminalTitle: title, cwd: nil,
              workspaceLabel: "api", workspaceNumber: 1, tabNumber: 1, stateChangeSeq: 0, since: nil)
    }

    @Test func blockedNamesTheTaskAndAsksForYou() {
        let notice = AgentNotice(agent: agent(.blocked, title: "[ . ] Action Required | Add rate limiting | api"))
        #expect(notice.title == "Add rate limiting")
        #expect(notice.body == "Codex needs you in api.")
        #expect(notice.playsSound)
        #expect(notice.identifier == "local/t1")
    }

    @Test func doneIsQuiet() {
        let notice = AgentNotice(agent: agent(.done, title: "Review PR 12"))
        #expect(notice.body == "Codex finished in api.")
        #expect(!notice.playsSound)
    }

    @Test func remoteAgentsSayWhere() {
        #expect(AgentNotice(agent: agent(.blocked, title: "Tune spacing", kind: "claude", machine: "omarchy")).body
            == "Claude needs you in api on omarchy.")
    }

    @Test func aReminderSaysItIsStillWaiting() {
        #expect(AgentNotice(agent: agent(.blocked, title: "Review PR 12"), reminder: true).body == "Codex is still waiting in api.")
        #expect(AgentNotice(agent: agent(.blocked, title: nil), reminder: true).body == "Still waiting.")
    }

    @Test func withoutATaskTitleItSaysWhoAndWhere() {
        let blocked = AgentNotice(agent: agent(.blocked, title: nil))
        #expect(blocked.title == "Codex in api")
        #expect(blocked.body == "Needs you.")
        #expect(AgentNotice(agent: agent(.done, title: "dev@devbox:~")).body == "Finished.")
    }
}

@MainActor @Suite struct NotifierTests {
    final class Spy {
        var posted: [AgentNotice] = []
        var removed: [String] = []
        var agents: [AgentKey: Agent] = [:]
        var herdrInFront = false
        var notifyDone = true
        var paused = false
    }

    private func make(_ spy: Spy) -> Notifier {
        Notifier(.init(post: { spy.posted.append($0) }, remove: { spy.removed += $0 },
                       currentAgent: { spy.agents[$0] }, herdrIsFrontmost: { spy.herdrInFront },
                       notifyDone: { spy.notifyDone }, paused: { spy.paused }, confirmDelay: .milliseconds(30)))
    }

    private func agent(_ id: String, _ status: AgentStatus, since: Date? = nil) -> Agent {
        Agent(key: AgentKey(machine: Fleet.local, terminalID: id), paneID: "w1:\(id)", status: status, kind: "claude",
              displayAgent: nil, name: nil, metadataTitle: nil, terminalTitle: "Task \(id)", cwd: nil,
              workspaceLabel: "api", workspaceNumber: 1, tabNumber: 1, stateChangeSeq: 0, since: since)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }

    /// Waits for a post instead of guessing how long the main actor takes under a parallel test run.
    private func posted(_ spy: Spy, count: Int) async -> Bool {
        for _ in 0..<100 where spy.posted.count < count { try? await Task.sleep(for: .milliseconds(20)) }
        return spy.posted.count == count
    }

    @Test func postsOnceTheStateHolds() async throws {
        let spy = Spy(), notifier = make(spy), blocked = agent("a", .blocked)
        spy.agents[blocked.key] = blocked
        notifier.handle(Transitions(needsYou: [blocked]))
        #expect(spy.posted.isEmpty)  // not before the confirmation delay
        #expect(await posted(spy, count: 1))
        #expect(spy.posted.map(\.title) == ["Task a"])
    }

    @Test func aFlickerNeverNotifies() async throws {
        let spy = Spy(), notifier = make(spy), blocked = agent("a", .blocked)
        spy.agents[blocked.key] = agent("a", .working)  // already moved on when the delay ends
        notifier.handle(Transitions(needsYou: [blocked]))
        try await settle()
        #expect(spy.posted.isEmpty)
    }

    @Test func staysQuietWhileHerdrIsInFront() async throws {
        let spy = Spy(), notifier = make(spy), blocked = agent("a", .blocked)
        spy.agents[blocked.key] = blocked
        spy.herdrInFront = true
        notifier.handle(Transitions(needsYou: [blocked]))
        try await settle()
        #expect(spy.posted.isEmpty)
    }

    @Test func finishedAgentsFollowTheSetting() async throws {
        let spy = Spy(), notifier = make(spy), done = agent("a", .done)
        spy.agents[done.key] = done
        spy.notifyDone = false
        notifier.handle(Transitions(needsYou: [done]))
        try await settle()
        #expect(spy.posted.isEmpty)
        spy.notifyDone = true
        notifier.handle(Transitions(needsYou: [done]))
        #expect(await posted(spy, count: 1))
    }

    @Test func resolvingTakesTheNotificationBack() async throws {
        let spy = Spy(), notifier = make(spy), blocked = agent("a", .blocked)
        spy.agents[blocked.key] = blocked
        notifier.handle(Transitions(needsYou: [blocked]))
        notifier.handle(Transitions(resolved: [blocked.key]))  // resolved inside the delay: nothing is posted
        try await settle()
        #expect(spy.posted.isEmpty)
        #expect(spy.removed == ["local/a"])
        notifier.withdraw(blocked.key)
        #expect(spy.removed == ["local/a", "local/a"])
    }

    @Test func pausedNotificationsStayQuiet() async throws {
        let spy = Spy(), notifier = make(spy), blocked = agent("a", .blocked)
        spy.agents[blocked.key] = blocked
        spy.paused = true
        notifier.handle(Transitions(needsYou: [blocked]))
        try await settle()
        #expect(spy.posted.isEmpty)
    }

    @Test func remindsOnceAfterAQuarterHour() async {
        let spy = Spy(), notifier = make(spy), now = Date.now
        let waiting = agent("a", .blocked, since: now.addingTimeInterval(-Notifier.reminderDelay - 1))
        let fresh = agent("b", .blocked, since: now.addingTimeInterval(-60))
        let unknown = agent("c", .blocked)  // blocked before Herdrbar started: length unknown
        await notifier.remind([waiting, fresh, unknown], now: now)
        #expect(spy.posted.map(\.body) == ["Claude is still waiting in api."])
        await notifier.remind([waiting], now: now.addingTimeInterval(600))
        #expect(spy.posted.count == 1)  // only once

        notifier.withdraw(waiting.key)  // you went to it: still no second reminder
        await notifier.remind([waiting], now: now.addingTimeInterval(1200))
        #expect(spy.posted.count == 1)

        notifier.handle(Transitions(resolved: [waiting.key]))  // answered; a new wait may remind again
        await notifier.remind([waiting], now: now.addingTimeInterval(1800))
        #expect(spy.posted.count == 2)
    }
}
