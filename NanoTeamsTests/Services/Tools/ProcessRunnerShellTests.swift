import XCTest

@testable import NanoTeams

/// Real-process tests for `ProcessRunner.runShell` / `loginShell`. Runs commands
/// UNSANDBOXED (sandboxProfile: nil) so the tests don't depend on `sandbox-exec`.
final class ProcessRunnerShellTests: XCTestCase {

    func testLoginShell_fallsBackToZshWhenShellEmpty() {
        XCTAssertEqual(ProcessRunner.loginShell(environment: [:]), BashConstants.fallbackShell)
        XCTAssertEqual(ProcessRunner.loginShell(environment: ["SHELL": "   "]), BashConstants.fallbackShell)
    }

    func testLoginShell_usesShellEnvWhenExecutable() {
        // /bin/zsh exists and is executable on every supported macOS.
        XCTAssertEqual(ProcessRunner.loginShell(environment: ["SHELL": "/bin/zsh"]), "/bin/zsh")
    }

    func testLoginShell_ignoresNonExecutableShell() {
        XCTAssertEqual(
            ProcessRunner.loginShell(environment: ["SHELL": "/nonexistent/shell"]),
            BashConstants.fallbackShell)
    }

    func testRunShell_echoSucceeds() throws {
        let result = try ProcessRunner.runShell(
            "echo hello", in: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 30, sandboxProfile: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("hello"))
    }

    func testRunShell_nonZeroExitReturned() throws {
        let result = try ProcessRunner.runShell(
            "exit 3", in: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 30, sandboxProfile: nil)
        XCTAssertEqual(result.exitCode, 3)
    }

    func testRunShell_capturesStderr() throws {
        let result = try ProcessRunner.runShell(
            "echo oops 1>&2", in: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 30, sandboxProfile: nil)
        XCTAssertTrue(result.stderr.contains("oops"))
    }

    func testRunShell_timeoutCarriesPartialOutput() {
        // The command prints a marker, then sleeps past the deadline. The thrown
        // timeout must carry the output captured before the deadline.
        XCTAssertThrowsError(
            try ProcessRunner.runShell(
                "echo PRE_TIMEOUT; sleep 5", in: URL(fileURLWithPath: NSTemporaryDirectory()),
                timeout: 0.5, sandboxProfile: nil)
        ) { error in
            guard case ProcessRunnerError.timeout(_, let stdout, _) = error else {
                return XCTFail("expected timeout error, got \(error)")
            }
            XCTAssertTrue(stdout.contains("PRE_TIMEOUT"), "partial stdout must survive a timeout")
        }
    }
}
