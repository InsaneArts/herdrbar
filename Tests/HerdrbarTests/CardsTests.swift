import AppKit
import Testing
@testable import Herdrbar

@Suite struct CardLayoutTests {
    private let area = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func theNewestCardSitsInTheCornerAndOlderOnesStackAway() {
        let first = CardLayout.cardFrame(index: 0, corner: .topRight, in: area)
        #expect(first.maxX == area.maxX - CardLayout.edge)
        #expect(first.maxY == area.maxY - CardLayout.edge)
        let second = CardLayout.cardFrame(index: 1, corner: .topRight, in: area)
        #expect(second.maxY == first.minY - CardLayout.gap)
        #expect(second.minX == first.minX)
    }

    @Test func bottomCornersStackUpwards() {
        let first = CardLayout.cardFrame(index: 0, corner: .bottomLeft, in: area)
        #expect(first.minX == area.minX + CardLayout.edge)
        #expect(first.minY == area.minY + CardLayout.edge)
        #expect(CardLayout.cardFrame(index: 1, corner: .bottomLeft, in: area).minY == first.maxY + CardLayout.gap)
    }

    @Test func topCenterIsCentred() {
        #expect(CardLayout.cardFrame(index: 0, corner: .topCenter, in: area).midX == area.midX)
    }

    @Test func aCardSlidesToItsNewSlotWithASmallOvershoot() {
        #expect(CardLayout.slide(0) == 0)
        #expect(abs(CardLayout.slide(1) - 1) < 1e-9)
        let path = (1...99).map { CardLayout.slide(Double($0) / 100) }
        #expect(path.max()! > 1 && path.max()! < 1.1)  // past the slot, a little, then back
        #expect(zip(path, path.dropFirst()).prefix(60).allSatisfy { $0 < $1 })  // no step back on the way
        let a = CGRect(x: 0, y: 0, width: 10, height: 10), b = CGRect(x: 100, y: 50, width: 10, height: 10)
        #expect(CardLayout.mix(a, b, 0.5) == CGRect(x: 50, y: 25, width: 10, height: 10))
    }

    @Test func thePanelLeavesRoomForTheShadowAndTheSquash() {
        let card = CardLayout.cardFrame(index: 0, corner: .topLeft, in: area)
        #expect(CardLayout.panelFrame(index: 0, corner: .topLeft, in: area) == card.insetBy(dx: -CardLayout.padding, dy: -CardLayout.padding))
    }
}

@Suite struct CardCopyTests {
    @Test func everyLineNamesTheAgent() {
        for variant in -3...10 {
            for (blocked, reminder) in [(true, false), (false, false), (true, true)] {
                #expect(CardCopy.headline(name: "Codex", blocked: blocked, reminder: reminder, variant: variant).contains("Codex"))
            }
        }
    }

    @Test func theFirstLinesSayPlainlyWhatHappened() {
        #expect(CardCopy.headline(name: "Codex", blocked: true, reminder: false, variant: 0) == "Codex needs you")
        #expect(CardCopy.headline(name: "Claude", blocked: false, reminder: false, variant: 0) == "Claude is done")
        #expect(CardCopy.headline(name: "Codex", blocked: true, reminder: true, variant: 0) == "Codex is still waiting")
    }

    @Test func aCardShowsTheTaskAndWhere() {
        let agent = Agent(key: AgentKey(machine: "omarchy", terminalID: "t1"), paneID: "w1:p1", status: .blocked, kind: "codex",
                          displayAgent: nil, name: nil, metadataTitle: nil, terminalTitle: "Add rate limiting", cwd: nil,
                          workspaceLabel: "api", workspaceNumber: 1, tabNumber: 1, stateChangeSeq: 0, since: nil)
        let card = CardContent(AgentNotice(agent: agent), variant: 0)
        #expect(card == CardContent(blocked: true, headline: "Codex needs you", detail: "Add rate limiting", place: "api on omarchy"))
        var untitled = agent
        untitled.terminalTitle = nil
        untitled.status = .done
        #expect(CardContent(AgentNotice(agent: untitled), variant: 0).detail == "Ready for the next task.")
    }
}

@Suite struct CardPreferencesTests {
    @Test func cardsAreOnByDefaultAndSettingsPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "CardPreferencesTests-\(UUID())"))
        #expect(CardPreferences.load(defaults) == CardPreferences())
        #expect(CardPreferences().enabled)
        let changed = CardPreferences(enabled: false, corner: .bottomLeft, display: .pointer, layer: .desktop, everySpace: false)
        changed.save(defaults)
        #expect(CardPreferences.load(defaults) == changed)
    }
}
