import XCTest
@testable import NanoTeams

/// Pins `ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(_:)`
/// (the C1 builder-layer filter that replaces the prior dispatcher
/// `if/else`) and the matching integration through `buildTimelineItems`.
///
/// The dispatcher in `TeamActivityFeedView.messageBubble` MUST stay
/// branch-free at the bubble level — a `_ConditionalContent` switch
/// between `EmptyView` and `MessageBubbleView` would re-mount the
/// underlying `NSTextView` on the streaming → committed flip and
/// defeat `SelectableMessageText`'s append-only optimization. The
/// suppression therefore lives at the builder, BEFORE the dispatcher.
@MainActor
final class ActivityFeedBuilderSupervisorMessageFilterTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    // MARK: - Predicate truth table (S2)

    /// A `.supervisorMessage` whose raw `content` is just the attribution
    /// prefix `"Supervisor:\n"` resolves to empty after `displayContent`
    /// strips the prefix and `stripAttachedFiles` finds no markers.
    /// This is the C4 atomicity-race case that the predicate must catch.
    func testShouldSuppress_supervisorMessage_attributionOnly_isTrue() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "Supervisor:\n",
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        XCTAssertTrue(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    /// `.supervisorMessage` with whitespace-only body after the prefix
    /// also counts as empty.
    func testShouldSuppress_supervisorMessage_whitespaceOnlyBody_isTrue() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "Supervisor:\n   \n\n",
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        XCTAssertTrue(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    /// `.supervisorMessage` with real text body — must NOT suppress.
    func testShouldSuppress_supervisorMessage_withBody_isFalse() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "Supervisor:\nLook at this please",
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    /// `.supervisorMessage` carrying only a skill (no typed text) — the skill
    /// re-extracts into `clippedTexts`, so the message is NOT empty.
    func testShouldSuppress_supervisorMessage_skillOnly_isFalse() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "Supervisor:\n## Skill: review\nskill body",
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    /// `.supervisorMessage` with no body but attached files — the
    /// attachment cards are real content, must NOT suppress.
    func testShouldSuppress_supervisorMessage_attachmentsOnly_isFalse() async {
        let raw = """
        Supervisor:
        
        ## Attached Files
        - /path/to/file.swift
        """
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: raw,
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    /// `.supervisorMessage` with no body but a clipped text — clip
    /// cards are real content, must NOT suppress.
    func testShouldSuppress_supervisorMessage_clipsOnly_isFalse() async {
        let raw = """
        Supervisor:
        
        ## Clipped Text
        let x = 1
        """
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: raw,
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    /// `.supervisorMessage` with thinking but otherwise empty — the
    /// thinking section is rendered, must NOT suppress.
    func testShouldSuppress_supervisorMessage_thinkingOnly_isFalse() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "Supervisor:\n",
            thinking: "internal monologue",
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    /// Other source contexts must NOT suppress even when empty —
    /// rendering an avatar-only ghost bubble surfaces the upstream bug
    /// (consultation / changeRequest producers always write non-empty
    /// payloads, so empty content there means a regression).
    func testShouldSuppress_consultationContext_isFalse() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "",
            sourceRole: .softwareEngineer, sourceContext: .consultation
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    func testShouldSuppress_changeRequestContext_isFalse() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "",
            sourceRole: .codeReviewer, sourceContext: .changeRequest
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    /// `.supervisorFeedback` shares the bubble STYLING with `.supervisorMessage` but not this
    /// suppression, and the narrowing is deliberate rather than an omission: the C4 race this
    /// filter exists for is a property of the QUEUED-CHAT delivery, which revision feedback
    /// does not use. Its trigger sites reject a whitespace-only comment and
    /// `resetStepForRevision` substitutes a canned sentence rather than nothing — so an empty
    /// one is a real upstream defect and must stay visible as a ghost bubble.
    ///
    /// RED: widen the guard to `rendersAsSupervisorUtterance` → this fails, and a genuine
    /// empty-feedback regression starts disappearing from the feed instead of showing.
    func testShouldSuppress_supervisorFeedbackContext_isFalse() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "",
            sourceRole: .supervisor, sourceContext: .supervisorFeedback
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
        XCTAssertTrue(
            MessageSourceContext.supervisorFeedback.rendersAsSupervisorUtterance,
            "anti-vacuity: it really does share the Supervisor styling — that is what makes "
                + "this narrowing a decision rather than a case nobody thought about"
        )
    }

    func testShouldSuppress_meetingContext_isFalse() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "",
            sourceRole: .productManager, sourceContext: .meeting
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    func testShouldSuppress_nilSourceContext_isFalse() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .assistant,
            content: "",
            sourceContext: nil
        )
        XCTAssertFalse(ActivityFeedBuilder.shouldSuppressEmptySupervisorMessage(msg))
    }

    // MARK: - Builder integration (C1 end-to-end)

    /// An empty `.supervisorMessage` step item must NOT produce an
    /// `.llmMessage` timeline entry. This is the load-bearing C1 fix
    /// — without it the dispatcher would receive the item and have to
    /// branch internally, breaking the SwiftUI structural-identity
    /// invariant `SelectableMessageText` depends on.
    func testBuilder_dropsEmptySupervisorMessageItem() async {
        let emptyMsg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "Supervisor:\n",
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        let step = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done,
            updatedAt: MonotonicClock.shared.now(),
            llmConversation: [emptyMsg]
        )
        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        let llmItems = items.filter {
            if case .llmMessage = $0.item { return true }
            return false
        }
        XCTAssertTrue(llmItems.isEmpty,
                      "Empty .supervisorMessage must be filtered at the builder, not surfaced as a ghost bubble in the dispatcher.")
    }

    /// Streaming `.supervisorMessage` items are exempt from suppression
    /// — the bubble must be alive even before first delta lands so the
    /// `MessageBubbleStreamingIndicator` can render Waiting/Generating.
    func testBuilder_keepsStreamingSupervisorMessage_evenIfRawIsEmpty() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "Supervisor:\n",
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        let step = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .running,
            updatedAt: MonotonicClock.shared.now(),
            llmConversation: [msg]
        )
        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { id in id == msg.id }
        )
        let llmItems = items.filter {
            if case .llmMessage = $0.item { return true }
            return false
        }
        XCTAssertEqual(llmItems.count, 1,
                       "Streaming bubble must remain visible — indicator drives UX even pre-first-delta.")
    }

    /// Non-empty supervisor messages must round-trip through the builder.
    func testBuilder_keepsSupervisorMessageWithBody() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "Supervisor:\nReal body text",
            sourceRole: .supervisor, sourceContext: .supervisorMessage
        )
        let step = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done,
            updatedAt: MonotonicClock.shared.now(),
            llmConversation: [msg]
        )
        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        let llmItems = items.filter {
            if case .llmMessage = $0.item { return true }
            return false
        }
        XCTAssertEqual(llmItems.count, 1)
    }

    /// Empty consultation messages are NOT suppressed — they surface as
    /// a regression signal (consultation producers should never write
    /// empty bodies).
    func testBuilder_keepsEmptyConsultationMessage_asRegressionSignal() async {
        let msg = LLMMessage(
            createdAt: date(0), role: .user,
            content: "",
            sourceRole: .softwareEngineer, sourceContext: .consultation
        )
        let step = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done,
            updatedAt: MonotonicClock.shared.now(),
            llmConversation: [msg]
        )
        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        // The pre-existing empty-content filter in `populateStepItems`
        // (line 179) drops messages with empty content + no thinking +
        // not streaming. So this empty consultation will also be filtered
        // — but for a different reason than supervisor suppression. Pin
        // the expectation to that pre-existing rule by including thinking
        // so the message survives the line-179 filter.
        let msgWithThinking = LLMMessage(
            createdAt: date(0), role: .user,
            content: "",
            thinking: "rationale",
            sourceRole: .softwareEngineer, sourceContext: .consultation
        )
        let stepWithThinking = StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done,
            updatedAt: MonotonicClock.shared.now(),
            llmConversation: [msgWithThinking]
        )
        let itemsWithThinking = ActivityFeedBuilder.buildTimelineItems(
            steps: [stepWithThinking],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        let llmItems = items.filter {
            if case .llmMessage = $0.item { return true }
            return false
        }
        let llmItemsWithThinking = itemsWithThinking.filter {
            if case .llmMessage = $0.item { return true }
            return false
        }
        XCTAssertTrue(llmItems.isEmpty,
                      "Pre-existing empty-content filter (not the supervisor suppression) drops a content+thinking-empty consultation.")
        XCTAssertEqual(llmItemsWithThinking.count, 1,
                       "Same consultation with thinking survives BOTH filters — supervisor suppression must not catch it.")
    }
}
