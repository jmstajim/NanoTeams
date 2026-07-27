import XCTest

@testable import NanoTeams

/// Corner coverage for `ConversationReplay` — the seam a re-entering step uses to recover
/// the conversation it was in the middle of.
///
/// This is the fix for the reported Ollama bug: re-entry used to re-synthesize through
/// `PromptBuilder`, which reads `step.messages` and therefore sees neither the tool calls
/// nor the tool results a Harmony loop accumulates. Pure value-in/value-out, so every
/// branch is exercised directly — no delegate, task, or service.
final class ConversationReplayTests: XCTestCase {

    // MARK: - Fixtures

    private func step(
        transcript: [ChatMessage] = [],
        conversation: [LLMMessage] = []
    ) -> StepExecution {
        StepExecution(
            id: "s", role: .softwareEngineer, title: "Step",
            llmConversation: conversation,
            wireTranscript: transcript
        )
    }

    private func display(
        _ role: LLMRole,
        _ content: String,
        _ context: MessageSourceContext? = nil
    ) -> LLMMessage {
        LLMMessage(role: role, content: content, sourceContext: context)
    }

    // MARK: - resume: source selection

    /// The transcript is byte-faithful, the display record is not — whenever both exist
    /// the transcript must win, or the prefix cache misses for no reason.
    func testResume_prefersWireTranscript_overDisplayRecord() {
        let s = step(
            transcript: [ChatMessage(role: .system, content: "WIRE")],
            conversation: [display(.system, "DISPLAY")]
        )
        let resumed = ConversationReplay.resume(from: s)
        XCTAssertEqual(resumed?.source, .wireTranscript)
        XCTAssertEqual(resumed?.messages.count, 1)
        XCTAssertEqual(resumed?.messages.first?.content, "WIRE")
    }

    /// Steps persisted before `wireTranscript` existed still have to resume — degraded
    /// (one prefix miss) but semantically complete, and self-healing on the next suspend.
    func testResume_emptyTranscript_fallsBackToLegacyRebuild() {
        let s = step(conversation: [
            display(.system, "System"),
            display(.user, "Task"),
        ])
        let resumed = ConversationReplay.resume(from: s)
        XCTAssertEqual(resumed?.source, .legacyConversation)
        XCTAssertEqual(resumed?.messages.map(\.content), ["System", "Task"])
    }

    func testResume_bothEmpty_returnsNil() {
        XCTAssertNil(ConversationReplay.resume(from: step()))
    }

    /// Degenerate: the display record exists but every entry is display-only, so the
    /// rebuild is empty. That must read as "nothing to replay" (fresh build), NOT as a
    /// successful replay of an empty conversation — an empty `input` is a hard error on
    /// the wire.
    func testResume_conversationOfOnlyDisplayOnlyEntries_returnsNil() {
        let s = step(conversation: [
            display(.user, "Retry 1/3: timeout. Retrying in 5s…", .serverError),
            display(.user, "Child asked…", .delegatedQuestion),
            display(.assistant, "Escalating…", .delegationEscalation),
        ])
        XCTAssertNil(
            ConversationReplay.resume(from: s),
            "an all-dropped rebuild must fall through to a fresh build, not replay nothing")
    }

    /// A transcript holding a single message is still a real transcript. Guards against a
    /// future `count > 1` style emptiness check.
    func testResume_singleMessageTranscript_isAFaithfulReplay() {
        let s = step(transcript: [ChatMessage(role: .system, content: "only")])
        XCTAssertEqual(ConversationReplay.resume(from: s)?.source, .wireTranscript)
    }

    // MARK: - rebuildFromDisplayRecord: what is dropped

