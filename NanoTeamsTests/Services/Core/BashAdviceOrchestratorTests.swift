import XCTest

@testable import NanoTeams

/// The orchestrator's "Ask AI" seam: `hasPendingBashApproval` mirrors gate state,
/// and `requestBashJudgeAdvice` returns per-command advice WITHOUT consuming the
/// pending approval or recording a decision (the human still answers).
@MainActor
final class BashAdviceOrchestratorTests: NTMSOrchestratorTestBase {

    @discardableResult
    private func seedPending(taskID: Int, stepID: String, commands: [String]) -> Date {
        let token = MonotonicClock.shared.now()
        sut.llmExecutionService.pendingBashApprovals[TaskStepKey(taskID: taskID, stepID: stepID)] =
            PendingBashApproval(
                commandKeys: commands.map { "key:\($0)" },
                commands: commands,
                workingDirectories: commands.map { _ in nil },
                question: "approve?",
                judgeConfig: LLMConfig(),
                createdAt: token)
        return token
    }

    func testPendingBashApproval_reflectsGateStateAndIsScoped() {
        XCTAssertNil(sut.llmExecutionService.pendingBashApproval(stepID: "role", taskID: 1))
        let token = seedPending(taskID: 1, stepID: "role", commands: ["ls"])
        XCTAssertEqual(sut.llmExecutionService.pendingBashApproval(stepID: "role", taskID: 1)?.createdAt, token)
        // Scoped by (taskID, stepID): a different step/task does not match.
        XCTAssertNil(sut.llmExecutionService.pendingBashApproval(stepID: "role", taskID: 2))
        XCTAssertNil(sut.llmExecutionService.pendingBashApproval(stepID: "other", taskID: 1))
    }

