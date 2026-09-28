import Foundation
import Testing
@testable import Herdrbar

@Suite struct JumpTests {
    @Test(arguments: [("w14:pV", true), ("term_65c21b8a3f80b1", true), ("w1:p1; rm -rf ~", false),
                      ("-w1:p1", false), ("", false), ("$(reboot)", false)])
    func onlyPlainIDsAreUsed(id: String, safe: Bool) {
        #expect(isSafeID(id) == safe)
    }

    @MainActor @Test func theClientInTheLastUsedTerminalWins() {
        let jump = Jump()
        let ghostty = HerdrClient(pid: 100, tty: nil, environment: [:], hostPID: 10, hostBundleID: Terminals.ghostty)
        let kitty = HerdrClient(pid: 200, tty: nil, environment: [:], hostPID: 20, hostBundleID: "net.kovidgoyal.kitty")
        let tmux = HerdrClient(pid: 300, tty: nil, environment: [:], hostPID: nil, hostBundleID: nil)
        jump.lastActive = [10: .now, 20: .now.addingTimeInterval(-60)]
        #expect(jump.mostRecentlyUsed([ghostty, kitty, tmux])?.pid == 100)
        jump.lastActive = [10: .now.addingTimeInterval(-60), 20: .now]
        #expect(jump.mostRecentlyUsed([ghostty, kitty, tmux])?.pid == 200)
        jump.lastActive = [:]
        #expect(jump.mostRecentlyUsed([ghostty, kitty])?.pid == 200)  // no history: the newest client
        #expect(jump.mostRecentlyUsed([tmux]) == nil)
    }
}
