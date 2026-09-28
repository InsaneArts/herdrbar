import Foundation
import Testing
@testable import Herdrbar

@Suite struct WireTests {
    @Test func decodesARealSnapshot() throws {
        let snapshot = try decodeSnapshotReply(try Fixtures.data("snapshot"))
        #expect(snapshot.version == "0.9.0")
        #expect(snapshot.workspaces.count == 8)
        #expect(snapshot.panes.count == 20)
        #expect(snapshot.agents.count == 15)
        let statuses = Dictionary(grouping: snapshot.agents, by: \.status).mapValues(\.count)
        #expect(statuses == [.blocked: 2, .working: 3, .idle: 10])
        // `name` and the metadata `title` are left out when unset; the task lives in the terminal title.
        #expect(snapshot.agents.allSatisfy { $0.name == nil && $0.title == nil })
        #expect(snapshot.agents.allSatisfy { $0.terminalTitleStripped != nil })
    }

    @Test func unknownStatusDecodesAsUnknown() throws {
        let line = Data(#"{"id":"x","result":{"type":"session_snapshot","snapshot":{"version":"9.9.9","workspaces":[],"tabs":[],"panes":[],"agents":[{"terminal_id":"t","pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent_status":"paused","focused":false,"revision":0,"brand_new_field":{"x":1}}]}}}"#.utf8)
        let snapshot = try decodeSnapshotReply(line)
        #expect(snapshot.agents.first?.status == .unknown)
        #expect(snapshot.agents.first?.stateChangeSeq == nil)
    }

    @Test func errorReplyThrowsHerdrsError() {
        let line = Data(#"{"id":"stale:sub:1:probe","error":{"code":"pane_not_found","message":"pane w999:p999 not found"}}"#.utf8)
        #expect(throws: HerdrError(code: "pane_not_found", message: "pane w999:p999 not found")) {
            try decodeSnapshotReply(line)
        }
    }

    @Test func unknownMethodErrorHasAnEmptyID() {
        let line = Data(#"{"id":"","error":{"code":"invalid_request","message":"unknown method"}}"#.utf8)
        #expect(throws: HerdrError.self) { try decodeReply(line, as: Pong.self) }
    }

    @Test func subscribeParamsCoverEveryPane() throws {
        let data = try JSONEncoder().encode(SubscribeParams(paneIDs: ["w2:p1", "w1:p1"]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]])
        let subscriptions = try #require(object["subscriptions"])
        let perPane = subscriptions.filter { $0["type"] == "pane.agent_status_changed" }.map { $0["pane_id"] }
        #expect(perPane == ["w1:p1", "w2:p1"])
        #expect(!subscriptions.contains { $0["type"] == "pane.updated" })
        #expect(subscriptions.filter { $0["pane_id"] == nil }.count == 7)
    }

    @Test(arguments: [
        ("0.9.1", "0.9.1", true), ("0.9.0", "0.9.1", false), ("0.10.0", "0.9.1", true),
        ("1.0.0-beta", "0.9.1", true), ("0.9", "0.9.1", false), ("0.9.1.1", "0.9.1", true),
    ])
    func versionComparison(version: String, minimum: String, expected: Bool) {
        #expect(isVersion(version, atLeast: minimum) == expected)
    }
}
