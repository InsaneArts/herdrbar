import AppKit
import Testing
@testable import Herdrbar

@MainActor @Suite struct TerminalsTests {
    @Test(arguments: [("/dev/ttys002", true), ("/dev/ttys012", true), ("/dev/tty", false),
                      ("/dev/ttys002; rm -rf ~", false), ("ttys002", false), ("/dev/../etc/ttys", false)])
    func onlyRealTTYsAreUsed(tty: String, safe: Bool) {
        #expect(Terminals.isSafeTTY(tty) == safe)
    }

    @Test func kittyNeedsItsRemoteControlAddress() {
        let app = URL(fileURLWithPath: "/Applications/kitty.app")
        #expect(Terminals.kittyCommand(environment: ["KITTY_LISTEN_ON": "unix:/tmp/kitty", "KITTY_WINDOW_ID": "7"], kittyApp: app)
            == ["/Applications/kitty.app/Contents/MacOS/kitten", "@", "--to", "unix:/tmp/kitty", "focus-window", "--match", "id:7"])
        #expect(Terminals.kittyCommand(environment: ["KITTY_WINDOW_ID": "7"], kittyApp: app) == nil)  // remote control off
        #expect(Terminals.kittyCommand(environment: ["KITTY_LISTEN_ON": "unix:/tmp/kitty", "KITTY_WINDOW_ID": "7; ls"], kittyApp: app) == nil)
        #expect(Terminals.kittyCommand(environment: ["KITTY_LISTEN_ON": "/tmp/kitty", "KITTY_WINDOW_ID": "7"], kittyApp: app) == nil)
    }

    @Test func eachTerminalOpensHerdrItsOwnWay() {
        let herdr = "/opt/homebrew/bin/herdr"
        #expect(Terminals.openPlan(for: Terminals.ghostty, herdr: herdr) == .newInstance(arguments: ["-e", herdr]))
        #expect(Terminals.openPlan(for: Terminals.alacritty, herdr: herdr) == .newInstance(arguments: ["-e", herdr]))
        #expect(Terminals.openPlan(for: Terminals.kitty, herdr: herdr) == .newInstance(arguments: [herdr]))
        #expect(Terminals.openPlan(for: Terminals.terminal, herdr: herdr) == .commandFile)
        #expect(Terminals.openPlan(for: Terminals.iTerm, herdr: herdr) == .iTermScript)
        #expect(Terminals.openPlan(for: "com.github.wez.wezterm", herdr: herdr) == nil)
    }
}
