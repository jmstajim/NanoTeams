import XCTest
@testable import NanoTeams

/// Pins `TeamActivityFeedView.resolveImplicitStreamTarget(...)`.
@MainActor
final class TeamActivityFeedImplicitStreamTargetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Fixture

    private func makeRunningStep(stepID: String = "step.1", messages: [LLMMessage]) -> StepExecution {
        var step = StepExecution.make(for: makeRoleDef(id: stepID))
        step.status = .running
        step.llmConversation = messages
        return step
    }

    private func makeRoleDef(id: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: "Coding Agent",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
    }

    private func makeMsg(content: String, createdAt: Date) -> LLMMessage {
        LLMMessage(
            id: UUID(),
            createdAt: createdAt,
            role: .assistant,
            content: content
        )
    }

    // MARK: - Happy path

    /// Latest message in a running step, not the preview target → true.
    func testReturnsTrue_whenLatestMessageInRunningStepAndNotPreviewTarget() {
        let msg = makeMsg(content: "Создам простой веб-калькулятор…", createdAt: MonotonicClock.shared.now())
        let step = makeRunningStep(messages: [msg])
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id,
            messageID: msg.id,
            isPreviewTarget: false,
            allSteps: [step]
        )
        XCTAssertTrue(result)
    }

    /// Multiple committed messages — only the latest by `createdAt` is the
    /// implicit target. Older messages in the same running step stay quiet.
    func testReturnsTrue_onlyForLatestMessage_whenSeveralExist() {
        let older  = makeMsg(content: "first", createdAt: MonotonicClock.shared.now())
        let newer  = makeMsg(content: "second", createdAt: MonotonicClock.shared.now())
        let step   = makeRunningStep(messages: [older, newer])
        let latest = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: newer.id, isPreviewTarget: false, allSteps: [step]
        )
        let stale  = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: older.id, isPreviewTarget: false, allSteps: [step]
        )
        XCTAssertTrue(latest, "Latest by createdAt picks up the implicit target")
        XCTAssertFalse(stale, "Older messages in the same step must not surface the pill")
    }

    // MARK: - Negative cases (each guards a single condition)

    /// When the streaming preview manager is actively targeting this bubble,
    /// the regular `isStreaming` path handles indicator priority — implicit-
    /// target must NOT also fire (would conflate with the actively-growing
    /// content case, where content visibility intentionally suppresses the
    /// pill).
    func testReturnsFalse_whenIsPreviewTarget() {
        let msg = makeMsg(content: "live tokens", createdAt: MonotonicClock.shared.now())
        let step = makeRunningStep(messages: [msg])
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id,
            messageID: msg.id,
            isPreviewTarget: true,
            allSteps: [step]
        )
        XCTAssertFalse(result, "Preview-target case is handled by the regular `isStreaming` branch — implicit target must short-circuit")
    }

    func testReturnsFalse_whenStepNotRunning() {
        let msg = makeMsg(content: "final answer", createdAt: MonotonicClock.shared.now())
        var step = makeRunningStep(messages: [msg])
        step.status = .done
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: msg.id, isPreviewTarget: false, allSteps: [step]
        )
        XCTAssertFalse(result, "Done steps have no LLM work in flight — pill stays hidden")
    }

    /// Stale `stepID` reference (step removed mid-rebuild, descendant detached,
    /// etc.) must NOT crash and must NOT surface a pill. Indicator falls back
    /// to nil — safer than a stale "Generating" that never clears.
    func testReturnsFalse_whenStepNotFound() {
        let msg = makeMsg(content: "orphan", createdAt: MonotonicClock.shared.now())
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: "missing.step", messageID: msg.id, isPreviewTarget: false, allSteps: []
        )
        XCTAssertFalse(result)
    }

    /// Even when the step is running and not preview-targeted, a stale
    /// message id (one that's not the latest) must not pick up the pill.
    /// Defends against a future change to the dispatcher that might call
    /// the resolver for every bubble in the step regardless of position.
    func testReturnsFalse_whenMessageIDDoesNotMatchLatest() {
        let msg     = makeMsg(content: "real", createdAt: MonotonicClock.shared.now())
        let stranger = UUID()
        let step = makeRunningStep(messages: [msg])
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id,
            messageID: stranger,
            isPreviewTarget: false,
            allSteps: [step]
        )
        XCTAssertFalse(result)
    }

    /// `system` and `tool` turns are skipped by the dispatcher — `tool` turns
    /// in particular are persisted at the latest `createdAt` after a tool
    /// call lands. The resolver mirrors the dispatcher's filter so the user-
    /// facing "latest message" matches what's actually rendered.
    func testReturnsTrue_whenLatestVisibleMessage_evenIfToolTurnHasLaterTimestamp() {
        let visible = makeMsg(content: "i'll write the file", createdAt: MonotonicClock.shared.now())
        let toolTurn = LLMMessage(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            role: .tool,
            content: "{\"ok\":true}"
        )
        let step = makeRunningStep(messages: [visible, toolTurn])
        let result = TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: visible.id, isPreviewTarget: false, allSteps: [step]
        )
        XCTAssertTrue(result, "Tool-role turns are filtered from the visible set — the latest assistant bubble stays the implicit target")
    }

    /// Step with ONLY tool/system messages (no visible assistant turn). Defends
    /// against a refactor that switches `.max(by:)` → `.last` or relaxes the
    /// role filter — either would silently surface a pill on a hidden turn.
    func testReturnsFalse_whenStepHasNoVisibleMessages() {
        let toolTurn = LLMMessage(
            id: UUID(), createdAt: MonotonicClock.shared.now(),
            role: .tool, content: "{\"ok\":true}"
        )
        let step = makeRunningStep(messages: [toolTurn])
        XCTAssertFalse(TeamActivityFeedView.resolveImplicitStreamTarget(
            stepID: step.id, messageID: UUID(), isPreviewTarget: false, allSteps: [step]
        ))
    }
}
