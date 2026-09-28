import AppKit
import Carbon.HIToolbox
import Testing
@testable import Herdrbar

@Suite struct HotkeyTests {
    @Test func nextWaitingCyclesThroughNeedsYou() {
        let keys = ["a", "b", "c"].map { AgentKey(machine: Fleet.local, terminalID: $0) }
        let model = MenuModel(needsYou: keys.map { AgentRow(key: $0, status: .blocked, title: "", subtitle: "") })
        #expect(MenuRows.nextWaiting(in: model, after: nil) == keys[0])
        #expect(MenuRows.nextWaiting(in: model, after: keys[0]) == keys[1])
        #expect(MenuRows.nextWaiting(in: model, after: keys[2]) == keys[0])
        #expect(MenuRows.nextWaiting(in: model, after: AgentKey(machine: Fleet.local, terminalID: "gone")) == keys[0])
        #expect(MenuRows.nextWaiting(in: MenuModel(), after: nil) == nil)
    }

    @Test func shortcutsNeedARealModifier() throws {
        let shortcut = try #require(Shortcut(keyCode: UInt16(kVK_ANSI_H), flags: [.command, .option], characters: "h"))
        #expect(shortcut.display == "⌥⌘H")
        #expect(shortcut.modifiers == UInt32(cmdKey | optionKey))
        #expect(Shortcut(keyCode: UInt16(kVK_ANSI_H), flags: [.shift], characters: "h") == nil)
        #expect(Shortcut(keyCode: UInt16(kVK_ANSI_H), flags: [], characters: "h") == nil)
    }

    @Test func specialKeysHaveNames() {
        #expect(Shortcut(keyCode: UInt16(kVK_F5), flags: [.control], characters: nil)?.display == "⌃F5")
        #expect(Shortcut(keyCode: UInt16(kVK_Space), flags: [.control, .shift, .command], characters: " ")?.display == "⌃⇧⌘Space")
    }
}
