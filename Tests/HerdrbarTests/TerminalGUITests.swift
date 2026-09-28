import AppKit
import Testing
@testable import Herdrbar

/// Opens real terminal windows. Opt in with HERDRBAR_E2E_GUI=1. The herdr clients attach to a throwaway
/// session, never to your default one.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDRBAR_E2E_GUI"] == "1"), .serialized)
struct TerminalGUITests {
    @MainActor @Test func kittyRemoteControlFocusesTheHerdrWindow() async throws {
        _ = NSApplication.shared
        // The tests run inside herdr; like Herdrbar's main.swift, drop its variables before launching kitty.
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("HERDR_") { unsetenv(key) }
        let kittyApp = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: Terminals.kitty), "kitty is not installed")
        let kitten = kittyApp.appending(path: "Contents/MacOS/kitten").path
        let session = try HerdrTestSession()
        defer { session.stop() }
        let address = "unix:/tmp/hb-kitty-\(UUID().uuidString.prefix(6))"

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--listen-on", address, "-o", "allow_remote_control=socket-only",
                                   session.herdr, "--session", session.name]
        configuration.createsNewApplicationInstance = true
        let kitty = try await NSWorkspace.shared.openApplication(at: kittyApp, configuration: configuration)
        defer { kitty.forceTerminate() }

        var found: HerdrClient?
        for _ in 0..<100 where found == nil {
            try await Task.sleep(for: .milliseconds(100))
            found = ClientLocator.localClients(session: session.name).first { $0.hostBundleID == Terminals.kitty }
        }
        let client = try #require(found, "no herdr client appeared in kitty")
        #expect(client.environment["KITTY_LISTEN_ON"] == address)
        let herdrWindow = try #require(client.environment["KITTY_WINDOW_ID"].flatMap(Int.init))

        // A second window takes the focus away from herdr's.
        _ = try await CLI.run([kitten, "@", "--to", address, "launch", "--type=os-window"], timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await focusedWindow(kitten, address) != herdrWindow)

        await Terminals.raise(client, socket: session.socketPath)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await focusedWindow(kitten, address) == herdrWindow)
    }

    private func focusedWindow(_ kitten: String, _ address: String) async throws -> Int? {
        Terminals.focusedKittyWindow(try await CLI.run([kitten, "@", "--to", address, "ls"], timeout: .seconds(5)))
    }
}