    func testRequestAdvice_perCommand_doesNotMutateGateState() async {
        let key = TaskStepKey(taskID: 1, stepID: "role")
        seedPending(taskID: 1, stepID: "role", commands: ["ls", "rm -rf x"])

        let advices = await sut.requestBashJudgeAdvice(
            taskID: 1, stepID: "role",
            client: FixedVerdictClient(verdict: #"{"decision":"OK"}"#))

        XCTAssertEqual(advices.map(\.command), ["ls", "rm -rf x"])
        XCTAssertTrue(advices.allSatisfy(\.allowed))
        // Advisory is read-only: the pending approval survives untouched.
        XCTAssertNotNil(sut.llmExecutionService.pendingBashApprovals[key])
    }

    func testRequestAdvice_noPending_returnsEmpty_withoutCallingJudge() async {
        let client = FixedVerdictClient(verdict: #"{"decision":"OK"}"#)
        let advices = await sut.requestBashJudgeAdvice(taskID: 5, stepID: "missing", client: client)
        XCTAssertTrue(advices.isEmpty)
        XCTAssertEqual(client.callCount, 0)
    }

    // MARK: - resolveBashApproval (the Allow / Deny / Always-allow buttons)

    @discardableResult
    private func beginRequest(command: String, offerAlways: Bool, taskID: Int = 1, stepID: String = "role") -> Date {
        let createdAt = MonotonicClock.shared.now()
        sut.bashApprovalDidBegin(
            BashApprovalRequest(
                taskID: taskID, stepID: stepID, commandKey: "key:\(command)", command: command,
                workingDirectory: nil, offerAlways: offerAlways, createdAt: createdAt))
        return createdAt
    }

    func testBashApprovalDidBeginAndEnd_publishAndClearTheRequest() {
        let key = TaskStepKey(taskID: 1, stepID: "role")
        XCTAssertNil(sut.bashApprovalRequests[key])
        let createdAt = beginRequest(command: "ls", offerAlways: true)
        XCTAssertEqual(sut.bashApprovalRequests[key]?.command, "ls")
        sut.bashApprovalDidEnd(taskID: 1, stepID: "role", commandKey: "key:ls", createdAt: createdAt)
        XCTAssertNil(sut.bashApprovalRequests[key], "the request is cleared when the gate stops holding it")
    }

    func testBashApprovalDidEnd_staleCreatedAt_doesNotClearFreshCard() {
        // A second hold of the SAME command (same commandKey, new createdAt) replaces
        // the card. A late `didEnd` from the FIRST hold must NOT clear the fresh card
        // — otherwise the step is wedged with no Allow/Deny button. Only a matching
        // `createdAt` clears it.
        let key = TaskStepKey(taskID: 1, stepID: "role")
        let firstCreatedAt = beginRequest(command: "ls", offerAlways: true)
        let secondCreatedAt = beginRequest(command: "ls", offerAlways: true)   // overwrites the card
        XCTAssertEqual(sut.bashApprovalRequests[key]?.createdAt, secondCreatedAt)

        sut.bashApprovalDidEnd(taskID: 1, stepID: "role", commandKey: "key:ls", createdAt: firstCreatedAt)
        XCTAssertEqual(sut.bashApprovalRequests[key]?.createdAt, secondCreatedAt,
            "a stale didEnd from a prior hold must not clear the freshly-republished card")

        sut.bashApprovalDidEnd(taskID: 1, stepID: "role", commandKey: "key:ls", createdAt: secondCreatedAt)
        XCTAssertNil(sut.bashApprovalRequests[key], "the matching didEnd clears the card")
    }

    func testClearAllBashApprovalRequests_dropsEveryCard() {
        beginRequest(command: "ls", offerAlways: true, taskID: 1, stepID: "role")
        beginRequest(command: "make", offerAlways: true, taskID: 2, stepID: "other")
        XCTAssertEqual(sut.bashApprovalRequests.count, 2)
        sut.clearAllBashApprovalRequests()
        XCTAssertTrue(sut.bashApprovalRequests.isEmpty, "full teardown drops every published card")
    }

    func testResolveAlwaysAllow_semiAutomatic_persistsAllowRule() {
        sut.configuration.bashMode = .semiAutomatic
        beginRequest(command: "rm foo", offerAlways: true)
        sut.resolveBashApproval(taskID: 1, stepID: "role", commandKey: "key:rm foo", choice: .alwaysAllow)
        XCTAssertTrue(sut.configuration.bashAllowRules.contains("rm foo"))
    }

    func testResolveAlwaysAllow_alwaysConfirmManual_doesNotPersist() {
        // Always-confirm Manual never persists a standing allow — even an
        // (offerAlways=false) command resolved as alwaysAllow stays one-shot.
        sut.configuration.bashMode = .manual
        beginRequest(command: "rm foo", offerAlways: false)
        sut.resolveBashApproval(taskID: 1, stepID: "role", commandKey: "key:rm foo", choice: .alwaysAllow)
        XCTAssertFalse(sut.configuration.bashAllowRules.contains("rm foo"))
    }

    func testResolveAllow_doesNotPersistAnyRule() {
        sut.configuration.bashMode = .semiAutomatic
        beginRequest(command: "rm foo", offerAlways: true)
        sut.resolveBashApproval(taskID: 1, stepID: "role", commandKey: "key:rm foo", choice: .allow)
        XCTAssertTrue(sut.configuration.bashAllowRules.isEmpty)
    }

    func testResolveAlwaysAllow_staleCommandKey_doesNotPersist() {
        // The persist must key off the SAME command the button resolved: a stale-card
        // tap whose commandKey no longer matches the currently-held request must not
        // persist a mismatched command into the allow rules.
        sut.configuration.bashMode = .semiAutomatic
        beginRequest(command: "rm foo", offerAlways: true)   // request.commandKey == "key:rm foo"
        sut.resolveBashApproval(taskID: 1, stepID: "role", commandKey: "key:stale", choice: .alwaysAllow)
        XCTAssertFalse(sut.configuration.bashAllowRules.contains("rm foo"),
            "a commandKey that doesn't match the held request must not persist its command")
    }
}

/// Returns the same verdict for every command; counts calls.
private final class FixedVerdictClient: LLMClient, @unchecked Sendable {
    let verdict: String
    private(set) var callCount = 0
    init(verdict: String) { self.verdict = verdict }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        let text = verdict
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: text))
            continuation.finish()
        }
    }
    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
