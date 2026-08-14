import XCTest
@testable import NanoTeams

/// `GeneratedTeamPanelState.failed` — the predicate behind "Generating team…" vs the error
/// pane + Retry button.
///
/// Every wedge this type exists to prevent looks identical to the user: a spinner that
/// never resolves, no error text, no Retry, and no exit but deleting the task.
final class GeneratedTeamPanelStateTests: XCTestCase {

    private func failed(
        pending: Bool = true,
        toolCallIsError: Bool = false,
        stepStatus: StepStatus? = nil,
        hasRun: Bool = true,
        inFlight: Bool = false
    ) -> Bool {
        GeneratedTeamPanelState.failed(
            isPending: pending,
            toolCallIsError: toolCallIsError,
            stepStatus: stepStatus,
            hasRun: hasRun,
            isGenerationInFlight: inFlight)
    }

    // MARK: - Not pending ⇒ never a failure

    func testNotPending_isNeverFailure() {
        XCTAssertFalse(failed(pending: false, toolCallIsError: true, stepStatus: .failed))
    }

    // MARK: - The ordinary failures

    func testErroredPlaceholder_isFailure() {
        XCTAssertTrue(failed(toolCallIsError: true, stepStatus: .running, inFlight: true))
    }

    func testFailedStep_isFailure() {
        XCTAssertTrue(failed(stepStatus: .failed))
    }

    // MARK: - Liveness is the fallback for EVERY remaining shape

    /// The regression. Generation is in flight when the app quits; on relaunch the
    /// in-memory in-flight set is empty and `StatusRecoveryService` has parked the
    /// synthetic step `.running` → `.paused`. An earlier cut returned
    /// `stepStatus == .failed` outright whenever a step survived, so this state read as
    /// "still generating" forever.
    func testPausedStepWithNothingInFlight_isFailure() {
        XCTAssertTrue(failed(stepStatus: .paused, inFlight: false))
    }

    /// Same shape via `pauseRun` cancelling a generation whose step was already injected,
    /// and via any crash that leaves the status un-parked.
    func testRunningStepWithNothingInFlight_isFailure() {
        XCTAssertTrue(failed(stepStatus: .running, inFlight: false))
    }

    func testMissingStepWithNothingInFlight_isFailure() {
        XCTAssertTrue(failed(stepStatus: nil, inFlight: false))
    }

    // MARK: - Windows that must NOT read as failure

    func testRunningStepInFlight_isNotFailure() {
        XCTAssertFalse(failed(stepStatus: .running, inFlight: true))
    }

    /// Between `startRun` and the step's injection there is legitimately no record.
    func testNoStepYetButInFlight_isNotFailure() {
        XCTAssertFalse(failed(stepStatus: nil, inFlight: true))
    }

    /// A task whose run hasn't started has nothing to have failed — and this term must
    /// stay ABOVE the liveness fallback, or every freshly created generated-team task
    /// would open on an error pane.
    func testNoRunYet_isNotFailure() {
        XCTAssertFalse(failed(stepStatus: nil, hasRun: false, inFlight: false))
    }

    // MARK: - Precedence

    /// An errored placeholder outranks liveness: the failure is already recorded, so a
    /// stale in-flight marker must not hide it.
    func testErroredPlaceholderOutranksInFlight() {
        XCTAssertTrue(failed(toolCallIsError: true, stepStatus: nil, inFlight: true))
    }

    func testDoneStepStillPending_fallsThroughToLiveness() {
        // `.done` with no team adopted and nothing in flight is a torn record, not success.
        XCTAssertTrue(failed(stepStatus: .done, inFlight: false))
        XCTAssertFalse(failed(stepStatus: .done, inFlight: true))
    }

    // MARK: - Copy

    func testFailureMessage_prefersTheRecordedEnvelopeMessage() {
        XCTAssertEqual(
            GeneratedTeamPanelState.failureMessage(
                recorded: "AI returned invalid team configuration", stepStatus: .failed),
            "AI returned invalid team configuration")
    }

    /// The destroyed-record shape. `generationToolCall` resolves through
    /// `step.toolCalls`, and `StepExecution.reset()` empties that array — so the pane
    /// rendered a bare heading with no diagnosis and nothing to distinguish it from a
    /// generation that was never attempted.
    func testFailureMessage_whenTheRecordWasDestroyed_saysSo() {
        let message = GeneratedTeamPanelState.failureMessage(recorded: nil, stepStatus: .pending)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("cleared"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("retry"), message)
    }

    func testFailureMessage_whenGenerationWasInterrupted_saysSo() {
        for status in [StepStatus.paused, .running] {
            let message = GeneratedTeamPanelState.failureMessage(recorded: nil, stepStatus: status)
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("interrupted"), "\(status): \(message)")
        }
    }

    /// A whitespace-only envelope message is as useless as none — the fallback must
    /// still fire, or the pane shows a heading over a blank line.
    func testFailureMessage_blankRecordedMessage_fallsThrough() {
        let message = GeneratedTeamPanelState.failureMessage(recorded: "   \n ", stepStatus: .pending)
        XCTAssertFalse(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotEqual(message, "   \n ")
    }

    func testFailureMessage_isNeverEmpty_forEveryStepStatus() {
        var statuses: [StepStatus?] = StepStatus.allCases.map { $0 }
        statuses.append(nil)
        for status in statuses {
            let message = GeneratedTeamPanelState.failureMessage(recorded: nil, stepStatus: status)
            XCTAssertFalse(
                message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "empty message for \(String(describing: status))")
        }
    }

    /// A CANCELLED generation sets `toolCall.isError = true` too, so the pane read
    /// "Team generation failed" over "Team generation was cancelled" — blaming the app
    /// for the user's own pause. Same shape `StatusRecoveryService` produces for a
    /// generation interrupted by an app quit, and for a destroyed record it settles.
    func testFailureTitle_saysPausedForAnInterruptedGeneration() {
        XCTAssertEqual(
            GeneratedTeamPanelState.failureTitle(stepStatus: .paused), "Team generation paused")
        for status: StepStatus? in [.failed, .pending, .done, nil] {
            XCTAssertEqual(
                GeneratedTeamPanelState.failureTitle(stepStatus: status),
                "Team generation failed",
                "\(String(describing: status))")
        }
    }
}
