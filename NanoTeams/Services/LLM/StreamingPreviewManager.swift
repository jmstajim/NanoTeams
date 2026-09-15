import Foundation
import Observation
#if DEBUG
import Synchronization
#endif

/// Manages streaming message previews for real-time LLM response display.
/// Main-actor-isolated manager that accumulates streaming content and provides previews to the UI.
///
/// All per-step state is keyed by `TaskStepKey` (taskID + stepID) — NOT by stepID
/// alone. `StepExecution.id` equals the team role ID, so two concurrent tasks on
/// the same team share stepID strings; a stepID-only key let one task's
/// commit/clear wipe the other task's live indicator state (the June 2026
/// concurrent-task "lost Thinking/Processing indicator" bug).
@Observable @MainActor
final class StreamingPreviewManager {

    /// Structural version — incremented only when a preview is added or removed.
    /// Views observe this to know when to rebuild the timeline,
    /// without re-evaluating on every content append.
    private(set) var structuralVersion: UInt64 = 0

    /// Everything the manager knows about ONE live step, in one value — so a reset is one
    /// removal, the liveness of a key is one lookup, and a new per-step fact is one field.
    /// Until 2026-09-14 these were nine parallel `[TaskStepKey: _]` dictionaries reset by hand
    /// in four places (a ten-term guard in `clear`, eleven `removeAll`s in `clearAll`), and
    /// every new field cost six edits plus a test that the guards still noticed it.
    ///
    /// **Invariant: `preview.content` is always `ModelTokenCleaner.clean`-normal** —
    /// model-token-stripped AND free of leading and trailing whitespace — and equals
    /// `clean(the last replaced value, then every delta since)`, the value commit persists, on
    /// ANY stream (pinned over random splits of well-formed and of token-dense streams by
    /// `StreamingPreviewManagerTrailingWhitespaceTests`). The stream itself is kept
    /// (`StepStreamState.stream`, a `ModelTokenCleaner.IncrementalStrip`) and re-stripped when a
    /// delta may have completed a token; a replace re-seeds it with the RAW replacement — the
    /// service's own `assistantCollected` at the Harmony rewind — never with a stripped copy,
    /// because `clean` is not idempotent and a pre-stripped seed is a different stream. Until the
    /// evening of 2026-09-14 the buffer was stripped AGAIN instead, and a single forward pass over
    /// its own output is not a pass over the stream: the equality failed where a deletion pulled
    /// `<` and `|y|>` together into a token the next pass removed, and where it brought a kept
    /// opener's next closer within a span. Both writers uphold the invariant, and they must:
    ///
    /// - `append` grows the stream and takes the whole-stream strip from it only when the gate
    ///   says a token may have completed, so a writer that seeded `preview.content` without
    ///   seeding `stream` would strip from a stream that does not hold what the bubble shows.
    ///   A third writer must seed both.
    /// - The trailing whitespace run is not dropped but HELD (`heldTrailingWhitespace`) until
    ///   the next delta that carries a visible scalar, so the buffer is the stream minus a
    ///   provisional tail and nothing streamed is lost. Rendered verbatim by
    ///   `SelectableMessageText`, a trailing `\n` is a real empty line fragment: the blank band
    ///   under a bubble while native tool calls are cut out of the content channel
    ///   (2026-09-14, MeditationApp task 113 run 6: the Qwen template's `\n<tool_call>…` on LM
    ///   Studio left `calls + 1` newlines behind every turn, and the band grew with each call).
    ///
    /// Commit persists `clean(assistantCollected)` — the SERVICE's value, never this buffer —
    /// so the value on screen is the committed value and the bubble cannot shift when the turn
    /// lands, on every route rather than only past the Harmony rewind.
    private struct StepStreamState {
        /// The content bubble's live text; `nil` until the first visible content or `beginStreaming`.
        var preview: StepMessage?
        /// The message `beginStreaming` pre-created for this stream, if one is open.
        var streamingMessageID: UUID?
        /// Accumulated thinking text — reasoning, plus whatever the service pipes here while a
        /// tool call is typed. Read as `nil` while empty (`streamingThinking`).
        var thinking = ""
        /// Prompt-processing status: the window between "request sent" and "first token".
        /// `.indeterminate` for every provider from stream start; refined to `.fraction` by the
        /// servers that narrate their prefill (LM Studio). See `PromptProcessingStatus`.
        var processingStatus: PromptProcessingStatus?
        /// `true` once ANY stream delta (thinking, content, harmony tool-call buffered, OpenAI
        /// tool-call delta) has been observed. Lets the UI distinguish "Waiting" (no activity
        /// yet — model still in prompt processing or hasn't started emitting) from "Generating"
        /// (tokens flowing but landing in a harmony/tool-call buffer, invisible to the
        /// previews). Without it the bubble showed "Waiting" while the model actively emitted a
        /// long tool-call argument JSON — confusing to the user (LM Studio's loaded-models panel
        /// shows token counts climbing but the activity feed appears stuck).
        var hasStreamActivity = false
        /// `true` once the live stream has committed to tool-call emission — a Harmony envelope
        /// marker was detected (`<|call|>`/`<|start|>`/`<|channel|>`, i.e. strictly "harmony
        /// envelope streaming", which is almost always a tool call) or OpenAI tool-call deltas
        /// arrived. The envelope text streams into the THINKING preview (the user watches it
        /// being typed under the animated "Thinking…" row — `MessageBubbleView.isThinkingStreaming`
        /// includes this flag so the loader keeps spinning despite frozen prose). The flag
        /// additionally overrides the frozen-prose CONTENT suppression as the indicator's
        /// "Generating" fallback while the thinking preview is still empty; a non-empty thinking
        /// preview outranks it (`hasThinkingContent` is checked first).
        var streamingToolCall = false
        /// The step's live bubble belongs to a CONTEXT-COMPACTION epoch rather than to the model
        /// taking a turn. The summary call streams through the same delegate as any other turn,
        /// so without this the bubble would say "Thinking…" while the app discards the
        /// conversation behind it — the one reading that must not happen. Set at birth by
        /// `beginStreaming(isCompacting:)` or by the epoch through `markCompacting`, and cleared
        /// when it ends, on every path including cancellation.
        var compacting = false
        /// Wall-clock timestamp of the LAST observed stream activity. Read by the Autovisor
        /// stuck-detector to tell a genuinely stalled `.running` role (token silence) from one
        /// mid-(even long-)response — tokens keep refreshing this, so a flowing response never
        /// reads as "hung". Uses `Date()` (elapsed measurement, not a model-ordering timestamp).
        ///
        /// Refreshed directly by `beginStreaming` and by `updateProcessingStatus` — the latter
        /// only for `.fraction` (a server-reported figure is evidence; the app's own
        /// `.indeterminate` claim is not) — and by `markStreamActivity`. Token-content deltas
        /// refresh it via the caller's PAIRED `markStreamActivity` call — `append` /
        /// `replaceContent` / `appendThinking` do NOT stamp it themselves (see
        /// `NTMSOrchestrator+Streaming`, which wraps each with `markStreamActivity`). A future
        /// direct caller of those must keep that pairing.
        var lastStreamActivityAt: Date?
        /// Whitespace the stream has produced that the bubble is NOT showing yet: the maximal
        /// trailing whitespace run of the token-stripped stream. Delivered in front of the next
        /// delta that carries a visible scalar (the buffer then equals the eager concatenation
        /// byte for byte), dropped when the buffer is replaced or reset (it was provisional — a
        /// rewind or a fresh stream is the new truth). The scalar set is
        /// `ModelTokenCleaner.edgeWhitespace`, the one `clean` trims. Each held scalar is walked
        /// once on arrival and once on delivery; a strip that later removes a token in front of
        /// it exposes it again and walks it again, bounded by the whole-buffer pass that strip
        /// already paid — O(run) per such strip, not per delta.
        var heldTrailingWhitespace = ""
        /// Every content delta since the last reset, verbatim — after a replace, the RAW replaced
        /// value and every delta since — behind the gate that says whether the newest one could
        /// have completed a token. `preview.content` is `stripTokens` of this with both edge runs
        /// removed, and `heldTrailingWhitespace` is its trailing run — the whole stripped stream
        /// when that is all whitespace. The reply's length held once more, freed with the step.
        var stream = ModelTokenCleaner.IncrementalStrip()

