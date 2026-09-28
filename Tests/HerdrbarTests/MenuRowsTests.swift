import Foundation
import Testing
@testable import Herdrbar

@Suite struct MenuRowsTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    private func agent(_ terminal: String, _ status: AgentStatus, title: String? = nil, workspace: String = "api",
                       number: Int = 1, tab: Int = 1, kind: String? = "claude", seq: UInt64 = 0,
                       since: Date? = nil, machine: String = Fleet.local) -> Agent {
        Agent(key: AgentKey(machine: machine, terminalID: terminal), paneID: "p-\(terminal)", status: status,
              kind: kind, displayAgent: nil, name: nil, metadataTitle: nil, terminalTitle: title, cwd: nil,
              workspaceLabel: workspace, workspaceNumber: number, tabNumber: tab, stateChangeSeq: seq, since: since)
    }

    // MARK: Titles

    @Test(arguments: [
        ("[ . ] Action Required | Add rate limiting to the API | api", "Add rate limiting to the API"),
        ("[ ! ] Action Required | Clean up feature flags* | api", "Clean up feature flags*"),
        ("Migrate the blog to Astro | api", "Migrate the blog to Astro"),
        ("Deduplicate the photo library", "Deduplicate the photo library"),
        ("Working | Port settings | other-project", "Port settings | other-project"),
    ])
    func cleansTitles(raw: String, expected: String) {
        #expect(MenuRows.title(for: agent("a", .idle, title: raw)) == expected)
    }

    @Test func dropsATrailingFolderName() {
        var subject = agent("a", .idle, title: "Explain the cache layer | cache-service")
        subject.cwd = "/Users/dev/code/cache-service"
        #expect(MenuRows.title(for: subject) == "Explain the cache layer")
    }

    @Test func fallsBackToTheAgentName() {
        #expect(MenuRows.title(for: agent("a", .idle, title: "dev@devbox:~", kind: "codex")) == "Codex")
        #expect(MenuRows.title(for: agent("a", .idle, title: "claude")) == "Claude")
        #expect(MenuRows.title(for: agent("a", .idle, title: "[ . ]")) == "Claude")
        #expect(MenuRows.title(for: agent("a", .idle, title: nil, kind: nil)) == "Agent")
    }

    @Test func aUserSetNameWins() {
        var subject = agent("a", .idle, title: "Some task")
        subject.name = "reviewer"
        #expect(MenuRows.title(for: subject) == "reviewer")
        subject.name = nil
        subject.metadataTitle = "Refactor auth middleware"
        #expect(MenuRows.title(for: subject) == "Refactor auth middleware")
    }

    @Test func longTitlesStopAtAWord() {
        let title = MenuRows.title(for: agent("a", .idle, title: "Review the tile reading pipeline architecture documentation"))
        #expect(title == "Review the tile reading pipeline…")
        #expect(title.count <= MenuRows.titleLimit)
    }

    // MARK: Subtitles

    @Test func subtitleNamesProjectAgentAndTime() {
        #expect(MenuRows.subtitle(for: agent("a", .blocked, kind: "codex", since: now.addingTimeInterval(-240)), now: now)
            == "api · Codex · 4m")
        #expect(MenuRows.subtitle(for: agent("a", .working, workspace: "dotfiles", machine: "omarchy"), now: now)
            == "dotfiles on omarchy · Claude")
    }

    static let durationCases: [(TimeInterval, String)] = [(30, "now"), (240, "4m"), (3 * 3600 + 59, "3h"), (2 * 86_400 + 5, "2d")]

    @Test(arguments: durationCases)
    func durations(seconds: TimeInterval, expected: String) {
        #expect(MenuRows.duration(since: now.addingTimeInterval(-seconds), now: now) == expected)
    }

    @Test func identicalRowsGetTheirTab() {
        let rows = MenuRows.rows(for: [agent("a", .idle, title: "Fix tests", tab: 1), agent("b", .idle, title: "Fix tests", tab: 2)],
                                 now: now)
        #expect(rows.map(\.subtitle) == ["api · Claude · tab 1", "api · Claude · tab 2"])
    }

    // MARK: Sections

    private func fleet(_ agents: [TestAgent], workspaces: [WorkspaceInfo]) -> Fleet {
        var fleet = Fleet()
        _ = fleet.apply(.success(makeSnapshot(agents, workspaces: workspaces)), machine: Fleet.local, now: now)
        return fleet
    }

    @Test func blockedComesBeforeDoneAndOlderBeforeNewer() {
        let a = agent("a", .done, seq: 1), b = agent("b", .blocked, seq: 9, since: now)
        let c = agent("c", .blocked, seq: 5), d = agent("d", .blocked, seq: 2, since: now.addingTimeInterval(-60))
        let order = [a, b, c, d].sorted(by: MenuRows.needsYouOrder).map(\.key.terminalID)
        #expect(order == ["c", "d", "b", "a"])
    }

    @Test func workingFollowsHerdrsOrder() {
        let order = [agent("x", .working, number: 2, tab: 1), agent("y", .working, number: 1, tab: 3),
                     agent("z", .working, number: 1, tab: 1), agent("r", .working, number: 1, machine: "box")]
            .sorted(by: MenuRows.workspaceOrder).map(\.key.terminalID)
        #expect(order == ["z", "y", "x", "r"])
    }

    @Test func theRealSnapshotMakesTheExpectedMenu() throws {
        var fleet = Fleet()
        _ = fleet.apply(.success(try decodeSnapshotReply(try Fixtures.data("snapshot"))), machine: Fleet.local, now: now)
        let model = MenuRows.model(fleet: fleet, local: .live, now: now)
        #expect(model.notice == nil)
        // Both were blocked before Herdrbar looked, so herdr's state_change_seq decides: site (284) waited longer.
        #expect(model.needsYou.map(\.title) == ["Clean up feature flags*", "Add rate limiting to the API"])
        #expect(model.needsYou.map(\.subtitle) == ["site · Codex", "api · Codex"])
        #expect(model.working.count == 3)
        #expect(model.idle.count == 10)
        #expect(model.idle.map(\.subtitle).allSatisfy { !$0.isEmpty })
        #expect(model.attention == 2)
        #expect(model.anyBlocked)
        #expect(model.tooltip == "2 need you · 3 working · 10 idle")
    }

    @Test func noticesWhenNothingNeedsYouOrNothingRuns() {
        let workspaces = [WorkspaceInfo(workspaceID: "w1", label: "api", number: 1)]
        let quiet = MenuRows.model(fleet: fleet([TestAgent(terminal: "a", pane: "w1:p1", status: .working)], workspaces: workspaces),
                                   local: .live, now: now)
        #expect(quiet.notice == .nothingNeedsYou)
        #expect(quiet.tooltip == "Nothing needs you · 1 working")
        #expect(quiet.attention == 0)
        let empty = MenuRows.model(fleet: fleet([], workspaces: workspaces), local: .live, now: now)
        #expect(empty.notice == .noAgents)
        #expect(empty.tooltip == "No agents running")
    }

    @Test func herdrProblemsReplaceTheAgentList() {
        let workspaces = [WorkspaceInfo(workspaceID: "w1", label: "api", number: 1)]
        let busy = fleet([TestAgent(terminal: "a", pane: "w1:p1", status: .blocked)], workspaces: workspaces)
        for (state, notice) in [(LocalState.notRunning, MenuModel.Notice.notRunning), (.notInstalled, .notInstalled),
                                (.tooOld(version: "0.9.0"), .tooOld(version: "0.9.0"))] {
            let model = MenuRows.model(fleet: busy, local: state, now: now)
            #expect(model.notice == notice)
            #expect(model.herdrDown)
            #expect(model.needsYou.isEmpty && model.attention == 0)
        }
        #expect(MenuModel.Notice.tooOld(version: "0.9.0").text == "Herdr 0.9.0 Is Too Old")
    }

    // MARK: Local state

    @Test func localStateWaitsOutAShortOutage() {
        var machine = Machine(label: Fleet.local)
        #expect(MenuRows.localState(machine: nil, herdrInstalled: true, now: now) == .connecting)
        machine.lastSuccess = now
        machine.serverVersion = "0.9.1"
        #expect(MenuRows.localState(machine: machine, herdrInstalled: true, now: now) == .live)
        machine.firstFailure = now
        #expect(MenuRows.localState(machine: machine, herdrInstalled: true, now: now.addingTimeInterval(2)) == .live)
        #expect(MenuRows.localState(machine: machine, herdrInstalled: true, now: now.addingTimeInterval(3)) == .notRunning)
        #expect(MenuRows.localState(machine: machine, herdrInstalled: false, now: now.addingTimeInterval(3)) == .notInstalled)
    }

    @Test func localStateGatesOldServers() {
        var machine = Machine(label: Fleet.local)
        machine.lastSuccess = now
        machine.serverVersion = "0.8.9"
        #expect(MenuRows.localState(machine: machine, herdrInstalled: true, now: now) == .tooOld(version: "0.8.9"))
        machine.serverVersion = "0.9.0"
        #expect(MenuRows.localState(machine: machine, herdrInstalled: true, now: now) == .live)
    }
}
