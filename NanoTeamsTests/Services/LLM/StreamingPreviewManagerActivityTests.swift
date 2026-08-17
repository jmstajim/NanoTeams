import XCTest
@testable import NanoTeams

/// Pin: `StreamingPreviewManager.hasStreamActivity` lifecycle. The flag
/// drives the UI's "Waiting" → "Generating" status flip when tokens flow
/// into invisible buffers (tool-call args, harmony envelopes). Without
/// this flag the activity feed shows "Waiting" while the model actively
/// emits tokens.
@MainActor
final class StreamingPreviewManagerActivityTests: XCTestCase {

    // MARK: - hasStreamActivity getter

    func testHasReceivedStreamActivity_unset_returnsFalse() {
        let manager = StreamingPreviewManager()
        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0),
                       "Unmarked step must report no activity — drives 'Waiting' indicator")
    }

    func testMarkStreamActivity_thenHasReceivedReturnsTrue() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        XCTAssertTrue(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0))
    }

    func testMarkStreamActivity_isolatedPerStep() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "stepA", taskID: 0)
        XCTAssertTrue(manager.hasReceivedStreamActivity(stepID: "stepA", taskID: 0))
        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "stepB", taskID: 0),
                       "Activity flag must be per-step — concurrent role steps would otherwise cross-contaminate")
    }

    func testMarkStreamActivity_idempotent() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        XCTAssertTrue(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0),
                      "Repeat marks are safe no-ops — caller fires on every delta without checking")
    }

    // MARK: - Lifecycle: commit / clear / clearAll

    func testCommit_clearsActivityFlag() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: "step1", taskID: 0, messageID: messageID, role: .softwareEngineer, content: "hello")
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        XCTAssertTrue(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0))

        manager.commit(stepID: "step1", taskID: 0)

        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0),
                       "commit must clear hasStreamActivity along with previews/thinking/progress — next stream on this step starts clean")
    }

    func testClear_clearsActivityFlag() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        XCTAssertTrue(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0))

        manager.clear(stepID: "step1", taskID: 0)

        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0),
                       "clear must remove the activity flag")
    }

    func testClearAll_clearsAllActivityFlags() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "stepA", taskID: 0)
        manager.markStreamActivity(stepID: "stepB", taskID: 0)
        manager.markStreamActivity(stepID: "stepC", taskID: 0)

        manager.clearAll()

        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "stepA", taskID: 0))
        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "stepB", taskID: 0))
        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "stepC", taskID: 0))
    }

    /// Marking activity on a step that has no other state must still flip
    /// the flag. This matters because the FIRST stream delta might arrive
    /// before any preview / thinking buffer is initialized — the indicator
    /// needs to flip immediately regardless.
    func testMarkStreamActivity_worksWithoutPriorBeginStreaming() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        XCTAssertTrue(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0),
                      "Activity flag must work even before a preview is created — UI may need to flip status before the first content delta lands")
    }

    /// `clear` must short-circuit only when ALL state is empty. Pre-fix,
    /// the guard didn't include `hasStreamActivity`, so an activity-only
    /// step would fail the guard and the flag would never be removed.
    func testClear_emptyExceptForActivity_stillClearsFlag() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        manager.clear(stepID: "step1", taskID: 0)
        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0),
                       "clear must clear the activity flag even when no other state was set for the step")
    }

    // MARK: - streamingToolCall flag (tool-call envelope assembly)

    func testIsStreamingToolCall_unset_returnsFalse() {
        let manager = StreamingPreviewManager()
        XCTAssertFalse(manager.isStreamingToolCall(stepID: "step1", taskID: 0),
                       "Unmarked step must report no tool-call streaming")
    }

    func testMarkStreamingToolCall_thenReturnsTrue() {
        let manager = StreamingPreviewManager()
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)
        XCTAssertTrue(manager.isStreamingToolCall(stepID: "step1", taskID: 0))
    }

    func testMarkStreamingToolCall_isolatedPerStep() {
        let manager = StreamingPreviewManager()
        manager.markStreamingToolCall(stepID: "stepA", taskID: 0)
        XCTAssertTrue(manager.isStreamingToolCall(stepID: "stepA", taskID: 0))
        XCTAssertFalse(manager.isStreamingToolCall(stepID: "stepB", taskID: 0),
                       "Tool-call flag must be per-step — parallel role steps must not cross-contaminate")
    }

    func testMarkStreamingToolCall_idempotent() {
        let manager = StreamingPreviewManager()
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)
        XCTAssertTrue(manager.isStreamingToolCall(stepID: "step1", taskID: 0))
    }

    func testCommit_clearsStreamingToolCall() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)
        XCTAssertTrue(manager.isStreamingToolCall(stepID: "step1", taskID: 0))

        manager.commit(stepID: "step1", taskID: 0)

        XCTAssertFalse(manager.isStreamingToolCall(stepID: "step1", taskID: 0),
                       "commit must clear streamingToolCall — the next iteration's stream starts clean")
    }

    func testClear_clearsStreamingToolCall() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)

        manager.clear(stepID: "step1", taskID: 0)

        XCTAssertFalse(manager.isStreamingToolCall(stepID: "step1", taskID: 0))
    }

    func testClearAll_clearsStreamingToolCall() {
        let manager = StreamingPreviewManager()
        manager.markStreamingToolCall(stepID: "stepA", taskID: 0)
        manager.markStreamingToolCall(stepID: "stepB", taskID: 0)

        manager.clearAll()

        XCTAssertFalse(manager.isStreamingToolCall(stepID: "stepA", taskID: 0))
        XCTAssertFalse(manager.isStreamingToolCall(stepID: "stepB", taskID: 0))
    }

    /// Guard-condition pin (same regression shape as
    /// `testClear_emptyExceptForActivity_stillClearsFlag`): `clear`'s
    /// short-circuit guard must include `streamingToolCall`, otherwise a
    /// step carrying ONLY this flag early-returns and leaks a false
    /// "Generating" into the step's next stream.
    func testClear_emptyExceptForToolCallFlag_stillClearsFlag() {
        let manager = StreamingPreviewManager()
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)
        manager.clear(stepID: "step1", taskID: 0)
        XCTAssertFalse(manager.isStreamingToolCall(stepID: "step1", taskID: 0),
                       "clear must clear streamingToolCall even when no other state was set for the step")
    }

    /// `commit` must clear per-step transient state even when no preview
    /// exists. Pre-fix, the early `guard let preview` return skipped ALL
    /// dictionary removals — flags set after an out-of-band clear (or any
    /// future preview-less path) would survive the commit and leak into
    /// the next stream as a stale "Generating".
    func testCommit_withoutPreview_stillClearsTransientState() {
        let manager = StreamingPreviewManager()
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        manager.updateProcessingStatus(stepID: "step1", taskID: 0, status: .fraction(0.5))

        manager.commit(stepID: "step1", taskID: 0)

        XCTAssertFalse(manager.isStreamingToolCall(stepID: "step1", taskID: 0),
                       "commit must clear streamingToolCall even without a preview")
        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0),
                       "commit must clear hasStreamActivity even without a preview")
        XCTAssertNil(manager.processingStatus[TaskStepKey(taskID: 0, stepID: "step1")],
                     "commit must clear processingStatus even without a preview")
        XCTAssertNil(manager.lastStreamActivity(stepID: "step1", taskID: 0))
    }

    /// Companion preview-less commit pin for `thinkingPreviews` — reachable
    /// because `appendThinking` has no preview dependency (an out-of-band
    /// clear followed by in-flight envelope deltas recreates the entry
    /// alone). A selective-clear regression here would leak raw tool-call
    /// JSON into the step's next thinking section.
    func testCommit_withoutPreview_clearsThinkingPreview() {
        let manager = StreamingPreviewManager()
        manager.appendThinking(stepID: "step1", taskID: 0, content: "<|call|>{\"partial\":")

        manager.commit(stepID: "step1", taskID: 0)

        XCTAssertNil(manager.streamingThinking(stepID: "step1", taskID: 0),
                     "commit must clear thinkingPreviews even without a preview")
    }

    /// Retry-path pin: a generic (non-cancellation) mid-stream error
    /// bypasses both commit and clear — the in-step retry re-enters
    /// `performStreamingCall`, whose `beginStreaming` MUST reset the
    /// per-stream flags. Without this, a stream that flipped the
    /// tool-call flag and then died on a network error shows a false
    /// "Generating" through the retry's sleep + prompt-processing.
    func testBeginStreaming_resetsStreamingToolCall() {
        let manager = StreamingPreviewManager()
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)

        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: UUID(), role: .softwareEngineer)

        XCTAssertFalse(manager.isStreamingToolCall(stepID: "step1", taskID: 0),
                       "A fresh stream starts with no tool-call signal")
    }

    /// Same retry-path leak applies to `hasStreamActivity` (pre-existing,
    /// fixed in the same pass): a fresh stream has received nothing yet,
    /// so the indicator must read "Waiting"/"Processing", not a stale
    /// "Generating" from the failed attempt.
    func testBeginStreaming_resetsHasStreamActivity() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1", taskID: 0)

        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: UUID(), role: .softwareEngineer)

        XCTAssertFalse(manager.hasReceivedStreamActivity(stepID: "step1", taskID: 0),
                       "A fresh stream starts with no received deltas")
    }

    /// The worst retry-path leak: a failed attempt's thinking preview now
    /// carries partial tool-call JSON (the envelope pipe). Without the
    /// reset, the retry's thinking row starts pre-populated with that
    /// garbage AND `hasThinkingContent` suppresses the retry's genuine
    /// "Processing X%" row (thinking outranks everything in the resolver).
    func testBeginStreaming_resetsThinkingPreview() {
        let manager = StreamingPreviewManager()
        manager.appendThinking(stepID: "step1", taskID: 0, content: "<|call|>{\"path\":\"src/eng")

        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: UUID(), role: .softwareEngineer)

        XCTAssertNil(manager.streamingThinking(stepID: "step1", taskID: 0),
                     "A fresh stream starts with an empty thinking preview — the failed attempt's envelope text must not leak into the retry")
    }

    func testBeginStreaming_resetsProcessingProgress() {
        let manager = StreamingPreviewManager()
        manager.updateProcessingStatus(stepID: "step1", taskID: 0, status: .fraction(0.47))

        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: UUID(), role: .softwareEngineer)

        XCTAssertNil(manager.processingStatus[TaskStepKey(taskID: 0, stepID: "step1")],
                     "A fresh stream starts with no progress signal — a stale percent must not survive into the retry")
    }

    // MARK: - structuralVersion discipline (timeline-rebuild churn guard)

    /// `structuralVersion` increments ONLY on preview add/remove — flag sets
    /// and thinking appends are polled by TimelineView and must NOT trigger
    /// timeline rebuilds. The tool-call flag flips at marker-detection
    /// frequency; bumping the version there would churn `recomputeAndRebuild`
    /// mid-stream.
    func testMarkStreamingToolCall_doesNotBumpStructuralVersion() {
        let manager = StreamingPreviewManager()
        let before = manager.structuralVersion

        manager.markStreamingToolCall(stepID: "step1", taskID: 0)
        manager.markStreamingToolCall(stepID: "step2", taskID: 0)

        XCTAssertEqual(manager.structuralVersion, before,
                       "Flag sets are polled state — no structural change, no rebuild")
    }

    func testAppendThinking_doesNotBumpStructuralVersion() {
        let manager = StreamingPreviewManager()
        let before = manager.structuralVersion

        manager.appendThinking(stepID: "step1", taskID: 0, content: "<|call|>{\"name\":\"edit_file\"")
        manager.appendThinking(stepID: "step1", taskID: 0, content: ",\"arguments\":{}}")

        XCTAssertEqual(manager.structuralVersion, before,
                       "Envelope deltas stream at token rate — thinking appends must never trigger rebuilds")
    }

    /// The commit restructure (clear-even-without-preview) must keep the
    /// version bump CONDITIONAL: clearing flag-only transient state removes
    /// no preview, so no rebuild is warranted.
    func testCommit_withoutPreview_doesNotBumpStructuralVersion() {
        let manager = StreamingPreviewManager()
        manager.markStreamingToolCall(stepID: "step1", taskID: 0)
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        let before = manager.structuralVersion

        manager.commit(stepID: "step1", taskID: 0)

        XCTAssertEqual(manager.structuralVersion, before,
                       "No preview existed → nothing structural changed → no rebuild signal")
    }

    // MARK: - lastStreamActivityAt timestamp (Autovisor stuck-detector hang signal)

    /// The timestamp must be stamped on a delta and READABLE — the Autovisor
    /// stuck-detector reads it to tell a hung role from one mid-response.
    func testMarkStreamActivity_stampsLastActivityTimestamp() {
        let manager = StreamingPreviewManager()
        XCTAssertNil(manager.lastStreamActivity(stepID: "step1", taskID: 0),
                     "no activity yet → nil (detector falls back to persisted timestamps)")
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        XCTAssertNotNil(manager.lastStreamActivity(stepID: "step1", taskID: 0))
    }

    func testBeginStreaming_stampsLastActivityTimestamp() {
        let manager = StreamingPreviewManager()
        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: UUID(), role: .softwareEngineer)
        XCTAssertNotNil(manager.lastStreamActivity(stepID: "step1", taskID: 0),
                        "stream begin counts as activity (covers the pre-first-token window)")
    }

    func testUpdateProcessingProgress_stampsLastActivityTimestamp() {
        let manager = StreamingPreviewManager()
        manager.updateProcessingStatus(stepID: "step1", taskID: 0, status: .fraction(0.5))
        XCTAssertNotNil(manager.lastStreamActivity(stepID: "step1", taskID: 0),
                        "prompt-processing progress is server activity — must refresh the clock or a long pre-token phase reads as a hang")
    }

    /// The activity clock records SERVER evidence. A server-reported fraction is
    /// evidence; `.indeterminate` is the app's own claim that it issued a send,
    /// so it must not masquerade as a token arriving — that would let a future
    /// caller suppress a genuine hang by re-asserting the claim.
    ///
    /// Behaviourally a no-op today (`performStreamingCall` sets `.indeterminate`
    /// exactly once, immediately after `beginStreaming`, which stamps the clock
    /// itself), which is why this is asserted against a bare manager.
    ///
    /// RED: drop the `if case .fraction` guard in `updateProcessingStatus` ->
    /// the clock is stamped and this fails.
    func testUpdateProcessingStatus_indeterminate_doesNotStampTheActivityClock() {
        let manager = StreamingPreviewManager()
        manager.updateProcessingStatus(stepID: "step1", taskID: 0, status: .indeterminate)
        XCTAssertNil(manager.lastStreamActivity(stepID: "step1", taskID: 0),
                     "an app-side 'request in flight' claim is not evidence that the server produced anything")
    }

    /// CRITICAL: the timestamp must be cleared in lockstep with `hasStreamActivity`.
    /// A stale timestamp surviving a commit would make a finished step look
    /// "recently active" and silently SUPPRESS a real hang on its next stream.
    func testCommit_clearsLastActivityTimestamp() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "step1", taskID: 0, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: "step1", taskID: 0, messageID: messageID, role: .softwareEngineer, content: "hi")
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        XCTAssertNotNil(manager.lastStreamActivity(stepID: "step1", taskID: 0))
        manager.commit(stepID: "step1", taskID: 0)
        XCTAssertNil(manager.lastStreamActivity(stepID: "step1", taskID: 0),
                     "commit must clear lastStreamActivityAt alongside hasStreamActivity")
    }

    func testClear_clearsLastActivityTimestamp() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "step1", taskID: 0)
        manager.clear(stepID: "step1", taskID: 0)
        XCTAssertNil(manager.lastStreamActivity(stepID: "step1", taskID: 0))
    }

    func testClearAll_clearsLastActivityTimestamps() {
        let manager = StreamingPreviewManager()
        manager.markStreamActivity(stepID: "stepA", taskID: 0)
        manager.markStreamActivity(stepID: "stepB", taskID: 0)
        manager.clearAll()
        XCTAssertNil(manager.lastStreamActivity(stepID: "stepA", taskID: 0))
        XCTAssertNil(manager.lastStreamActivity(stepID: "stepB", taskID: 0))
    }
}
