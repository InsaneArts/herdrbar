import Foundation
import Testing
@testable import Herdrbar

@Suite struct FleetTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let local = Fleet.local

    private func key(_ terminal: String) -> AgentKey { AgentKey(machine: Fleet.local, terminalID: terminal) }

    @Test func firstSnapshotIsASilentBaseline() {
        var fleet = Fleet()
        let transitions = fleet.apply(.success(makeSnapshot([
            TestAgent(terminal: "a", pane: "w1:p1", status: .blocked),
            TestAgent(terminal: "b", pane: "w1:p2", status: .done),
        ])), machine: local, now: t0)
        #expect(transitions == Transitions())
        #expect(fleet.agents.count == 2)
        #expect(fleet.agents.allSatisfy { $0.since == nil })
    }

    @Test func becomingBlockedNeedsYouAndStartsTheClock() throws {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .working)])), machine: local, now: t0)
        let later = t0.addingTimeInterval(90)
        let transitions = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .blocked)])),
                                      machine: local, now: later)
        #expect(transitions.needsYou.map(\.key) == [key("a")])
        #expect(transitions.resolved.isEmpty)
        #expect(try #require(fleet.agent(key("a"))).since == later)
    }

    @Test(arguments: [AgentStatus.working, .idle, .unknown])
    func leavingBlockedResolves(next: AgentStatus) {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .working)])), machine: local, now: t0)
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .blocked)])), machine: local, now: t0)
        let transitions = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: next)])),
                                      machine: local, now: t0)
        #expect(transitions == Transitions(resolved: [key("a")]))
    }

    @Test func seeingADoneAgentResolvesIt() {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .done)])), machine: local, now: t0)
        let transitions = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .idle)])),
                                      machine: local, now: t0)
        #expect(transitions == Transitions(resolved: [key("a")]))
    }

    @Test func aNewAgentNeverNotifiesButItsClockStarts() throws {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot([])), machine: local, now: t0)
        let later = t0.addingTimeInterval(5)
        let transitions = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .blocked)])),
                                      machine: local, now: later)
        #expect(transitions == Transitions())
        #expect(try #require(fleet.agent(key("a"))).since == later)
    }

    @Test func anAgentThatVanishesWhileWaitingResolves() {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .blocked)])), machine: local, now: t0)
        let transitions = fleet.apply(.success(makeSnapshot([])), machine: local, now: t0)
        #expect(transitions == Transitions(resolved: [key("a")]))
    }

    @Test func theClockKeepsRunningWhileTheStatusHolds() throws {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .idle)])), machine: local, now: t0)
        let start = t0.addingTimeInterval(10)
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .working)])), machine: local, now: start)
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p2", status: .working)])),
                        machine: local, now: t0.addingTimeInterval(60))
        let agent = try #require(fleet.agent(key("a")))
        #expect(agent.since == start)
        #expect(agent.paneID == "w1:p2")  // a pane move keeps the agent's identity
    }

    @Test func agentsSurviveTwoFailuresAndHideOnTheThird() {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot([TestAgent(terminal: "a", pane: "w1:p1", status: .working)])), machine: local, now: t0)
        struct Down: Error {}
        _ = fleet.apply(.failure(Down()), machine: local, now: t0)
        _ = fleet.apply(.failure(Down()), machine: local, now: t0)
        #expect(fleet.agents.count == 1)
        _ = fleet.apply(.failure(Down()), machine: local, now: t0)
        #expect(fleet.agents.isEmpty)
        #expect(fleet.machines[local]?.firstFailure == t0)
    }

    @Test func aReconnectOnlyNotifiesAboutRealChanges() {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot([
            TestAgent(terminal: "a", pane: "w1:p1", status: .blocked),
            TestAgent(terminal: "b", pane: "w1:p2", status: .working),
        ])), machine: local, now: t0)
        struct Down: Error {}
        for _ in 0..<3 { _ = fleet.apply(.failure(Down()), machine: local, now: t0) }
        let transitions = fleet.apply(.success(makeSnapshot([
            TestAgent(terminal: "a", pane: "w1:p1", status: .blocked),  // unchanged: silent
            TestAgent(terminal: "b", pane: "w1:p2", status: .blocked),  // changed during the outage
        ])), machine: local, now: t0)
        #expect(transitions.needsYou.map(\.key) == [key("b")])
        #expect(fleet.machines[local]?.firstFailure == nil)
    }
}
