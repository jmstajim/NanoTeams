import XCTest

@testable import NanoTeams

/// Persistence + lifecycle corners for `StepExecution.wireTranscript`, the byte-faithful
/// record of what was last SENT to the model. `ConversationReplay` replays it on re-entry,
/// so anything that corrupts it corrupts the model's memory of its own work.
///
/// Both invariants pinned here are silent when broken: a step still runs, it just resumes
/// from the wrong conversation.
final class StepExecutionWireTranscriptTests: XCTestCase {

    private func encoder() -> JSONEncoder { JSONCoderFactory.makePersistenceEncoder() }
    /// `makeDateDecoder` is the read side of `makePersistenceEncoder` — it is the decoder
    /// the repository uses for `task.json`, so these round-trips exercise the real pair.
    private func decoder() -> JSONDecoder { JSONCoderFactory.makeDateDecoder() }

    private func step(transcript: [ChatMessage]) -> StepExecution {
        StepExecution(
            id: "swe", role: .softwareEngineer, title: "Step", wireTranscript: transcript)
    }

    private func roundTrip(_ s: StepExecution) throws -> StepExecution {
        try decoder().decode(StepExecution.self, from: encoder().encode(s))
    }

    // MARK: - Codable

    func testRoundTrip_preservesTranscriptContentRoleAndOrder() throws {
        let original = step(transcript: [
            ChatMessage(role: .system, content: "System"),
            ChatMessage(role: .user, content: "Task"),
            ChatMessage(role: .assistant, content: "Working"),
            ChatMessage(role: .tool, content: "[CALL] read_file\n\n[RESULT]\n{\"ok\":true}"),
        ])
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded.wireTranscript.map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertEqual(
            decoded.wireTranscript.map { $0.content ?? "" },
            original.wireTranscript.map { $0.content ?? "" })
    }

    /// The encode side is guarded by `!isEmpty`, so an empty transcript writes NO key. That
    /// is what makes every `task.json` written before the field existed decode cleanly —
    /// the legacy shape and the empty shape are byte-identical on disk.
    func testEmptyTranscript_writesNoKey_andDecodesBackToEmpty() throws {
        let json = try encoder().encode(step(transcript: []))
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(
            text.contains("wireTranscript"),
            "an empty transcript must not bloat every persisted step with a dead key")
        XCTAssertTrue(try decoder().decode(StepExecution.self, from: json).wireTranscript.isEmpty)
    }

    /// The legacy path proper: a `task.json` from before the field existed. Decoding must
    /// yield `[]` (→ `ConversationReplay` falls back to the display-record rebuild), never
    /// throw — a throw here would make every pre-existing task unloadable.
    func testLegacyJSONWithoutTheKey_decodesToEmpty() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try encoder().encode(step(transcript: [
                    ChatMessage(role: .system, content: "System")
                ]))) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "wireTranscript"), "key must have been present")

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try decoder().decode(StepExecution.self, from: stripped)
        XCTAssertTrue(decoded.wireTranscript.isEmpty)
        XCTAssertEqual(decoded.id, "swe", "the rest of the step still decodes")
    }

    /// A `nil` content assistant turn is how an envelope-only Harmony turn can arrive.
    /// It must survive as nil rather than collapsing to "" — the replay distinguishes them.
    func testRoundTrip_preservesNilContentDistinctFromEmptyString() throws {
        let decoded = try roundTrip(step(transcript: [
            ChatMessage(role: .assistant, content: nil),
            ChatMessage(role: .assistant, content: ""),
        ]))
        XCTAssertNil(decoded.wireTranscript.first?.content)
        XCTAssertEqual(decoded.wireTranscript.last?.content, "")
    }

    // MARK: - reset()

    /// `restartRole` resets a step to run again from scratch. A surviving transcript would
    /// let a later re-entry replay the conversation of the DISCARDED attempt — the model
    /// would wake believing it had already done work that was thrown away.
    func testReset_clearsTheTranscriptAlongsideTheDisplayRecord() {
        var s = step(transcript: [ChatMessage(role: .system, content: "System")])
        s.llmConversation = [LLMMessage(role: .system, content: "System")]

        s.reset()

        XCTAssertTrue(s.wireTranscript.isEmpty, "a discarded attempt must leave nothing to replay")
        XCTAssertTrue(
            s.llmConversation.isEmpty,
            "the two records are cleared together — leaving either one behind resurrects the "
                + "discarded attempt through ConversationReplay's fallback")
    }

    func testReset_withSupervisorComment_stillClearsTheTranscript() {
        var s = step(transcript: [ChatMessage(role: .user, content: "old")])
        s.reset(supervisorComment: "Try again, differently.")
        XCTAssertTrue(s.wireTranscript.isEmpty)
        XCTAssertEqual(s.messages.count, 1, "the comment seeds the fresh run")
    }

    /// The contrast that gives `reset` its meaning: a REVISION keeps the transcript so the
    /// role continues its own conversation with feedback appended, where a reset discards
    /// it. If both cleared, every revision would lose the work it is revising.
    func testResetVersusRevision_haveOppositeTranscriptSemantics() {
        let transcript = [ChatMessage(role: .user, content: "prior work")]

        var restarted = step(transcript: transcript)
        restarted.reset()

        let revised = step(transcript: transcript)

        XCTAssertTrue(restarted.wireTranscript.isEmpty)
        XCTAssertFalse(
            revised.wireTranscript.isEmpty,
            "revision is a continuation — only reset() discards the transcript")
    }
}
