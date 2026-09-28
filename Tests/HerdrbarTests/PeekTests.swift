import Foundation
import Testing
@testable import Herdrbar

@Suite struct PeekTests {
    @Test func keepsTheBottomOfTheScreen() {
        let screen = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n\n\n"
        let lines = Peek.lines(from: screen)
        #expect(lines.count == Peek.lineLimit)
        #expect(lines.first == "line 15")
        #expect(lines.last == "line 30")
    }

    @Test func tidiesStatusBarsAndLongLines() {
        let screen = "\n\n› Ask Codex to do anything   \n  GPT xhigh · ~/code/api" + String(repeating: " ", count: 60) + "⚠ 6 warnings\n"
            + String(repeating: "x", count: 200)
        let lines = Peek.lines(from: screen)
        #expect(lines[0] == "› Ask Codex to do anything")
        #expect(lines[1] == "  GPT xhigh · ~/code/api   ⚠ 6 warnings")
        #expect(lines[2].count == Peek.widthLimit && lines[2].hasSuffix("…"))
    }

    @Test func emptyScreensStayEmpty() {
        #expect(Peek.lines(from: "\n\n  \n").isEmpty)
    }

    @Test func decodesTheReadReply() throws {
        let line = Data(#"{"id":"r","result":{"type":"pane_read","read":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","source":"detection","format":"text","text":"a\nb","revision":3,"truncated":false}}}"#.utf8)
        #expect(try decodeReply(line, as: AgentReadResult.self).read.text == "a\nb")
    }
}
