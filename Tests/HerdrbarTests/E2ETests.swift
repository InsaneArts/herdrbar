import Foundation
import Testing
@testable import Herdrbar

/// Runs against a real, throwaway herdr session. Opt in with HERDRBAR_E2E=1. Your default session is
/// never touched: the test starts `herdr --session herdrbar-e2e-… server` and deletes it afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDRBAR_E2E"] == "1"), .serialized)
struct E2ETests {
    struct WorkspaceParams: Encodable, Sendable { var label: String; var focus: Bool }
    struct ReportParams: Encodable, Sendable {
        var pane_id: String, source = "herdrbar-e2e", agent = "claude", state: String
    }

    @Test func statusChangesReachTheMenuWithinHalfASecond() async throws {
        let session = try HerdrTestSession()
        defer { session.stop() }
        // The first workspace holds herdr's focus. The agent lives in the second, so a finish reports done.
        _ = try await session.call("workspace.create", WorkspaceParams(label: "e2e-front", focus: false))
        let reply = try JSONSerialization.jsonObject(
            with: try await session.call("workspace.create", WorkspaceParams(label: "e2e-back", focus: false))) as? [String: Any]
        let pane = try #require(((reply?["result"] as? [String: Any])?["root_pane"] as? [String: Any])?["pane_id"] as? String)

        let source = LocalSource(socketPath: session.socketPath)
        let recorder = Recorder()
        let task = Task { await source.run { await recorder.append($0) } }
        defer { task.cancel() }
        #expect(await eventually { await recorder.latest != nil })
        try await Task.sleep(for: .milliseconds(300))  // let the subscription settle

        for (state, expected) in [("working", AgentStatus.working), ("blocked", .blocked), ("idle", .done)] {
            let start = ContinuousClock.now
            _ = try await session.call("pane.report_agent", ReportParams(pane_id: pane, state: state))
            let seen = await eventually(timeout: .seconds(2)) {
                await recorder.latest?.agents.first { $0.paneID == pane }?.status == expected
            }
            let elapsed = ContinuousClock.now - start
            #expect(seen, "never saw \(expected)")
            #expect(elapsed < .milliseconds(500), "\(expected) took \(elapsed)")
        }
    }
}

/// A headless herdr server in its own named session, with the caller's HERDR_* variables removed so it
/// cannot reach the session the tests run inside.
final class HerdrTestSession {
    let name = "herdrbar-e2e-\(UUID().uuidString.prefix(6).lowercased())"
    let herdr: String
    let socketPath: String
    private let server = Process()

    init() throws {
        herdr = try #require(HerdrInstall.locate().binary, "herdr is not installed")
        socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/herdr/sessions/\(name)/herdr.sock").path
        server.executableURL = URL(fileURLWithPath: herdr)
        server.arguments = ["--session", name, "server"]
        server.environment = Self.cleanEnvironment
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath) {
            guard Date() < deadline else { throw HerdrError(code: "e2e", message: "session socket never appeared") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func call(_ method: String, _ params: some Encodable & Sendable) async throws -> Data {
        let line = try await Herdr.call(method, params, socket: socketPath)
        if let error = try? JSONDecoder().decode([String: HerdrError].self, from: line)["error"] { throw error }
        return line
    }

    func stop() {
        for arguments in [["session", "stop", name], ["session", "delete", name]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: herdr)
            process.arguments = arguments
            process.environment = Self.cleanEnvironment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        if server.isRunning { server.terminate() }
    }

    private static var cleanEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR_") }
    }
}