        /// Nothing recorded: every field at its default. A key in this state is not live.
        var isVacant: Bool {
            preview == nil && streamingMessageID == nil && thinking.isEmpty
                && processingStatus == nil && !hasStreamActivity && !streamingToolCall
                && !compacting && lastStreamActivityAt == nil && heldTrailingWhitespace.isEmpty
                && stream.raw.isEmpty
        }
    }

    /// Per-step state keyed by (taskID, stepID).
    /// @ObservationIgnored — content changes do not trigger view re-evaluation.
    /// Views poll through the accessors below via `LiveMessageBubble`'s poll instead.
    @ObservationIgnored private var states: [TaskStepKey: StepStreamState] = [:]

    /// Reverse lookup set for O(1) `isStreaming(messageID:)` checks.
    @ObservationIgnored private var activeMessageIDs: Set<UUID> = []

    /// Per-step caption for a tool call that is WAITING rather than working — today the
    /// only producer is `XcodeBuildGate`, whose queue can hold a role for the length of
    /// somebody else's build.
    ///
    /// A caption rather than a placeholder in `resultJSON`, and that is not a style choice:
    /// `AutovisorStatus.hasToolInFlight` reads `resultJSON == nil` to mean "a tool is still
    /// running". Filling it with a placeholder — the one existing precedent, from vision —
    /// would stop `AutovisorStuckEvaluator` suppressing its "hung" verdict, and past
    /// `stuckHangSeconds` (180) the queued role would be answered with `manage_role restart`
    /// and lose its conversation. Any queue longer than three minutes is a real one.
    ///
    /// OBSERVED, unlike the per-step state above: it changes only when the build queue
    /// changes (minutes apart), and its one reader is a leaf label inside the in-flight
    /// tool-call row (`ToolWaitCaptionLabel`), which must re-evaluate when the queue moves.
    /// Until the evening of 2026-09-11 it was `@ObservationIgnored` and had no reader at
    /// all — write-only state, and the card spun identically for a build and for a wait.
    /// Kept beside `states` rather than inside it for that reason: the struct is polled, this
    /// is observed.
    private(set) var toolWaitCaption: [TaskStepKey: String] = [:]
    /// The last gate notification applied. The gate numbers its notifications and the
    /// observer hops each one to the main actor through an unstructured `Task`, which
    /// carries no ordering guarantee: a hand-off emits up to three sets in a row, and a
    /// stale `[k]` landing after the `[]` that superseded it would pin a caption on a step
    /// that stopped waiting. Anything not newer than this is dropped.
    @ObservationIgnored private var lastToolWaitSeq: UInt64 = 0

