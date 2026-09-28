import Foundation
import Testing
@testable import Herdrbar

@Suite struct CLITests {
    @Test func returnsWhatTheProgramPrints() async throws {
        #expect(try await CLI.run(["/bin/sh", "-c", "echo hello"], timeout: .seconds(5)) == Data("hello\n".utf8))
    }

    @Test func reportsTheExitStatusAndStderr() async {
        await #expect(throws: CLI.Failure(status: 3, message: "unknown option: --machine")) {
            try await CLI.run(["/bin/sh", "-c", "echo 'unknown option: --machine' >&2; exit 3"], timeout: .seconds(5))
        }
    }

    @Test func stopsAProgramThatRunsTooLong() async {
        let started = ContinuousClock.now
        do {
            _ = try await CLI.run(["/bin/sh", "-c", "sleep 10"], timeout: .milliseconds(200))
            Issue.record("expected a timeout")
        } catch let failure as CLI.Failure {
            #expect(failure.timedOut)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func refusesOutputOverTheCap() async {
        do {
            _ = try await CLI.run(["/bin/sh", "-c", "yes | head -c 200000"], timeout: .seconds(5), limit: 1000)
            Issue.record("expected an overflow")
        } catch let failure as CLI.Failure {
            #expect(failure.tooLarge)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
