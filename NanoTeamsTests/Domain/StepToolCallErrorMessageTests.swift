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

    /// `error` as a bare string with NO top-level `message` beside it carries no diagnosis.
    /// Renamed from `testErrorIsNotAnObject_isNil`, which described a rule the property no
    /// longer follows: a top-level `error` string IS read now, when a message accompanies it.
    func testErrorIsAStringWithNoTopLevelMessage_isNil() {
        XCTAssertNil(call(result: #"{"ok":false,"error":"boom"}"#).errorMessage)
    }

    /// A success envelope that happens to carry a top-level `message` is not a failure.
    /// The top-level branch is gated on `error` being a STRING, which is what keeps it out.
    ///
    /// RED: gate the branch on `dict["error"] != nil` (or drop the gate) → this returns
    /// "all good" and every consumer reports a success as the task's last error.
    func testSuccessEnvelopeWithATopLevelMessage_isNil() {
        XCTAssertNil(call(result: #"{"ok":true,"message":"all good"}"#).errorMessage)
    }

    // MARK: - The executor's shape

    /// The EXECUTOR writes the code as a top-level string beside a top-level message —
    /// every rejection it makes itself. Reading only the nested shape returned `nil` for all
    /// four, so the Autovisor was handed `Role 'X' failed.` for a step whose last error named
    /// a missing `.git` or an unselected Xcode scheme, both of which it can act on.
    ///
    /// Driven through the real emitter, so a change to the envelope shape breaks this rather
    /// than silently orphaning the branch.
    ///
    /// RED: drop the top-level branch from `errorMessage` → every row is nil.
    func testExecutorEmittedRejections_areReadable() throws {
        let toolCall = StepToolCall(name: "git_add", argumentsJSON: #"{"paths":["a"]}"#)
        for reason in LLMExecutionService.ToolUnavailabilityReason.allCases {
            let envelope = LLMExecutionService.makeUnavailableToolResult(
                call: toolCall, canonicalName: "git_add", scope: "for this role", reason: reason)
            let message = try XCTUnwrap(
                call(result: envelope.outputJSON).errorMessage,
                "\(reason) must be readable — the manager has no other channel for it")
            XCTAssertTrue(message.contains("git_add"), "\(reason): \(message)")
        }
    }

    func testIdenticalWriteLoopEnvelope_isReadable() throws {
        let envelope = LLMExecutionService.makeIdenticalWriteLoopResult(
            call: StepToolCall(name: "write_file", argumentsJSON: #"{"path":"a.swift","content":"x"}"#))
        let message = try XCTUnwrap(call(result: envelope.outputJSON).errorMessage)
        XCTAssertTrue(message.contains("a.swift"), message)
    }

    /// The consumer the widening was for. A step whose last errored call is an executor
    /// rejection now reports THAT instead of the role-name tautology.
    ///
    /// This is a deliberate behaviour change to an LLM-facing surface, not a side effect:
    /// `precondition_failed` names a blocker the manager can act on (`set_work_folder_context`,
    /// or telling the human), while `Role 'X' failed.` names nothing. If it ever proves
    /// harmful the filter belongs in `lastError`, never in `errorMessage` — a second reader
    /// of one question is the drift this property exists to prevent.
    func testAutovisorLastError_readsExecutorRejections_notJustHandlerEnvelopes() {
        let envelope = LLMExecutionService.makeUnavailableToolResult(
            call: StepToolCall(name: "git_add", argumentsJSON: "{}"),
            canonicalName: "git_add", scope: "for this role", reason: .gitRepoMissing)
        let step = StepExecution(
            id: "eng", role: .softwareEngineer, title: "Eng", status: .failed,
            toolCalls: [call(result: envelope.outputJSON)])
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "do")
        task.runs = [Run(id: 0, steps: [step], roleStatuses: [:])]

        let reported = AutovisorStatus.lastError(for: task) ?? ""
        XCTAssertTrue(reported.contains("git repository"), reported)
        XCTAssertFalse(reported.contains("Role 'eng' failed."), reported)
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
