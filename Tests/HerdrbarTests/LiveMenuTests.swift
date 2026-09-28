import Foundation
import Testing
@testable import Herdrbar

/// Prints the menu Herdrbar would show for your running herdr session. Read-only: it only takes one
/// `session.snapshot`. Opt in with HERDRBAR_LIVE=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDRBAR_LIVE"] == "1"))
struct LiveMenuTests {
    @Test func printsTheMenuForTheRunningSession() async throws {
        let snapshot = try await Herdr.snapshot(socket: HerdrInstall.locate().socketPath)
        var fleet = Fleet()
        _ = fleet.apply(.success(snapshot), machine: Fleet.local, now: .now)
        let model = MenuRows.model(fleet: fleet, local: .live, now: .now)
        var lines = ["herdr \(snapshot.version) · \(model.tooltip)"]
        if let notice = model.notice { lines.append(notice.text) }
        for (header, rows) in [("Needs You", model.needsYou), ("Working", model.working), ("Idle", model.idle)] where !rows.isEmpty {
            lines.append(header)
            lines += rows.map { "  [\($0.status.rawValue)] \($0.title)\n      \($0.subtitle)" }
        }
        print(lines.joined(separator: "\n"))
        #expect(model.attention == snapshot.agents.filter(\.status.needsYou).count)
    }

    @MainActor @Test func printsTheHerdrClientsAndTheirTerminals() {
        for client in ClientLocator.localClients() {
            print("client pid \(client.pid) tty \(client.tty ?? "-") host \(client.hostBundleID ?? "-") pid \(client.hostPID.map(String.init) ?? "-")")
        }
    }

    @Test func printsPeekForTheWaitingAgents() async throws {
        struct Params: Encodable, Sendable { var target: String; var source = "detection" }
        let socket = HerdrInstall.locate().socketPath
        let snapshot = try await Herdr.snapshot(socket: socket)
        for agent in snapshot.agents where agent.status.needsYou {
            let line = try await Herdr.call("agent.read", Params(target: agent.paneID), socket: socket)
            let lines = Peek.lines(from: try decodeReply(line, as: AgentReadResult.self).read.text)
            print("=== peek \(agent.paneID) (\(lines.count) lines)\n" + lines.joined(separator: "\n"))
        }
    }
}

