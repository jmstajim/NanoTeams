import XCTest

@testable import NanoTeams

/// State-machine coverage for `PromptImprovementSession` — the non-blocking
/// "improve prompt" lifecycle. Reducer-level tests drive `ingest` /
/// `finishStream` / `failStream` directly (deterministic, no concurrency);
/// two pump-integration tests exercise the real Task via a held continuation.
///
/// All test methods are `async` and construct their fixtures locally — the
/// sanctioned pattern for `@MainActor` XCTestCase on Xcode 26.x CI (sync test
/// methods constructing `@MainActor` types abort; see CLAUDE.md testing
/// conventions).
@MainActor
final class PromptImprovementSessionTests: XCTestCase {

    // MARK: - Harness

    /// Simulated host text field: `read`/`write` closures over a plain string,
    /// recording every session-driven write.
    @MainActor
    private final class Field {
        var text: String
        private(set) var writes: [String] = []
        init(_ initial: String) { text = initial }
        func read() -> String { text }
        func write(_ new: String) {
            text = new
            writes.append(new)
        }
    }

    /// Holds the injected provider stream's continuation so the test controls
    /// delta timing; also counts provider invocations and captures the prompt.
    private final class StreamBox: @unchecked Sendable {
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        var invocationCount = 0
        var capturedPrompt: String?
    }

    private func makeSession(box: StreamBox) -> PromptImprovementSession {
        PromptImprovementSession(streamProvider: { prompt, _ in
            box.invocationCount += 1
            box.capturedPrompt = prompt
            return AsyncThrowingStream { continuation in
                box.continuation = continuation
            }
        })
    }