    /// Entries the runtime records for the activity feed but never put on the wire. Replaying
    /// them would both mislead the model and guarantee a prefix miss against what was sent.
    func testRebuild_dropsDisplayOnlyContexts() {
        let rebuilt = ConversationReplay.rebuildFromDisplayRecord([
            display(.system, "System"),
            display(.user, "Retry 1/3…", .serverError),
            display(.user, "Question from child", .delegatedQuestion),
            display(.assistant, "Escalated", .delegationEscalation),
            display(.user, "Task"),
        ])
        XCTAssertEqual(rebuilt.map(\.content), ["System", "Task"])
    }

    /// The mirror of the above, and the more dangerous direction: these contexts tag turns
    /// that WERE sent. Dropping one silently deletes the Supervisor's answer from the
    /// replay — the exact failure this whole seam exists to prevent.
    func testRebuild_keepsEverySentContext() {
        let sent: [MessageSourceContext] = [
            .supervisorAnswer, .supervisorMessage, .consultation, .meeting, .changeRequest,
            // The thinking-loop correction IS sent — it is the entire recovery, since a
            // stateless resend without it is byte-identical to the request that looped.
            // Dropping it here would silently restore the pre-fix behaviour on the
            // legacy replay path.
            .loopCorrection,
        ]
        for context in sent {
            let rebuilt = ConversationReplay.rebuildFromDisplayRecord([
                display(.user, "payload", context)
            ])
            XCTAssertEqual(
                rebuilt.map(\.content), ["payload"],
                "\(context) tags a turn that was sent — it must survive the replay")
        }
    }

    /// An assistant turn that carried only a Harmony tool-call envelope persists with empty
    /// content (the streaming path truncates at the marker). Replaying a run of blank
    /// assistant turns tells the model nothing; the following `.tool` composite names the call.
    func testRebuild_dropsEmptyAssistantTurns_keepsEmptyOtherRoles() {
        let rebuilt = ConversationReplay.rebuildFromDisplayRecord([
            display(.assistant, ""),
            display(.assistant, "real prose"),
            display(.user, ""),
        ])
        XCTAssertEqual(
            rebuilt.map { "\($0.role.rawValue):\($0.content ?? "")" },
            ["assistant:real prose", "user:"],
            "only the ASSISTANT empty-content case is dropped")
    }

    // MARK: - rebuildFromDisplayRecord: fidelity

    /// `providerID` is nil in essentially all production traffic, so there is no
    /// `tool_call_id` to pair a result to its call. The `[CALL] … [RESULT] …` composite is
    /// self-describing and must survive verbatim — trimming or reformatting it costs the
    /// model the only record of which call produced which result.
    func testRebuild_preservesToolCompositeVerbatim() {
        let composite = """
            [CALL] read_file
            Arguments: {"path":"Package.swift"}

            [RESULT]
            {"ok":true,"data":{"content":"// swift-tools-version: 5.9"}}
            """
        let rebuilt = ConversationReplay.rebuildFromDisplayRecord([display(.tool, composite)])
        XCTAssertEqual(rebuilt.first?.role, .tool)
        XCTAssertEqual(rebuilt.first?.content, composite)
    }

    func testRebuild_preservesOrder() {
        let rebuilt = ConversationReplay.rebuildFromDisplayRecord(
            (0..<6).map { display(.user, "m\($0)") })
        XCTAssertEqual(rebuilt.map(\.content), (0..<6).map { "m\($0)" })
    }

    func testRebuild_emptyInput_returnsEmpty() {
        XCTAssertTrue(ConversationReplay.rebuildFromDisplayRecord([]).isEmpty)
    }

    /// The rebuild maps roles by RAW VALUE across two independently-declared enums, so a
    /// case added to `LLMRole` without the matching `MessageRole` case would be silently
    /// dropped from every legacy replay. Pinned so that divergence fails here instead.
    func testRebuild_everyLLMRoleMapsToAMessageRole() {
        for role in [LLMRole.system, .user, .assistant, .tool] {
            XCTAssertNotNil(
                MessageRole(rawValue: role.rawValue),
                "LLMRole.\(role.rawValue) has no MessageRole counterpart — legacy replay "
                    + "would silently drop every turn with this role")
        }
    }
}
