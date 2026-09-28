import Foundation
import Testing
@testable import Herdrbar

@Suite struct ClientLocatorTests {
    @Test(arguments: [
        (["herdr"], true),
        (["/opt/homebrew/bin/herdr"], true),
        (["herdr", "--session", "default"], true),
        (["herdr", "--session=default"], true),
        (["herdr", "session", "attach", "default"], true),
        (["herdr", "--handoff"], true),
        (["herdr", "server"], false),
        (["herdr", "agent", "list"], false),
        (["herdr", "--remote", "workbox"], false),
        (["herdr", "--machine", "workbox", "agent", "list"], false),
        (["herdr", "--session", "work"], false),
        (["herdr", "session", "attach", "work"], false),
        (["herdr", "api", "snapshot"], false),
    ])
    func classifiesClients(argv: [String], isClient: Bool) {
        #expect(ClientLocator.isLocalClient(argv: argv) == isClient)
    }

    @Test func parsesKernelArguments() throws {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        buffer += Array("/opt/homebrew/bin/herdr".utf8) + [0, 0, 0]
        buffer += Array("herdr\u{0}--handoff\u{0}TERM_PROGRAM=kitty\u{0}KITTY_WINDOW_ID=3\u{0}A=b=c\u{0}\u{0}ptr_munge=".utf8)
        let parsed = try #require(ClientLocator.parseProcArgs(buffer))
        #expect(parsed.argv == ["herdr", "--handoff"])
        #expect(parsed.environment == ["TERM_PROGRAM": "kitty", "KITTY_WINDOW_ID": "3", "A": "b=c"])
    }

    /// Starts two processes named `herdr`: a tiny compiled program that waits until it is killed, so
    /// their argv is exactly `herdr` (a client) or `herdr server` (not a client). A copy of a system binary
    /// would not do: macOS refuses to launch Apple's platform binaries from another folder.
    @MainActor @Test func findsARealClientAndIgnoresTheServer() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appending(path: "herdr")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-x", "c", "-", "-o", fake.path]
        let source = Pipe()
        compiler.standardInput = source
        try compiler.run()
        source.fileHandleForWriting.write(Data("#include <unistd.h>\nint main(void) { for (;;) pause(); }\n".utf8))
        try source.fileHandleForWriting.close()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0, "cc failed")

        func start(_ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = fake
            process.arguments = arguments
            process.environment = ["HERDRBAR_TEST_MARK": "1"]
            try process.run()
            return process
        }
        let client = try start([])
        let server = try start(["server"])
        defer { client.terminate(); server.terminate() }

        var found: [HerdrClient] = []
        for _ in 0..<60 where !found.contains(where: { $0.pid == client.processIdentifier }) {
            Thread.sleep(forTimeInterval: 0.05)
            found = ClientLocator.localClients()
        }
        if !found.contains(where: { $0.pid == client.processIdentifier }) {
            let entry = ClientLocator.processTable()[client.processIdentifier]
            Issue.record("fake client \(client.processIdentifier): \(String(describing: entry)) argv \(String(describing: ClientLocator.arguments(of: client.processIdentifier)?.argv))")
        }
        let pids = Set(found.map(\.pid))
        #expect(pids.contains(client.processIdentifier))
        #expect(!pids.contains(server.processIdentifier))
        let mine = try #require(found.first { $0.pid == client.processIdentifier })
        #expect(mine.environment["HERDRBAR_TEST_MARK"] == "1")
    }
}