    private func makeConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "m")
    }

    private func start(_ session: PromptImprovementSession, field: Field) {
        session.start(config: makeConfig(), read: { field.read() }, write: { field.write($0) })
    }

    /// Bounded yield-loop for pump-driven assertions — deterministic enough
    /// on the main actor without wall-clock sleeps.
    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<4000 where !condition() {
            await Task.yield()
        }
    }

    // MARK: - Start

    func testStart_blankText_isNoOp() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let empty = Field("")
        let whitespace = Field("   \n\t ")

        start(session, field: empty)
        start(session, field: whitespace)

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(box.invocationCount, 0, "blank prompts must never hit the LLM")
        XCTAssertTrue(empty.writes.isEmpty)
        XCTAssertTrue(whitespace.writes.isEmpty)
    }

    func testStart_entersWaiting_withoutTouchingField() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original prompt")

        start(session, field: field)

        XCTAssertEqual(session.phase, .waitingForFirstDelta)
        XCTAssertTrue(session.isImproving)
        XCTAssertTrue(field.writes.isEmpty,
                      "the field keeps the ORIGINAL text while the model thinks")
        XCTAssertEqual(field.text, "original prompt")
        XCTAssertEqual(box.capturedPrompt, "original prompt")
    }

    func testStart_whileImproving_isNoOp() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")

        start(session, field: field)
        let genAfterFirst = session.generation
        start(session, field: field)

        XCTAssertEqual(box.invocationCount, 1)
        XCTAssertEqual(session.generation, genAfterFirst,
                       "a second start mid-run must not invalidate the live pump")
    }

    func testStart_clearsPriorErrorAndRevertOffer() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")

        // Arm a revert offer via a full successful run.
        start(session, field: field)
        session.ingest(delta: "Improved.", generation: session.generation)
        session.finishStream(generation: session.generation)
        XCTAssertTrue(session.canRevert)

        // Second run: revert offer and (hypothetical) error must clear immediately.
        start(session, field: field)
        XCTAssertFalse(session.canRevert)
        XCTAssertNil(session.errorMessage)
    }

    // MARK: - Streaming

    func testFirstDelta_transitionsToStreaming_andWritesDisplayText() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        session.ingest(delta: "Improved start", generation: session.generation)

        XCTAssertEqual(session.phase, .streaming)
        XCTAssertEqual(field.text, "Improved start")
        XCTAssertEqual(field.writes, ["Improved start"])
    }

    func testTokenOnlyFirstDelta_keepsOriginal_staysWaiting() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        session.ingest(delta: "<|channel|>", generation: session.generation)

        XCTAssertEqual(session.phase, .waitingForFirstDelta,
                       "a delta that strips to nothing must not blank the field")
        XCTAssertTrue(field.writes.isEmpty)
        XCTAssertEqual(field.text, "original")
    }

    func testOpeningFenceFirstDelta_keepsOriginal() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        session.ingest(delta: "```\n", generation: session.generation)

        XCTAssertEqual(session.phase, .waitingForFirstDelta)
        XCTAssertTrue(field.writes.isEmpty)
    }

    func testDeltaAccumulation_stripsModelTokensPerWrite() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        session.ingest(delta: "Clear ", generation: session.generation)
        session.ingest(delta: "prompt<|channel|>.", generation: session.generation)

        XCTAssertEqual(field.text, "Clear prompt.")
        XCTAssertEqual(field.writes, ["Clear ", "Clear prompt."])
    }

    /// The field sees exactly the single-shot display after every delta, including the two
    /// writes of `""` when a fence completes under an already-written field: delta 1 shows "`",
    /// delta 2 "``", delta 3 completes the fence and hides it — `lastWritten` is non-nil, so the
    /// empty text IS written — delta 4's "\n" writes "" again, delta 5 "Body".
    ///
    /// RED: read `display.text` BEFORE `display.append(delta)` in `ingest` → every write lags one
    /// delta: the first `""` is swallowed by the `lastWritten == nil` early return, writes become
    /// `["`", "``", "", ""]` and `field.text` is `""` instead of `"Body"`.
    /// RED: skip the write whenever `text.isEmpty`, regardless of `lastWritten` → writes become
    /// `["`", "``", "Body"]`.
    func testIngest_fieldWritesFollowSingleShotDisplay_forCharByCharFence() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        for delta in ["`", "`", "`", "\n", "Body"] {
            session.ingest(delta: delta, generation: session.generation)
        }

        XCTAssertEqual(field.writes, ["`", "``", "", "", "Body"])
        XCTAssertEqual(field.text, "Body")
        XCTAssertEqual(session.phase, .streaming)
    }

    // MARK: - Completion

    func testCompletion_writesPostProcessedFinal_andArmsRevert() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        session.ingest(delta: "```\n", generation: session.generation)
        session.ingest(delta: "Body.\n", generation: session.generation)
        session.ingest(delta: "```", generation: session.generation)
        XCTAssertEqual(field.text, "Body.\n```",
                       "mid-stream: opening fence hidden, closing fence still visible")

        session.finishStream(generation: session.generation)

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(field.text, "Body.", "final write applies the full pipeline")
        XCTAssertTrue(session.canRevert)
        XCTAssertEqual(session.revertText, "original")
        XCTAssertNil(session.task)
    }

    func testEmptyFinal_afterMidStreamWrites_failsAndRestores() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        // Displays as a bare space mid-stream, post-processes to empty.
        session.ingest(delta: "<|tok|> ", generation: session.generation)
        XCTAssertEqual(field.text, " ")

        session.finishStream(generation: session.generation)

        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(field.text, "original", "empty result must restore the original")
        XCTAssertFalse(session.canRevert)
    }

    func testThinkingOnlyStream_neverWrites_fails() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        session.finishStream(generation: session.generation)

        XCTAssertNotNil(session.errorMessage)
        XCTAssertTrue(field.writes.isEmpty, "no content ever arrived — zero field writes")
        XCTAssertEqual(field.text, "original")
    }

    // MARK: - Errors

    func testErrorBeforeFirstDelta_failsWithoutWrites() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        session.failStream(message: "Server error", generation: session.generation)

        XCTAssertEqual(session.errorMessage, "Server error")
        XCTAssertTrue(field.writes.isEmpty)
        XCTAssertFalse(session.isImproving)
    }

    func testErrorMidStream_restoresOriginal() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "partial rewrite", generation: session.generation)

        session.failStream(message: "Connection lost", generation: session.generation)

        XCTAssertEqual(session.errorMessage, "Connection lost")
        XCTAssertEqual(field.text, "original")
        XCTAssertFalse(session.canRevert)
    }

    func testRetryAfterFailure_startsFreshRun() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.failStream(message: "boom", generation: session.generation)

        start(session, field: field)

        XCTAssertEqual(session.phase, .waitingForFirstDelta)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(box.invocationCount, 2)
    }

    func testUserEditInFailedState_clearsError() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.failStream(message: "boom", generation: session.generation)

        field.text = "user moved on"
        session.noteFieldTextChanged()

        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(session.phase, .idle)
    }

    func testEchoOfRestore_keepsFailedState() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "partial", generation: session.generation)
        session.failStream(message: "boom", generation: session.generation)

        // The restore write triggers the host's .onChange — the echo must not
        // clear the error the user hasn't seen yet.
        session.noteFieldTextChanged()

        XCTAssertEqual(session.errorMessage, "boom")
    }

    // MARK: - Stop / disappear

    func testStop_whileWaiting_idleWithoutWrites() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        session.stop()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(field.writes.isEmpty)
        XCTAssertNil(session.task)
    }

    func testStop_whileStreaming_restoresOriginal_noRevertOffer() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "half-done rewrite", generation: session.generation)

        session.stop()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(field.text, "original")
        XCTAssertFalse(session.canRevert)
    }

    func testHandleDisappear_midStream_equalsStop() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "half", generation: session.generation)

        session.handleDisappear()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(field.text, "original")
    }

    func testHandleDisappear_whenIdle_isNoOp() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "Improved.", generation: session.generation)
        session.finishStream(generation: session.generation)

        session.handleDisappear()

        XCTAssertTrue(session.canRevert, "disappear after completion must not retire the revert offer")
        XCTAssertEqual(field.text, "Improved.")
    }

    // MARK: - Stale events (generation counter)

    func testStaleDelta_afterStop_isDropped() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        let staleGen = session.generation
        session.stop()

        session.ingest(delta: "late delta", generation: staleGen)

        XCTAssertEqual(field.text, "original")
        XCTAssertEqual(session.phase, .idle)
    }

    func testStaleFinish_afterStopAndRestart_isDropped() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        let staleGen = session.generation
        session.stop()
        start(session, field: field)

        session.finishStream(generation: staleGen)

        XCTAssertEqual(session.phase, .waitingForFirstDelta,
                       "a stale finish must not terminate the NEW run")
        XCTAssertFalse(session.canRevert)
    }

    // MARK: - CAS baseline (external ownership)

    func testExternalEditMidStream_cancelsWithoutRestore() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "partial", generation: session.generation)

        // External owner (draft swap / programmatic clear) takes the field.
        field.text = "external owner's text"
        session.noteFieldTextChanged()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(field.text, "external owner's text",
                       "the external write must win — no restore over it")
        XCTAssertNil(session.task)
    }

    func testCASMismatchAtWriteTime_selfCancelsWithoutWrite() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "first", generation: session.generation)

        // Field hijacked between deltas, no onChange delivered yet.
        field.text = "hijacked"
        session.ingest(delta: " second", generation: session.generation)

        XCTAssertEqual(field.text, "hijacked", "CAS write must refuse to clobber")
        XCTAssertEqual(session.phase, .idle)
    }

    func testCASMismatchAtFinish_selfCancelsWithoutWrite() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "partial", generation: session.generation)

        field.text = "hijacked"
        session.finishStream(generation: session.generation)

        XCTAssertEqual(field.text, "hijacked")
        XCTAssertFalse(session.canRevert)
        XCTAssertEqual(session.phase, .idle)
    }

    func testOwnWriteEcho_midStream_doesNotCancel() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "partial", generation: session.generation)

        // The session's own write comes back through .onChange — must not
        // read as an external edit.
        session.noteFieldTextChanged()

        XCTAssertEqual(session.phase, .streaming)
    }

    // MARK: - Revert offer lifecycle

    func testRevert_restoresOriginal_clearsRevertOffer() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("my rough prompt")
        start(session, field: field)
        session.ingest(delta: "Polished prompt.", generation: session.generation)
        session.finishStream(generation: session.generation)

        session.revert()

        XCTAssertEqual(field.text, "my rough prompt")
        XCTAssertFalse(session.canRevert)
    }

    func testCompletionEcho_keepsRevertOffer() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "Improved.", generation: session.generation)
        session.finishStream(generation: session.generation)

        session.noteFieldTextChanged()

        XCTAssertTrue(session.canRevert)
    }

    func testUserEditAfterCompletion_dismissesRevertOffer() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "Improved.", generation: session.generation)
        session.finishStream(generation: session.generation)

        field.text = "Improved. Plus my tweak"
        session.noteFieldTextChanged()

        XCTAssertFalse(session.canRevert)
    }

    func testSubmitClear_dismissesRevertOffer() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "Improved.", generation: session.generation)
        session.finishStream(generation: session.generation)

        // handleSubmit clears the composer draft after send.
        field.text = ""
        session.noteFieldTextChanged()

        XCTAssertFalse(session.canRevert)
    }

    func testRevert_afterFieldHijack_retiresRevertOfferWithoutWrite() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "Improved.", generation: session.generation)
        session.finishStream(generation: session.generation)
        let writesBefore = field.writes.count

        // Field replaced without an onChange having reached the session yet.
        field.text = "hijacked"
        session.revert()

        XCTAssertEqual(field.text, "hijacked", "revert must not clobber a foreign value")
        XCTAssertEqual(field.writes.count, writesBefore)
        XCTAssertFalse(session.canRevert)
    }

    // MARK: - Chained improve

    func testChainedImprove_revertRestoresV0() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("v0 user text")
        start(session, field: field)
        session.ingest(delta: "v1 improved", generation: session.generation)
        session.finishStream(generation: session.generation)
        XCTAssertEqual(field.text, "v1 improved")

        // Improve the improved text — Revert must still mean "my own words".
        start(session, field: field)
        XCTAssertEqual(box.capturedPrompt, "v1 improved", "the chained run rewrites v1")
        session.ingest(delta: "v2 improved", generation: session.generation)
        session.finishStream(generation: session.generation)
        XCTAssertEqual(field.text, "v2 improved")

        session.revert()

        XCTAssertEqual(field.text, "v0 user text")
    }

    func testEditedThenImproved_capturesNewV0() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("v0")
        start(session, field: field)
        session.ingest(delta: "v1", generation: session.generation)
        session.finishStream(generation: session.generation)

        // User edits the improved text → the edit becomes the new v0.
        field.text = "v1 edited by user"
        session.noteFieldTextChanged()
        start(session, field: field)
        session.ingest(delta: "v2", generation: session.generation)
        session.finishStream(generation: session.generation)

        session.revert()

        XCTAssertEqual(field.text, "v1 edited by user")
    }

    // MARK: - Additional guard corners

    func testExternalEditDuringWaiting_cancelsWithoutRestore() async {
        // Distinct from the mid-stream case: the field is hijacked BEFORE any
        // content arrived (baseline still == original, lastWritten nil).
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        XCTAssertEqual(session.phase, .waitingForFirstDelta)

        field.text = "external owner's text"
        session.noteFieldTextChanged()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(field.text, "external owner's text",
                       "an external write during the thinking window must win — no restore")
        XCTAssertTrue(field.writes.isEmpty)
        XCTAssertNil(session.task)
    }

    func testRevert_duringStreaming_isNoOp() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)
        session.ingest(delta: "half rewrite", generation: session.generation)
        let writesBefore = field.writes.count

        session.revert()

        XCTAssertEqual(session.phase, .streaming, "revert must not disturb an in-flight stream")
        XCTAssertEqual(field.writes.count, writesBefore)
        XCTAssertEqual(field.text, "half rewrite")
    }

    func testRevert_whenNoRevertOffer_isNoOp() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")

        session.revert()

        XCTAssertEqual(field.text, "original")
        XCTAssertTrue(field.writes.isEmpty)
        XCTAssertFalse(session.canRevert)
    }

    func testStop_whenIdle_isNoOp() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")

        session.stop()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(field.writes.isEmpty)
    }

    func testStartAfterRevert_capturesRevertedTextAsNewOriginal() async {
        // Revert to v0, then improve again — Revert on the new run restores the
        // reverted text (which IS v0), and a fresh baseline is captured.
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("v0")
        start(session, field: field)
        session.ingest(delta: "v1", generation: session.generation)
        session.finishStream(generation: session.generation)
        session.revert()
        XCTAssertEqual(field.text, "v0")

        start(session, field: field)
        XCTAssertEqual(box.capturedPrompt, "v0", "the reverted text is what the new run rewrites")
        session.ingest(delta: "v1 again", generation: session.generation)
        session.finishStream(generation: session.generation)

        session.revert()
        XCTAssertEqual(field.text, "v0")
    }

    func testNoteFieldTextChanged_idleNoRevertOffer_isInert() async {
        // With no active run and no revert offer, field edits must not touch session state.
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")

        field.text = "user typing freely"
        session.noteFieldTextChanged()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.canRevert)
    }

    // MARK: - Pump integration (real Task via held continuation)

    func testPumpIntegration_deltasFlowEndToEnd() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        await waitUntil(box.continuation != nil)
        XCTAssertNotNil(box.continuation, "pump never subscribed to the provider stream")

        box.continuation?.yield("Hello")
        await waitUntil(session.phase == .streaming)
        XCTAssertEqual(field.text, "Hello")

        box.continuation?.yield(" world.  ")
        await waitUntil(field.text == "Hello world.  ")

        box.continuation?.finish()
        await waitUntil(!session.isImproving)

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(field.text, "Hello world.", "final write is post-processed (trimmed)")
        XCTAssertTrue(session.canRevert)
    }

    func testPumpIntegration_errorPath_restoresOriginal() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        await waitUntil(box.continuation != nil)
        box.continuation?.yield("partial")
        await waitUntil(session.phase == .streaming)

        box.continuation?.finish(throwing: NSError(
            domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Server error"]))
        await waitUntil(!session.isImproving)

        XCTAssertEqual(session.errorMessage, "Server error")
        XCTAssertEqual(field.text, "original")
    }

    func testPumpIntegration_stopCancelsTask_lateDeltaDropped() async {
        let box = StreamBox()
        let session = makeSession(box: box)
        let field = Field("original")
        start(session, field: field)

        await waitUntil(box.continuation != nil)
        box.continuation?.yield("partial")
        await waitUntil(session.phase == .streaming)

        session.stop()
        XCTAssertEqual(field.text, "original")

        // A delta already queued in the stream must not resurrect the rewrite.
        box.continuation?.yield(" late")
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(field.text, "original")
        XCTAssertEqual(session.phase, .idle)
    }
}
