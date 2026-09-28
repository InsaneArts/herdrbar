import Foundation

/// Runs a program with an argv array (never through a shell), a deadline, and a cap on its output.
enum CLI {
    struct Failure: Error, Equatable {
        var status: Int32
        /// What the program printed on stderr, or on stdout when stderr was empty.
        var message: String
        var timedOut = false
        var tooLarge = false
    }

    static func run(_ argv: [String], timeout: Duration, limit: Int = 16 << 20) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(argv, timeout: timeout, limit: limit) })
            }
        }
    }

    /// Written by the reader and deadline queues; read only after the group and the process finish.
    private final class Outcome: @unchecked Sendable {
        var output = Data(), errors = Data()
        var overflow = false, timedOut = false
    }

    private static func runBlocking(_ argv: [String], timeout: Duration, limit: Int) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let outcome = Outcome()
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            outcome.timedOut = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: deadline)

        // Read both pipes at once: a child blocked on a full stderr pipe would never finish stdout.
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            (outcome.output, outcome.overflow) = read(stdout.fileHandleForReading, limit: limit) { process.terminate() }
        }
        DispatchQueue.global().async(group: group) {
            (outcome.errors, _) = read(stderr.fileHandleForReading, limit: 64 * 1024) {}
        }
        group.wait()
        process.waitUntilExit()
        deadline.cancel()

        guard process.terminationReason == .exit, process.terminationStatus == 0, !outcome.overflow else {
            let text = outcome.errors.isEmpty ? outcome.output.prefix(64 * 1024) : outcome.errors
            throw Failure(status: process.terminationStatus,
                          message: String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                          timedOut: outcome.timedOut, tooLarge: outcome.overflow)
        }
        return outcome.output
    }

    /// Reads to the end, or until `limit` bytes; past the limit it calls `stop` and reports an overflow.
    private static func read(_ handle: FileHandle, limit: Int, stop: () -> Void) -> (Data, Bool) {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit {
                stop()
                while let rest = try? handle.read(upToCount: 64 * 1024), !rest.isEmpty {}  // drain so the child can exit
                return (data.prefix(limit), true)
            }
        }
        return (data, false)
    }
}
