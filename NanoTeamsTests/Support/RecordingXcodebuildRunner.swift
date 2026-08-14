import Foundation

@testable import NanoTeams

/// A scripted `xcodebuild`, and the recording of what it was asked to run.
///
/// Before the `XcodebuildRunning` seam, the only way to reach the orchestration in
/// `XcodeBuildRunner` and the two Xcode tool handlers was to spawn a real
/// `xcodebuild`. Three tests did, behind a `skipUnlessXcodebuildIsInstalled` gate —
/// so on a machine without the toolchain they contributed nothing, and on one with
/// it they contributed a real subprocess per test and an outcome that depended on
/// what the installed Xcode happened to print. Everything downstream of the
/// subprocess (the per-scheme loop, the stop-on-failure rule, the envelope) was
/// unreachable either way.
///
/// `responses` is consumed in order, so a multi-scheme sweep can be scripted
/// scheme-by-scheme; the last entry repeats once exhausted, which keeps a test that
/// only cares about "they all succeed" from having to count invocations. `calls`
/// records the arguments, which is how the *absence* of a subprocess gets asserted:
/// the settings-driven `resolveSchemes` paths claim to short-circuit before
/// auto-detection, and an empty `calls` is that claim as an assertion rather than a
/// section comment.
final class RecordingXcodebuildRunner: XcodebuildRunning, @unchecked Sendable {

    /// One scripted invocation result.
    struct Response {
        var exitCode: Int32
        var stdout: String
        var stderr: String

        static func ok(_ stdout: String = "") -> Response {
            Response(exitCode: 0, stdout: stdout, stderr: "")
        }
        static func failed(_ exitCode: Int32 = 65, stdout: String = "", stderr: String = "")
            -> Response {
            Response(exitCode: exitCode, stdout: stdout, stderr: stderr)
        }
    }

    /// One recorded invocation.
    struct Call: Equatable {
        var arguments: [String]
        var directory: URL
        var timeout: TimeInterval
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var thrown: Error?
    private var _calls: [Call] = []

    /// - Parameter responses: consumed in order; the final one repeats.
    /// - Parameter thrown: when set, every invocation throws instead. Models the
    ///   three conditions `ProcessRunner` actually throws for — missing executable,
    ///   cancellation, expired timeout — none of which a non-zero exit is.
    init(responses: [Response] = [.ok()], thrown: Error? = nil) {
        self.responses = responses
        self.thrown = thrown
    }

    var calls: [Call] { lock.withLock { _calls } }
    var callCount: Int { lock.withLock { _calls.count } }

    func run(
        _ arguments: [String], in directory: URL, timeout: TimeInterval
    ) throws -> ProcessRunner.Result {
        let response: Response = try lock.withLock {
            _calls.append(Call(arguments: arguments, directory: directory, timeout: timeout))
            if let thrown { throw thrown }
            let next = responses.first ?? .ok()
            if responses.count > 1 { responses.removeFirst() }
            return next
        }
        return ProcessRunner.Result(
            exitCode: response.exitCode, stdout: response.stdout, stderr: response.stderr)
    }
}

/// The runner for a path that must not spawn anything: every invocation fails the
/// test that reached it.
///
/// Distinct from `RecordingXcodebuildRunner(responses:)` with an unchecked `calls`.
/// A test asserting "this short-circuits before auto-detection" is only as good as
/// its remembering to assert the call count afterwards; this one cannot be forgotten,
/// because reaching it is itself the failure.
final class ForbiddenXcodebuildRunner: XcodebuildRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _reached = false

    /// `true` if a caller reached the subprocess. Read it to assert the negative
    /// explicitly where a test wants the reason spelled out in its own message.
    var reached: Bool { lock.withLock { _reached } }

    func run(
        _ arguments: [String], in directory: URL, timeout: TimeInterval
    ) throws -> ProcessRunner.Result {
        lock.withLock { _reached = true }
        // Not `XCTFail` — this type is constructed by nonisolated code on arbitrary
        // threads (`Task.detached` in `fetchAvailableSchemes`), where XCTest's
        // failure recording has no test case to attribute to. A thrown error is
        // observable at the call site and, for `detectSchemes`, is swallowed by
        // `try?` — which is exactly why the flag exists alongside it.
        throw ProcessRunnerError.executableNotFound(
            "a test reached xcodebuild through a path that must not spawn one")
    }
}
