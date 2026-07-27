import XCTest

@testable import NanoTeams

/// Every retry nudge `handleNoToolCalls` appends must carry `.retryNudge`.
///
/// The defect: all eight nudge sites wrote `role: .user` with `sourceRole == nil` and
/// `sourceContext == nil`, and `ActivityFeedBuilder` drops exactly that shape. So the app
/// was talking to the model on the user's behalf — "you replied with text but did not call
/// a tool", "your JSON was malformed", "you haven't submitted all artifacts" — and none of
/// it reached the screen. What the user saw in the wedged Autovisor pass was a column of
/// identical assistant bubbles with no cause; the cause was there, filtered out.
///
/// The nudges are NOT collapsed in place the way `.serverError` retry notices are, and
/// that is deliberate: a nudge is separated from the previous nudge by the model's own
/// committed reply, so a "replace if the last entry is a nudge" collapse would fire only
/// for envelope-only turns (whose assistant content commits empty) and not for prose ones.
/// A collapse that works in half the cases reads as a bug; N nudges for N retries is the
/// honest record, and F3 now bounds N.
@MainActor
final class RetryNudgeVisibilityTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        let step = StepExecution(id: "swe", role: .softwareEngineer, title: "Step", status: .running)
        stepID = step.id
        task = NTMSTask(id: 0, title: "T", supervisorTask: "do work", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() {
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        super.tearDown()
    }

    private func producingRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "swe", name: "SWE", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Engineering Notes"]),
            isSystemRole: true, systemRoleID: "softwareEngineer")
    }

    /// Every `.user` turn the step recorded, in order.
    private var recordedNudges: [LLMMessage] {
        (mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation ?? [])
            .filter { $0.role == .user }
    }

    // MARK: - Per-branch tagging

    func testGenericNoToolNudge_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "All done!", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages)
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testMissingArtifactsNudge_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Working on it.", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: producingRole(),
            conversationMessages: &messages)
        XCTAssertTrue((recordedNudges.last?.content ?? "").contains("Missing deliverables"),
                      "Sanity: this must be the artifact branch")
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testMalformedEnvelopeRetry_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: true,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: "<|channel|>commentary to=swift_build code<|message|>")
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testTokensOnlyRetry_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "<|return|>", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages)
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testDriftNudge_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: String(repeating: "x", count: 12_000))
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testRepetitiveNudge_isTagged() async {
        var shared: [ChatMessage] = []
        for _ in 1...3 {
            shared.append(ChatMessage(role: .assistant, content: "wait_for_events"))
            _ = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "wait_for_events", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: nil,
                conversationMessages: &shared)
        }
        XCTAssertTrue((recordedNudges.last?.content ?? "").contains("near-identical"),
                      "Sanity: this must be the repetition branch")
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    // MARK: - Replay contract

    /// A nudge really WAS sent, so the legacy display-record replay must keep it —
    /// unlike `.serverError`, which is display-only. Dropping it would make a replayed
    /// conversation show the model its own unproductive turns with the corrections
    /// removed, i.e. teach it that those turns were accepted.
    func testReplay_keepsRetryNudges() {
        let rebuilt = ConversationReplay.rebuildFromDisplayRecord([
            LLMMessage(role: .assistant, content: "Waiting."),
            LLMMessage(role: .user, content: "You replied with text but did not call a tool.",
                       sourceContext: .retryNudge),
            LLMMessage(role: .assistant, content: "Waiting."),
        ])
        XCTAssertEqual(rebuilt.count, 3)
        XCTAssertTrue(rebuilt.contains { ($0.content ?? "").contains("did not call a tool") },
                      "a retry nudge was sent, so a replay must resend it")
    }

    // MARK: - Structural pin

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    /// No `.user` turn may be recorded from the no-tool flow without attribution.
    ///
    /// A source pin because the property is "no site was forgotten" — and eight of them
    /// were. A ninth branch added later would compile, pass every behavioural test above,
    /// and be invisible on screen, which is precisely the failure mode this fixes.
    func testEveryUserTurnRecordedByFlowControl_carriesAContext() throws {
        let path = "NanoTeams/Services/LLM/LLMExecutionService+StepFlowControl.swift"
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)

        // The call spans lines, so join the whole file and scan each `appendLLMMessage(`
        // invocation up to its closing paren.
        let opener = "appendLLMMessage" + "("
        var searchStart = source.startIndex
        var checked = 0
        while let open = source.range(of: opener, range: searchStart..<source.endIndex) {
            guard let close = source.range(of: ")", range: open.upperBound..<source.endIndex) else { break }
            let call = String(source[open.upperBound..<close.lowerBound])
            searchStart = close.upperBound
            guard call.contains("role: .user") else { continue }
            checked += 1
            XCTAssertTrue(
                call.contains("sourceContext:"),
                "A `.user` turn recorded by \(path) with no sourceContext is dropped by "
                + "ActivityFeedBuilder's no-source filter — it must be attributed. Call: \(call)")
        }
        // Eight retry nudges plus the thinking-loop correction, which already carried
        // `.loopCorrection` and is the precedent this fix follows.
        XCTAssertEqual(checked, 9, "Expected the nine known `.user` record sites; adjust deliberately")
    }

    /// A broken `#filePath`→repoRoot derivation would scan nothing and pass vacuously.
    func testRepoRootResolves() {
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent("CLAUDE.md").path))
    }
}
