import Foundation
import Testing
@testable import Herdrbar

@Suite struct LineSocketTests {
    private func pair() -> (LineSocket, LineSocket) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (LineSocket(fd: fds[0]), LineSocket(fd: fds[1]))
    }

    @Test func splitsOnNewlineOnlyNotOnU2028() throws {
        let (writer, reader) = pair()
        try writer.send(Data("{\"t\":\"a\u{2028}b\"}\n{\"x\":1}\n".utf8))
        #expect(String(decoding: try reader.readLine(), as: UTF8.self) == "{\"t\":\"a\u{2028}b\"}")
        #expect(String(decoding: try reader.readLine(), as: UTF8.self) == "{\"x\":1}")
    }

    @Test func joinsALineSplitAcrossWrites() throws {
        let (writer, reader) = pair()
        try writer.send(Data("{\"part\":".utf8))
        let thread = Thread {
            Thread.sleep(forTimeInterval: 0.05)
            try? writer.send(Data("1}\n".utf8))
        }
        thread.start()
        #expect(String(decoding: try reader.readLine(), as: UTF8.self) == "{\"part\":1}")
    }

    @Test func refusesAFrameOverTheLimit() throws {
        let (writer, reader) = pair()
        try writer.send(Data(repeating: 0x41, count: 100))
        #expect(throws: SocketError.frameTooLarge) { try reader.readLine(limit: 10) }
    }

    @Test func reportsEndOfStream() throws {
        let (writer, reader) = pair()
        writer.shutdown()
        #expect(throws: SocketError.closed) { try reader.readLine() }
    }

    @Test func shutdownWakesABlockedReader() async throws {
        let (writer, reader) = pair()  // the open writer keeps the reader blocked
        let finished = Flag()
        let thread = Thread {
            _ = try? reader.readLine()
            finished.set()
        }
        thread.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!finished.isSet)
        reader.shutdown()
        #expect(await eventually(timeout: .seconds(1)) { finished.isSet })
        withExtendedLifetime(writer) {}
    }

    @Test func connectFailsWithoutAServer() {
        let path = FileManager.default.temporaryDirectory.appending(path: "hb-missing-\(UUID().uuidString.prefix(8)).sock").path
        #expect(throws: SocketError.connect(errno: ENOENT)) { try LineSocket(path: path) }
    }
}