    /// Replaces the whole waiting set in one write — the gate reports a SET, and a
    /// per-key diff here would let a stale key survive a hand-off. `seq` is the gate's
    /// notification number; an older or repeated one is ignored.
    func setToolWaitCaptions(_ keys: Set<TaskStepKey>, seq: UInt64, caption: String) {
        guard seq > lastToolWaitSeq else { return }
        lastToolWaitSeq = seq
        guard Set(toolWaitCaption.keys) != keys else { return }
        toolWaitCaption = Dictionary(uniqueKeysWithValues: keys.map { ($0, caption) })
    }

    // MARK: - Inline Streaming

    /// Marks a message as actively streaming for a step.
    /// Creates an empty preview and registers the (taskID, stepID) → messageID mapping.
    ///
    /// `isCompacting` is a birth property, not a follow-up call: the transient reset below
    /// clears the mark, so a caller raising it afterwards races the feed's own poll.
    ///
    /// Every other per-stream transient is reset too: a fresh stream has received nothing —
    /// no deltas, no tool-call signal, no thinking text, no progress, no held whitespace.
    /// Normally a no-op (commit/clear ran), but a generic mid-stream error bypasses BOTH and
    /// the in-step retry re-enters here. Without the reset, the retry inherits the failed
    /// attempt's state: stale flags mislabel its prompt-processing as "Generating", and —
    /// worse — stale thinking (now carrying partial tool-call JSON from the envelope pipe)
    /// prepends garbage to the retry's thinking row AND suppresses its "Processing X%" status
    /// (`hasThinkingContent` outranks everything in the resolver). The retry's sleep window
    /// itself still shows the old animation — acceptable: the catch path posts a visible
    /// "LLM server error … Retrying in Xs" bubble first. The activity CLOCK is stamped, not
    /// cleared — stream begin is server activity for the stuck-detector's hang heuristic.
    func beginStreaming(
        stepID: String, taskID: Int, messageID: UUID, role: Role, isCompacting: Bool = false
    ) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let isNew = states[key]?.preview == nil
        // Remove old messageID if replacing an existing streaming session
        if let oldID = states[key]?.streamingMessageID { activeMessageIDs.remove(oldID) }
        var fresh = StepStreamState()
        fresh.preview = StepMessage(
            id: messageID, createdAt: MonotonicClock.shared.now(), role: role, content: "")
        fresh.streamingMessageID = messageID
        fresh.compacting = isCompacting
        fresh.lastStreamActivityAt = MonotonicClock.shared.now()
        states[key] = fresh
        activeMessageIDs.insert(messageID)
        if isNew { structuralVersion &+= 1 }
    }

    /// Checks if a specific message is currently being streamed.
    func isStreaming(messageID: UUID) -> Bool {
        activeMessageIDs.contains(messageID)
    }

    /// Returns streaming content for a step (polled by `LiveMessageBubble`).
    func streamingContent(stepID: String, taskID: Int) -> String? {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.preview?.content
    }

    /// Returns streaming thinking content for a step (polled by `LiveMessageBubble`); nil while empty.
    func streamingThinking(stepID: String, taskID: Int) -> String? {
        guard let thinking = states[TaskStepKey(taskID: taskID, stepID: stepID)]?.thinking,
              !thinking.isEmpty else { return nil }
        return thinking
    }

    /// The message `beginStreaming` pre-created for the step's open stream, if any.
    func streamingMessageID(stepID: String, taskID: Int) -> UUID? {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.streamingMessageID
    }

    // MARK: - Content Accumulation

    /// Appends content to the streaming preview for a step.
    /// - Parameters:
    ///   - stepID: The step receiving the streaming content.
    ///   - taskID: The task owning the step.
    ///   - messageID: The message ID for the preview (used to update existing messages).
    ///   - role: The role of the message sender.
    ///   - content: The content to append.
    ///
    /// Costs `O(delta)`, not `O(accumulated buffer)`. All three halves of that are
    /// load-bearing; the first two were `O(buffer)` until 2026-08-22:
    ///
    /// 1. **In-place append.** Reading the `StepMessage` OUT of the dictionary into a
    ///    `var`, appending, and writing it back leaves the string buffer referenced twice,
    ///    so `+=` can never take its uniquely-referenced fast path: every call reallocated
    ///    and memcpy'd the whole accumulated reply. Going through the subscript's `_modify`
    ///    accessor keeps it unique — the idiom `appendThinking` below already used.
    /// 2. **Gated strip of the RAW stream.** `containsModelTokens` over the whole buffer ran on
    ///    EVERY call, and a `<|` the cleaner deliberately keeps (a mangled `<|tool_call{`) made
    ///    the strip itself fire on every later call too — a gate costing what it gates,
    ///    CLAUDE.md #106, the same defect `StreamMarkerWindow` was built for on the
    ///    neighbouring Harmony path. `ModelTokenCleaner.IncrementalStrip` puts the DECISION in a
    ///    delta-sized window — which bounded a kept span's re-fires to the deltas it stayed inside
    ///    the window for — and, since the evening of 2026-09-14, answers a delta without `>`
    ///    silently outright, so the inter-call newlines of a native tool-call turn cost no strip
    ///    at all; when it fires, it strips the whole stream as commit does — never the buffer's
    ///    own previous output, the shape that diverged from commit (see the type). Measured
    ///    2026-08-22, on the windowed in-place strip of the buffer: a 100 000-character reply
    ///    spent 336 ms on the MainActor here, 200 000 → 1 361 ms — input ×4, time ×16; with the
    ///    gate, 1.9 ms and 3.7 ms. The raw-stream shape adds one O(delta) copy per delta and, on
    ///    a fire, a whole-stream strip in place of the windowed edit; its bound is pinned as a
    ///    ratio by the work tests, not re-timed.
    /// 3. **Held tail.** The delta is split at its LAST visible scalar before anything touches
    ///    the buffer — scanned from the end, so a delta ending visibly costs one comparison —
    ///    and a whitespace-only delta never touches the buffer at all: it joins the stream and
    ///    the held run in place, and the strip cannot run for it (it carries no `>`, so the gate
    ///    is silent by its first fact). The "append, then detach the trailing run" spelling
    ///    re-walks every held scalar on every whitespace-only delta, Θ(k²) across k of them,
    ///    pinned by `StreamingPreviewManagerTrailingWhitespaceTests`.
    func append(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String) {
        guard !content.isEmpty else { return }
        let key = TaskStepKey(taskID: taskID, stepID: stepID)

        // 1. Split the DELTA into its visible head and its trailing whitespace run. O(delta).
        let scalars = content.unicodeScalars
        let cut = Self.trailingWhitespaceStart(content)
        guard cut > scalars.startIndex else {
            // Whitespace-only: nothing the bubble can show. Held in stream order behind whatever
            // is already held; neither the preview nor `structuralVersion` moves, so a first-ever
            // whitespace-only delta materializes no preview — the rule `replaceContent`'s create
            // branch already applies to a rewind to nothing. `messageID`/`role` come from the
            // delta that does create it. The stream records it all the same: whitespace carries
            // no `>`, so the gate is silent by its first fact and the strip cannot run.
            states[key, default: StepStreamState()].heldTrailingWhitespace += content
            let recomputed = states[key]!.stream.append(content)
            assert(recomputed == nil, "a delta without a visible scalar cannot complete a token")
            return
        }
        let head = String(scalars[..<cut])
        let tail = String(scalars[cut...])

        // 2. Grow the stream; take the whole-stream strip from it when this delta may have
        //    completed a token, else deliver held + head. The held run precedes the head in stream
        //    order, so the buffer is the stream's strip minus its provisional tail —
        //    byte-identical, nothing lost. On a recompute the stream already holds this delta's
        //    tail, so the trailing run detached in step 3 IS the new held run.
        if states[key] == nil { states[key] = StepStreamState() }
        var isNew = false
        if states[key]!.preview == nil {
            states[key]!.preview = StepMessage(
                id: messageID, createdAt: MonotonicClock.shared.now(), role: role, content: "")
            isNew = true
        }
        let held = states[key]!.heldTrailingWhitespace
        states[key]!.heldTrailingWhitespace = ""
        let recomputed: Bool
        if let stripped = states[key]!.stream.append(content) {
            states[key]!.preview!.content = stripped
            recomputed = true
        } else {
            states[key]!.preview!.content += held
            states[key]!.preview!.content += head
            recomputed = false
        }

        // 3. Re-establish both ends. On the append path the head ends in a visible scalar by
        //    construction, so the detach is one comparison; on a recompute the walk is bounded
        //    by the whole-stream pass just paid, and the run it detaches — whitespace the strip
        //    exposed before a token (`"Hello\n<|" + "end|>"` → `"Hello\n"`) followed by this
        //    delta's own tail — is already in stream order.
        let exposed = Self.normalizeEdges(&states[key]!.preview!.content)
        states[key]!.heldTrailingWhitespace = recomputed ? exposed : exposed + tail
        if isNew { structuralVersion &+= 1 }
    }

    /// Replaces the preview content for a step in one shot.
    ///
    /// Used to rewind when a Harmony tool-call marker is detected mid-flush, so
    /// partial prefixes like `<` or `<|` don't linger on screen after the
    /// streaming service has already decided they belong to a tool-call envelope.
    ///
    /// Takes the RAW replacement — the stream's new truth, the same bytes the rewind caller keeps
    /// as `assistantCollected` — and derives the display from it exactly as `append` derives it
    /// from the stream: strip, then hold the trailing run and drop the leading one, so the
    /// `clean`-normal invariant on the preview is enforced BY THE TYPE rather than remembered by
    /// callers; and the stream is re-seeded with the raw bytes, so `append`'s next strip runs over
    /// `rewound + deltas`, which is what commit strips. A caller that pre-stripped would hand a
    /// DIFFERENT stream: `clean` is not idempotent (`<<|x|>|y|>` → `<|y|>` → nothing), and until
    /// 2026-09-14 the seed was the stripped copy, so a sentinel the rewind left on screen would
    /// have vanished on the next recompute. Whatever was held before belonged to the old truth
    /// and is dropped. Runs units of times per stream, so the whole-buffer cost is not a
    /// per-delta one.
    ///
    /// A replacement with nothing visible — sentinels and whitespace only — IS an empty stream,
    /// and is recorded as one in every branch: every opener in it was deleted with its closer (a
    /// kept one would be visible), so nothing in it can pair with a later delta, and its
    /// whitespace would be dropped as leading in front of the next visible one. Seeding its bytes
    /// would change no display, but would keep a key `pruneIfVacant` must be able to drop; and a
    /// marker at position 0 must not materialize an empty bubble.
    func replaceContent(stepID: String, taskID: Int, messageID: UUID, role: Role, content: String) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        var buffer = ModelTokenCleaner.stripTokens(content)
        let exposed = Self.normalizeEdges(&buffer)
        guard !buffer.isEmpty else {
            guard states[key] != nil else { return }
            states[key]!.stream = ModelTokenCleaner.IncrementalStrip()
            states[key]!.heldTrailingWhitespace = ""
            if states[key]!.preview != nil { states[key]!.preview!.content = "" }
            return
        }
        if states[key] == nil { states[key] = StepStreamState() }
        states[key]!.stream = ModelTokenCleaner.IncrementalStrip(raw: content)
        states[key]!.heldTrailingWhitespace = exposed
        if states[key]!.preview != nil {
            states[key]!.preview!.content = buffer
        } else {
            states[key]!.preview = StepMessage(
                id: messageID, createdAt: MonotonicClock.shared.now(), role: role, content: buffer)
            structuralVersion &+= 1
        }
    }

    /// Appends thinking content to the streaming preview for a step.
    func appendThinking(stepID: String, taskID: Int, content: String) {
        guard !content.isEmpty else { return }
        states[TaskStepKey(taskID: taskID, stepID: stepID), default: StepStreamState()].thinking += content
    }

    // MARK: - Edge whitespace (the `clean` set, on scalars)

    /// Start of `s`'s maximal trailing whitespace run. Scanned from the END, so a string ending
    /// in a visible scalar costs one comparison however long it is. The set is
    /// `ModelTokenCleaner.edgeWhitespace`, applied to Unicode SCALARS as `trimmingCharacters(in:)`
    /// applies it: a cut inside a grapheme is legal there (`"\u{600} "` is one Character —
    /// Prepend + space; `"\r\n"` is one Character), and slicing the scalar view keeps the bytes
    /// exact where the Character view would round.
    nonisolated private static func trailingWhitespaceStart(_ s: String) -> String.Index {
        let scalars = s.unicodeScalars
        var cut = scalars.endIndex
        while cut > scalars.startIndex {
            let previous = scalars.index(before: cut)
            #if DEBUG
            _tailScanWork.wrappingAdd(1, ordering: .relaxed)
            #endif
            guard ModelTokenCleaner.edgeWhitespace.contains(scalars[previous]) else { break }
            cut = previous
        }
        return cut
    }

    /// Detaches the trailing whitespace run (returned, to be held) and drops the leading one.
    /// The leading check reads the buffer's first scalar rather than remembering whether the
    /// buffer was empty before the append: a strip can empty a NON-empty buffer and leave
    /// whitespace at the head (`"<|" + "end|>\n\nHi"`). Reached only right after a strip ran,
    /// so a walk here is bounded by what that strip already paid.
    nonisolated private static func normalizeEdges(_ buffer: inout String) -> String {
        let cut = trailingWhitespaceStart(buffer)
        var detached = ""
        if cut < buffer.unicodeScalars.endIndex {
            detached = String(buffer.unicodeScalars[cut...])
            buffer = String(buffer.unicodeScalars[..<cut])
        }
        if let first = buffer.unicodeScalars.first, ModelTokenCleaner.edgeWhitespace.contains(first) {
            let scalars = buffer.unicodeScalars
            let start = scalars.firstIndex { !ModelTokenCleaner.edgeWhitespace.contains($0) }
                ?? scalars.endIndex
            buffer = String(scalars[start...])
        }
        return detached
    }

    #if DEBUG
    /// Work-bound seam for `StreamingPreviewManagerTrailingWhitespaceTests`: scalars the tail
    /// scan has examined since the last reset. Inside the walk, not beside a call site (CLAUDE.md
    /// #62; the same placement as `ModelTokenCleaner._gateWork`), because the regression it
    /// guards is invisible in output — a whole-buffer rescan returns the same content, Θ(N²)
    /// slower.
    nonisolated private static let _tailScanWork = Atomic<Int>(0)
    nonisolated static func _testTailScanWork() -> Int { _tailScanWork.load(ordering: .relaxed) }
    nonisolated static func _testResetTailScanWork() { _tailScanWork.store(0, ordering: .relaxed) }

    /// How many steps hold ANY live state — the liveness the reset guards read. Test seam: a
    /// reset that "cleared" a flag by storing its default would still count here.
    func _testLiveStepCount() -> Int { states.count }
    #endif

    // MARK: - Processing Status

    /// Updates the prompt-processing status for a step.
    ///
    /// The activity clock is stamped for `.fraction` ONLY. A server-reported
    /// fraction IS server activity — a long prompt-processing phase (big context
    /// on a slow machine) emits these before the first token, so it must refresh
    /// the clock or the stuck-detector would mis-read the silent pre-token window
    /// as a hang. `.indeterminate` carries no such evidence: it is the app's own
    /// claim that it issued a send. Behaviourally that distinction is a no-op
    /// today — `.indeterminate` is set exactly once, immediately after
    /// `beginStreaming`, which stamps the clock itself — but it keeps the
    /// invariant "the activity clock reflects server evidence" true for any
    /// future caller that sets it more than once.
    func updateProcessingStatus(stepID: String, taskID: Int, status: PromptProcessingStatus) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        states[key, default: StepStreamState()].processingStatus = status
        if case .fraction = status {
            states[key]!.lastStreamActivityAt = MonotonicClock.shared.now()
        }
    }

    /// Clears the prompt-processing status for a step. A key left with nothing else recorded
    /// is removed — clearing a fact must not keep the step live.
    func clearProcessingStatus(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        states[key]?.processingStatus = nil
        pruneIfVacant(key)
    }

    /// Marks the step as having received at least one stream delta. Idempotent
    /// — caller fires this on every delta without checking, the manager
    /// short-circuits if the flag is already set. Call from any path that
    /// observes stream activity, including tool-call deltas and
    /// harmony-buffered content (where the delta produces no visible content
    /// in the preview).
    func markStreamActivity(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        states[key, default: StepStreamState()].hasStreamActivity = true
        states[key]!.lastStreamActivityAt = MonotonicClock.shared.now()
    }

    /// Polled by `MessageBubbleStreamingIndicator` to distinguish "Waiting"
    /// (no activity yet) from "Generating" (tokens flowing into invisible
    /// buffers like harmony tool-call args).
    func hasReceivedStreamActivity(stepID: String, taskID: Int) -> Bool {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.hasStreamActivity == true
    }

    /// Marks the step's live stream as having committed to tool-call
    /// emission (harmony envelope marker detected / OpenAI tool-call
    /// deltas arriving). Idempotent — the streaming loop fires it without
    /// checking. Callers pair it with `markStreamActivity` in the same
    /// delta iteration, which keeps `lastStreamActivityAt` fresh — this
    /// setter intentionally does NOT stamp the clock itself.
    func markStreamingToolCall(stepID: String, taskID: Int) {
        states[TaskStepKey(taskID: taskID, stepID: stepID), default: StepStreamState()].streamingToolCall = true
    }

    /// Marks (or unmarks) the step's live bubble as a compaction epoch's. Unmarking a key with
    /// nothing else recorded removes it — the mark must not keep the step live.
    func markCompacting(stepID: String, taskID: Int, _ isCompacting: Bool) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        if isCompacting {
            states[key, default: StepStreamState()].compacting = true
        } else {
            states[key]?.compacting = false
            pruneIfVacant(key)
        }
    }

    /// Polled per tick by `TeamActivityFeedView`: makes the status row read "Compacting…".
    func isCompacting(stepID: String, taskID: Int) -> Bool {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.compacting == true
    }

    /// Polled per tick by `TeamActivityFeedView` — keeps the Thinking
    /// loader animating during tool-call assembly
    /// (`MessageBubbleView.isThinkingStreaming`) and surfaces the
    /// indicator's "Generating" fallback when the thinking preview is
    /// still empty (visible prose froze at the marker).
    func isStreamingToolCall(stepID: String, taskID: Int) -> Bool {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.streamingToolCall == true
    }

    /// Wall-clock time of the last observed stream activity for a step, or nil
    /// if the step has no live stream. Consumed by the Autovisor stuck-detector.
    func lastStreamActivity(stepID: String, taskID: Int) -> Date? {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.lastStreamActivityAt
    }

    /// The step's live prompt-processing state, or nil when no request is in flight or the
    /// first generation delta has already arrived. Non-nil is therefore exactly "a request is
    /// in flight and the server has produced no token yet" — the fact the Autovisor's pre-token
    /// hang budget is keyed on, and what `TeamActivityFeedView.makeStreamingSnapshot` polls.
    func promptProcessingStatus(stepID: String, taskID: Int) -> PromptProcessingStatus? {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.processingStatus
    }

    /// Drops a key whose every field is back at its default, so "unset" operations leave no
    /// trace and the reset guards do not count a step that recorded nothing.
    private func pruneIfVacant(_ key: TaskStepKey) {
        if states[key]?.isVacant == true { states[key] = nil }
    }

    // MARK: - Commit / Clear

    /// Commits the streaming preview for a step: removes the preview, streaming
    /// mapping, thinking, and per-step transient indicator state.
    ///
    /// Returns nothing — deliberately. An earlier shape returned the committed
    /// `StepMessage?` (nil for whitespace-only content), but that value was
    /// structurally unconsumable: the one caller (`NTMSOrchestrator.commitStreaming`)
    /// persists the SERVICE's cleaned content (`ModelTokenCleaner` output on
    /// `assistantCollected`), never the raw UI buffer this manager accumulates — so
    /// the returned message was the wrong value for the only place that could read
    /// it, and no production consumer ever existed. The empty-turn suppression the
    /// return advertised is owned by `ActivityFeedBuilder` (the content-less,
    /// thinking-less, not-streaming `continue`), pinned by
    /// `ActivityFeedBuilderTests` — "no orphan bubble".
    ///
    /// Clears unconditionally: per-step transient state (flags, progress, clock,
    /// held whitespace) must not survive a commit even when no preview exists — the
    /// pre-fix early `guard let preview` return skipped ALL removals, so flags set
    /// after an out-of-band clear would leak into the next stream as a stale
    /// "Generating". A structural change (preview removal) only happened if one existed.
    func commit(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        let hadPreview = states[key]?.preview != nil
        if let msgID = states[key]?.streamingMessageID { activeMessageIDs.remove(msgID) }
        toolWaitCaption[key] = nil
        states[key] = nil
        if hadPreview { structuralVersion &+= 1 }
    }

    /// Clears the streaming preview for a step without committing.
    func clear(stepID: String, taskID: Int) {
        let key = TaskStepKey(taskID: taskID, stepID: stepID)
        guard states[key] != nil || toolWaitCaption[key] != nil else { return }
        if let msgID = states[key]?.streamingMessageID { activeMessageIDs.remove(msgID) }
        toolWaitCaption[key] = nil
        states[key] = nil
        structuralVersion &+= 1
    }

    /// Clears all streaming previews.
    func clearAll() {
        guard !states.isEmpty || !toolWaitCaption.isEmpty else { return }
        states.removeAll()
        toolWaitCaption.removeAll()
        activeMessageIDs.removeAll()
        structuralVersion &+= 1
    }

    // MARK: - Queries

    /// Gets the current preview for a step, if any.
    func preview(stepID: String, taskID: Int) -> StepMessage? {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.preview
    }

    /// Checks if there's an active preview for a step.
    func hasPreview(stepID: String, taskID: Int) -> Bool {
        states[TaskStepKey(taskID: taskID, stepID: stepID)]?.preview != nil
    }
    nonisolated deinit {}
}
