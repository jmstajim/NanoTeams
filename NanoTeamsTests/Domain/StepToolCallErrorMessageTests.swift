import XCTest
@testable import NanoTeams

/// `StepToolCall.errorMessage` — the ONE reader of a `{"ok":false,"error":{"message":…}}`
/// tool result, shared by the Autovisor's `task_status.last_error`, the generated-team
/// graph panel, and `retryTeamGenerationReportingResult`.
///
/// It shipped with three call sites and zero tests: mutating the body to `nil` left the
/// whole suite green, because none of the three consumers had a test that seeded an errored
/// tool call. That silently reverts the fix it exists for — the manager goes back to being
/// handed the tautology `"Role 'X' failed."` instead of the reason.
final class StepToolCallErrorMessageTests: XCTestCase {

    private func call(result: String?) -> StepToolCall {
        StepToolCall(name: ToolNames.createTeam, argumentsJSON: "{}", resultJSON: result,
                     isError: result != nil)
    }

    // MARK: - Reads the message

    func testErrorEnvelope_returnsTheMessage() {
        let json = #"{"ok":false,"error":{"code":"COMMAND_FAILED","message":"Key not found: name"}}"#
        XCTAssertEqual(call(result: json).errorMessage, "Key not found: name")
    }

    /// The shape the tool layer actually emits, `makeErrorEnvelope` with every field.
    func testFullEnvelopeWithMetaAndNext_stillFindsTheMessage() {
        let json = makeErrorEnvelope(
            code: .commandFailed, message: "AI returned invalid team configuration")
        XCTAssertEqual(
            call(result: json).errorMessage, "AI returned invalid team configuration")
    }

    // MARK: - Absent

    func testNoResult_isNil() {
        XCTAssertNil(call(result: nil).errorMessage)
    }

    func testSuccessEnvelope_isNil() {
        XCTAssertNil(call(result: #"{"ok":true,"data":{"status":"created"}}"#).errorMessage)
    }

    func testUnparseableResult_isNil() {
        XCTAssertNil(call(result: "not json at all").errorMessage)
    }

    func testErrorIsNotAnObject_isNil() {
        XCTAssertNil(call(result: #"{"ok":false,"error":"boom"}"#).errorMessage)
    }

    func testMessageMissing_isNil() {
        XCTAssertNil(call(result: #"{"ok":false,"error":{"code":"X"}}"#).errorMessage)
    }

    /// A message that renders as nothing is not a diagnosis — every caller has a better
    /// generic fallback, and the graph panel would otherwise show a blank error pane.
    func testWhitespaceOnlyMessage_isTreatedAsAbsent() {
        XCTAssertNil(call(result: #"{"ok":false,"error":{"message":"   \n "}}"#).errorMessage)
        XCTAssertNil(call(result: #"{"ok":false,"error":{"message":""}}"#).errorMessage)
    }

    // MARK: - The consumer that motivated it

    /// `AutovisorStatus.lastError` must prefer the envelope's reason over its own
    /// role-name tautology. This is the branch that had no coverage at all.
    func testAutovisorLastError_prefersTheEnvelopeReasonOverTheTautology() {
        let step = StepExecution(
            id: "eng", role: .softwareEngineer, title: "Eng", status: .failed,
            toolCalls: [call(result: #"{"ok":false,"error":{"message":"disk full"}}"#)])
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "do")
        task.runs = [Run(id: 0, steps: [step], roleStatuses: [:])]

        XCTAssertEqual(AutovisorStatus.lastError(for: task), "disk full")
    }

    func testAutovisorLastError_fallsBackToTheRoleNameWhenNoEnvelopeReason() {
        let step = StepExecution(
            id: "eng", role: .softwareEngineer, title: "Eng", status: .failed,
            toolCalls: [call(result: #"{"ok":false,"error":{"message":"  "}}"#)])
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "do")
        task.runs = [Run(id: 0, steps: [step], roleStatuses: [:])]

        let reported = AutovisorStatus.lastError(for: task)
        XCTAssertNotNil(reported)
        XCTAssertTrue(reported?.contains("eng") ?? false, reported ?? "nil")
    }

    /// The synthetic generation step's id is an opaque UUID that names no role, so the
    /// role-name tautology would hand the manager `Role 'team_generation_<uuid>' failed.`
    /// — a sentence it cannot act on. Reachable whenever the `create_team` record is gone
    /// (a `restartRole` reset) or carries no reason.
    func testAutovisorLastError_failedGenerationStep_saysWhatItIsAndWhatFixesIt() {
        let step = StepExecution(
            id: "\(StepExecution.teamGenerationIDPrefix)ABC", role: .supervisor,
            title: "Generate Team", status: .failed)
        var task = NTMSTask(id: 1, title: "Gen", supervisorTask: "build it")
        task.runs = [Run(id: 0, steps: [step], roleStatuses: [:])]

        let reported = AutovisorStatus.lastError(for: task) ?? ""
        XCTAssertTrue(reported.localizedCaseInsensitiveContains("team generation"), reported)
        XCTAssertTrue(reported.localizedCaseInsensitiveContains("retry"), reported)
        XCTAssertFalse(
            reported.contains(StepExecution.teamGenerationIDPrefix),
            "the opaque synthetic id must not leak into the manager's diagnosis")
    }

    /// The envelope still wins when there IS one — the generation arm is a fallback, not
    /// an override.
    func testAutovisorLastError_failedGenerationStepWithEnvelope_prefersTheEnvelope() {
        let step = StepExecution(
            id: "\(StepExecution.teamGenerationIDPrefix)ABC", role: .supervisor,
            title: "Generate Team", status: .failed,
            toolCalls: [call(result: #"{"ok":false,"error":{"message":"invalid team config"}}"#)])
        var task = NTMSTask(id: 1, title: "Gen", supervisorTask: "build it")
        task.runs = [Run(id: 0, steps: [step], roleStatuses: [:])]

        XCTAssertEqual(AutovisorStatus.lastError(for: task), "invalid team config")
    }
}
