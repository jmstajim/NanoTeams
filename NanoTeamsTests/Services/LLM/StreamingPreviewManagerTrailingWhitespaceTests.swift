import XCTest
@testable import NanoTeams

/// The streaming content preview is `ModelTokenCleaner.clean`-normal at every moment: no
/// model tokens, no leading whitespace, no trailing whitespace — `content ==
/// clean(the last replaced value, then every delta since)`. Trailing whitespace is HELD, not
/// dropped: it is delivered in front of the next delta that carries a visible scalar, so
/// the buffer sequence stays byte-identical to the eager concatenation minus a
/// provisional tail.
///
/// Why (2026-09-14, MeditationApp task 113 run 6, LM Studio `/v1/chat/completions`,
/// `ornith-1.5-35b-a3b-mlx`): the Qwen template renders native calls as
/// `\n<tool_call>\n{…}\n</tool_call>`; LM Studio cuts the calls into `tool_calls` deltas and
/// forwards the newlines around them as ordinary `content` deltas. Every one of nine turns
/// ended its content channel with exactly `calls + 1` newlines (101 of 101 records across
/// tasks 111–113), and `SelectableMessageText` rendered each as an empty line fragment: a
/// blank band between the frozen prose and the trailing "Thinking…" row, growing with each
/// call, collapsing only when commit persisted `clean(assistantCollected)`. The Harmony
/// rewind had fixed the same band on the prompt-taught route alone (a marker-bound rewind
/// cannot see the native route, and the `\n`s keep arriving between calls).
///
/// The equality holds on ANY stream, token-dense garbage included (evening of 2026-09-14): the
/// manager keeps the RAW stream (`ModelTokenCleaner.IncrementalStrip`) and re-strips IT when a
/// delta may have completed a token — never its own previous output, which is what a single
/// forward pass makes different from `clean` on two shapes: a deletion pulling `<` and `|y|>`
/// together (`<<|x|>` + `|y|>`), and a kept opener whose next closer a deletion brings within a
/// span. Both are pinned below as equalities with `clean`; until that evening they were the
/// invariant's documented exception.
///
/// Sibling of `StreamingPreviewManagerReplaceContentTests`; the token-strip half of the
/// invariant is pinned by `DLLMStreamingPreviewTokenStripTests`.
@MainActor
final class StreamingPreviewManagerTrailingWhitespaceTests: XCTestCase {

    var manager: StreamingPreviewManager!
    private let stepID = "planner"
    private let taskID = 7

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        manager = StreamingPreviewManager()
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func append(_ content: String, stepID: String? = nil, taskID: Int? = nil,
                        messageID: UUID = UUID(), role: Role = .softwareEngineer) {
        manager.append(stepID: stepID ?? self.stepID, taskID: taskID ?? self.taskID,
                       messageID: messageID, role: role, content: content)
    }

    private var content: String? {
        manager.streamingContent(stepID: stepID, taskID: taskID)
    }

    private func begin(messageID: UUID = UUID()) {
        manager.beginStreaming(stepID: stepID, taskID: taskID, messageID: messageID, role: .softwareEngineer)
    }

    // MARK: - Hold and delivery

    /// RED: append the delta verbatim → `"prose\n\n"`.
    func testAppend_deltaEndingInNewlines_isShownWithoutTheTail() {
        begin()
        append("prose\n\n")
        XCTAssertEqual(content, "prose", "the trailing run is provisional and must not render")
    }

    func testAppend_whitespaceOnlyDelta_doesNotChangeContent() {
        begin()
        append("prose")
        append("\n")
        XCTAssertEqual(content, "prose")
        append("\n")
        XCTAssertEqual(content, "prose", "each inter-call newline is held, not rendered")
    }

    /// Byte identity across three deltas of mixed kinds: the held run comes back in stream
    /// order, in front of the next visible delta. Nothing streamed vanishes.
    func testAppend_heldTail_isDeliveredInOrder_beforeTheNextVisibleDelta() {
        begin()
        append("prose ")
        XCTAssertEqual(content, "prose")
        append("\n\n")
        XCTAssertEqual(content, "prose")
        append("more")
        XCTAssertEqual(content, "prose \n\nmore")
    }

    func testAppend_internalWhitespace_isUntouched() {
        begin()
        append("a \t b\n\nc")
        XCTAssertEqual(content, "a \t b\n\nc")
    }

    func testAppend_heldTail_doesNotBumpStructuralVersion() {
        begin()
        append("prose")
        let before = manager.structuralVersion
        append("\n\n")
        append(" ")
        XCTAssertEqual(manager.structuralVersion, before, "holding whitespace is not a structural change")
    }

    /// The pinned defect in its exact shape: prose, then the template's `\n\n` before the first
    /// call, then one `\n` per further call (four calls → five newlines), then the next turn's
    /// prose in the same buffer. `SelectableMessageText` must see `"prose"` for the whole
    /// tool-call window and the full concatenation afterwards.
    func testAppend_thePinnedDefect_nativeToolCallWindow() {
        begin()
        append("prose")
        append("\n\n")
        for _ in 0..<3 { append("\n") }
        XCTAssertEqual(content, "prose", "n+1 newlines behind n native calls must not render as a blank band")
        append("Next")
        XCTAssertEqual(content, "prose\n\n\n\n\nNext", "the held run is delivered intact — no streamed byte is lost")
    }

    // MARK: - First delta / no preview

    func testAppend_firstEverDelta_whitespaceOnly_doesNotMaterializeAPreview() {
        let before = manager.structuralVersion
        append("\n\n")
        XCTAssertFalse(manager.hasPreview(stepID: stepID, taskID: taskID),
                       "nothing the bubble can show — the same rule as replaceContent's create guard")
        XCTAssertNil(content)
        XCTAssertEqual(manager.structuralVersion, before)
    }

    func testAppend_firstEverDelta_whitespaceOnly_thenVisible_createsPreviewFromTheVisibleDelta() {
        let before = manager.structuralVersion
        append("\n\n", messageID: UUID(), role: .productManager)
        let creator = UUID()
        append("Hi", messageID: creator, role: .techLead)
        XCTAssertEqual(content, "Hi", "leading whitespace is dropped: the preview is clean-normal at both ends")
        XCTAssertEqual(manager.structuralVersion, before &+ 1)
        let preview = manager.preview(stepID: stepID, taskID: taskID)
        XCTAssertEqual(preview?.id, creator, "identity comes from the delta that materialized the preview")
        XCTAssertEqual(preview?.role, .techLead)
    }

    /// The top-of-bubble twin of the band: a token stripped at position 0 exposes leading
    /// whitespace the service's own `stripLeadingWhitespace` never saw (it runs on the raw
    /// delta). RED: preview reads `"\n\nHello"` while commit persists `"Hello"`.
    func testAppend_leadingWhitespaceExposedByAStrippedToken_isDropped() {
        begin()
        append("<|channel|>")
        XCTAssertEqual(content, "")
        append("\n\nHello")
        XCTAssertEqual(content, "Hello")
    }

    /// The strip can empty a NON-empty buffer and leave whitespace at the head — the gate must
    /// read the buffer's first scalar, not remember whether the buffer was empty before the
    /// append (adversarial review, 2026-09-14).
    func testAppend_stripExposesLeadingWhitespace_onNonEmptyBuffer() {
        begin()
        append("<|")
        XCTAssertEqual(content, "<|", "an unclosed opener is kept verbatim, as the cleaner does")
        append("end|>\n\nHi")
        XCTAssertEqual(content, "Hi")
    }

    func testAppend_afterBeginStreaming_leadingWhitespaceIsDropped() {
        begin()
        append(" \nHi")
        XCTAssertEqual(content, "Hi")
    }

    // MARK: - Unicode: the set is `clean`'s, on scalars

    func testAppend_unicodeTrailingWhitespace_isHeld() {
        let runs = ["\u{00A0}", "\u{3000}", "\r\n", "\u{2028}", "\u{2029}", "\t", "\u{0085}", " \n \t"]
        for (index, run) in runs.enumerated() {
            let step = "step-\(index)"
            let id = UUID()
            manager.beginStreaming(stepID: step, taskID: taskID, messageID: id, role: .softwareEngineer)
            manager.append(stepID: step, taskID: taskID, messageID: id, role: .softwareEngineer, content: "x" + run)
            XCTAssertEqual(manager.streamingContent(stepID: step, taskID: taskID), "x",
                           "run \(index) (\(run.unicodeScalars.map { String($0.value, radix: 16) })) must be held")
            manager.append(stepID: step, taskID: taskID, messageID: id, role: .softwareEngineer, content: "y")
            XCTAssertEqual(manager.streamingContent(stepID: step, taskID: taskID), "x" + run + "y",
                           "run \(index) must come back byte-identical with the next visible delta")
        }
    }

    /// The rule is `clean`'s SET, not Unicode's `White_Space` and not "looks blank": Foundation's
    /// `whitespacesAndNewlines` contains U+200B ZERO WIDTH SPACE (a `Cf`, which Unicode does not
    /// call whitespace) and does NOT contain U+FEFF or U+200D. A preview that trimmed by any
    /// other rule would differ from commit's value and shift when the turn lands.
    func testAppend_foundationsSetIsTheRule_zeroWidthSpaceHeld_zeroWidthJoinerNot() {
        begin()
        append("x\u{200B}")
        XCTAssertEqual(content, "x", "U+200B is in Foundation's set, so commit trims it and so must the preview")
        XCTAssertEqual(ModelTokenCleaner.clean("x\u{200B}"), "x", "the premise: commit trims it")
        append("y")
        XCTAssertEqual(content, "x\u{200B}y", "held, not dropped — it comes back with the next visible delta")

        let second = "zwj"
        let id = UUID()
        manager.beginStreaming(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer)
        manager.append(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer, content: "x\u{200D}")
        XCTAssertEqual(manager.streamingContent(stepID: second, taskID: taskID), "x\u{200D}",
                       "U+200D is not in the set: shown as delivered")
    }

    /// The cut is at a SCALAR boundary, as `trimmingCharacters(in:)` cuts: `"\u{600} "` is one
    /// grapheme (Prepend + space) and `"\r\n"` is one grapheme, and both must split and rejoin
    /// byte-exactly.
    func testAppend_cutInsideAGraphemeCluster_isByteExact() {
        begin()
        append("\u{0600}")
        append(" ")
        XCTAssertEqual(content, "\u{0600}")
        append("1")
        XCTAssertEqual(content, "\u{0600} 1")

        let second = "crlf"
        let id = UUID()
        manager.beginStreaming(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer)
        manager.append(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer, content: "a\r")
        XCTAssertEqual(manager.streamingContent(stepID: second, taskID: taskID), "a")
        manager.append(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer, content: "\nb")
        XCTAssertEqual(manager.streamingContent(stepID: second, taskID: taskID), "a\r\nb")
    }

    func testAppend_combiningMarkAfterHeldSpace_keepsTheSpace() {
        begin()
        append("a ")
        append("\u{0301}b")
        XCTAssertEqual(content, "a \u{0301}b")
    }

    /// A combining mark right after a stripped token (`<|x|>` then U+0301) fuses with the `>` into
    /// one grapheme cluster. The cleaner matches bytes (2026-09-14), so the token is found whatever
    /// cluster it ends up in — and the display is what commit persists.
    ///
    /// RED: search `<|` / `|>` with `range(of:)` on the `String` in `ModelTokenCleaner` → commit
    /// keeps `"<|x|>\u{301}"` while the screen shows `"\u{301}"`.
    func testAppend_combiningMarkAfterAStrippedToken_isWhatCommitPersists() {
        begin()
        append("<|x|>")
        XCTAssertEqual(content, "")
        append("\u{0301}")
        XCTAssertEqual(Array((content ?? "").utf8), Array("\u{0301}".utf8))
        XCTAssertEqual(Array(ModelTokenCleaner.clean("<|x|>" + "\u{0301}").utf8), Array("\u{0301}".utf8),
                       "the premise: commit strips it too")
    }

    // MARK: - Interaction with the token strip

    /// A token whose span straddles held whitespace is stripped exactly as the eager buffer
    /// would strip it: the held run is delivered BEFORE the strip runs, and `isTokenSpan`'s
    /// verdict (a newline refuses the span, a space does not) is unchanged.
    func testAppend_tokenStraddlingTheHeldTail_matchesTheEagerStrip() {
        begin()
        append("<|")
        append("\n")
        append("end|>")
        XCTAssertEqual(content, ModelTokenCleaner.clean("<|\nend|>"))
        XCTAssertEqual(content, "<|\nend|>", "a newline inside the span is not a token")

        let second = "space"
        let id = UUID()
        manager.beginStreaming(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer)
        manager.append(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer, content: "<|")
        manager.append(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer, content: " ")
        manager.append(stepID: second, taskID: taskID, messageID: id, role: .softwareEngineer, content: "end|>")
        XCTAssertEqual(manager.streamingContent(stepID: second, taskID: taskID), "",
                       "a space inside the span is a token — stripped, as the eager buffer strips it")
    }

    /// The strip can EXPOSE a trailing run that stood before the token — "strip THEN re-trim",
    /// the order the Harmony rewind already keeps. The exposed run is held, not shown.
    func testAppend_stripExposesTrailingWhitespace_itIsHeldNotShown() {
        begin()
        append("Hello\n<|")
        XCTAssertEqual(content, "Hello\n<|")
        append("end|>")
        XCTAssertEqual(content, "Hello")
        append("!")
        XCTAssertEqual(content, "Hello\n!")
    }

    func testAppend_stripExposesEverything_contentEmptyTailHeld() {
        begin()
        append("<|end|>\n")
        XCTAssertEqual(content, "")
        XCTAssertTrue(manager.hasPreview(stepID: stepID, taskID: taskID))
        append("x")
        XCTAssertEqual(content, "x", "the held newline is leading now, and leading whitespace is dropped")
    }

    /// Review finding (2026-09-14): a re-pass on whitespace-only deltas widened the gate window
    /// past what the eager append saw (the held run no longer occupied window slots) and fired
    /// a strip the old buffer never ran. The whitespace branch hands the delta to the stream,
    /// whose gate is silent by its first fact (no `>`), so no strip runs: the pulled-together
    /// `<|aaaaaaaa|>` survives, exactly as in the eager buffer and in `clean` of the whole.
    func testAppend_whitespaceOnlyDelta_runsNoStripPass() {
        begin()
        let spaces = String(repeating: " ", count: 20)
        append("<<|x|>|aaaaaaaa|>" + spaces)
        XCTAssertEqual(content, "<|aaaaaaaa|>", "one pass: `<|x|>` gone, the pulled-together span kept")
        ModelTokenCleaner._testResetStripWork()
        append("\n")
        XCTAssertEqual(ModelTokenCleaner._testStripWork(), 0, "a whitespace-only delta must not hand the buffer to the strip")
        XCTAssertEqual(content, "<|aaaaaaaa|>")
        append("Z")
        let expected = "<|aaaaaaaa|>" + spaces + "\nZ"
        XCTAssertEqual(content, expected)
        XCTAssertEqual(content, ModelTokenCleaner.clean("<<|x|>|aaaaaaaa|>" + spaces + "\nZ"),
                       "what commit persists — the window is the eager window")
    }

    /// Review finding (2026-09-14): whitespace EXPOSED by a strip stood BEFORE the tail of the
    /// same delta and before anything held later, so it is held in front, never behind.
    func testAppend_stripExposedWhitespace_isHeldInStreamOrder() {
        begin()
        append("Hello\n <|x|")
        XCTAssertEqual(content, "Hello\n <|x|", "no closer yet: the opener is content")
        append("> ")
        XCTAssertEqual(content, "Hello", "the strip exposed `\\n ` in front of the delta's own tail")
        append("\t")
        append("Z")
        XCTAssertEqual(content, "Hello\n  \tZ", "exposed run, then the tail, then the tab — stream order")
        XCTAssertEqual(content, ModelTokenCleaner.clean("Hello\n <|x|" + "> " + "\t" + "Z"))
    }

    /// The two streams on which re-stripping the buffer diverged from `clean` — the invariant's
    /// documented exception until the evening of 2026-09-14, equalities since: the manager strips
    /// the RAW stream, as commit does.
    ///
    /// RED: in `append`, strip `preview.content` again instead of taking `stripTokens(raw)` from
    /// the stream → `""` here where commit persists `"<|y|>"`.
    func testAppend_pulledTogetherToken_isWhatCommitPersists() {
        begin()
        append("<<|x|>")
        XCTAssertEqual(content, "<", "`<|x|>` gone; the stray `<` is content")
        append("|y|>")
        XCTAssertEqual(content, "<|y|>", "one pass over the stream keeps the pulled-together span")
        XCTAssertEqual(content, ModelTokenCleaner.clean("<<|x|>" + "|y|>"))
    }

    func testAppend_keptOpener_doesNotReachALaterCloserThroughADeletion() {
        begin()
        let first = "<|tool_call><|" + String(repeating: "a", count: 25) + "|>"
        append(first)
        XCTAssertEqual(content, "<|tool_call>", "the mangled opener's first closer is 41 characters on — kept")
        append(" ok|>")
        XCTAssertEqual(content, "<|tool_call> ok|>", "re-stripping the buffer would pair them at 17 and delete everything")
        XCTAssertEqual(content, ModelTokenCleaner.clean(first + " ok|>"))
    }

    /// A rewind hands the manager the stream's new truth RAW — the same bytes the service keeps in
    /// `assistantCollected` (tokens included; it strips whitespace only, for the tokens-only
    /// diagnostic) — and the manager derives the display and re-seeds its stream from it, so a
    /// delta after it strips from `rewound + delta`, which is what commit would persist.
    ///
    /// RED: seed the stream with `clean(content)` instead of `content` → `"a"` here: over the
    /// stripped seed `a <` the stray `<` and `|y|>` pair into a token, while commit's one pass over
    /// `a <<|x|>|y|>` deletes `<|x|>` and leaves `<|y|>` unpaired.
    func testReplaceContent_seedsTheRawStream_soALaterDeltaStripsFromTheRewoundTruth() {
        begin()
        append("prose <|end|> ")
        let rewound = "a <<|x|>"
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: UUID(), role: .softwareEngineer, content: rewound)
        XCTAssertEqual(content, "a <", "the display is `clean` of the rewound value: `<|x|>` gone, the stray `<` kept")
        append("|y|>")
        XCTAssertEqual(content, ModelTokenCleaner.clean(rewound + "|y|>"))
        XCTAssertEqual(
            content, "a <|y|>",
            "commit's one pass over the rewound stream: `<|x|>` deleted, `<|y|>` left as the pull-together the "
                + "pass never revisits; over the pre-rewind stream (`prose <|end|> ` + `|y|>`) `prose  |y|>` would show")
    }

    /// The seed is the RAW value because `clean` is not idempotent: a stripped seed is a different
    /// stream, and a sentinel the rewind left on screen would vanish on the next recompute.
    ///
    /// RED: seed `clean(content)` → after `<|z|>` the recompute runs over `<|y|>hi<|z|>` and shows
    /// `"hi"` — the `<|y|>` that was on screen is gone, while commit persists `"<|y|>hi"`.
    func testReplaceContent_rawSeed_keepsTheScreenOnCommitsValueAcrossALaterRecompute() {
        begin()
        append("x")
        let rewound = "<<|x|>|y|>"
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: UUID(), role: .softwareEngineer, content: rewound)
        XCTAssertEqual(content, "<|y|>", "one pass: `<|x|>` gone, the pulled-together `<|y|>` is content")
        append("hi")
        XCTAssertEqual(content, "<|y|>hi")
        append("<|z|>")
        XCTAssertEqual(content, "<|y|>hi", "the recompute is over the rewound bytes plus the deltas — `<|y|>` stays")
        XCTAssertEqual(content, ModelTokenCleaner.clean(rewound + "hi" + "<|z|>"))
    }

    /// `replaceContent` on a key with NO state seeds the stream too — the create branch, not only
    /// the rewind over a live preview.
    ///
    /// RED: skip the seed when this call created the state (seed only a state that already existed)
    /// → the later `|>` finds no `<|` in a stream that holds only itself, the gate is silent, and
    /// `"a <|x|>"` shows where commit has `"a"`.
    func testReplaceContent_noPreview_seedsTheRawStream() {
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: UUID(), role: .softwareEngineer, content: "a <|x")
        XCTAssertEqual(content, "a <|x", "no closer yet: the opener is content")
        append("|>")
        XCTAssertEqual(content, "a")
        XCTAssertEqual(content, ModelTokenCleaner.clean("a <|x" + "|>"))
    }

    /// A replacement with nothing visible is an EMPTY stream in every branch, not only on a fresh
    /// key: its bytes cannot pair with a later delta and its whitespace would be dropped as leading,
    /// so recording them only keeps the key live after everything else about it has ended.
    ///
    /// RED: seed `IncrementalStrip(raw: content)` and hold `exposed` unconditionally → the inert
    /// stream keeps the key live and the count reads 1 after `clearProcessingStatus` /
    /// `markCompacting(false)` prune.
    func testReplaceContent_nothingVisible_leavesTheKeyPrunable() {
        manager.updateProcessingStatus(stepID: stepID, taskID: taskID, status: .indeterminate)
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: UUID(), role: .softwareEngineer, content: "<|end|>")
        XCTAssertNil(content, "nothing visible: no preview is materialized")
        manager.clearProcessingStatus(stepID: stepID, taskID: taskID)
        XCTAssertEqual(manager._testLiveStepCount(), 0, "a sentinel-only rewind must not keep the key live")

        manager.markCompacting(stepID: stepID, taskID: taskID, true)
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: UUID(), role: .softwareEngineer, content: "\n\n")
        manager.markCompacting(stepID: stepID, taskID: taskID, false)
        XCTAssertEqual(manager._testLiveStepCount(), 0, "a whitespace-only rewind must not keep the key live")

        begin()
        append("x")
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: UUID(), role: .softwareEngineer, content: " <|a|>\n")
        XCTAssertEqual(content, "", "a live preview is emptied")
        append("\nnext")
        XCTAssertEqual(content, ModelTokenCleaner.clean(" <|a|>\n" + "\nnext"), "and the empty stream is the replaced one's display")
    }

    /// The rewound value's own trailing run is held like any delta's — the display is
    /// `clean`-normal, and the run comes back in front of the next visible delta.
    func testReplaceContent_trailingWhitespaceOfTheRewoundValue_isHeld() {
        begin()
        append("x")
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: UUID(), role: .softwareEngineer, content: "Plan\n\n")
        XCTAssertEqual(content, "Plan")
        append("next")
        XCTAssertEqual(content, "Plan\n\nnext")
        XCTAssertEqual(content, ModelTokenCleaner.clean("Plan\n\n" + "next"))
    }

    /// `append("")` is a no-op before anything else: it holds nothing, creates no state, and
    /// cannot keep a key live for `clear`/`clearAll`.
    func testAppend_emptyDelta_isANoOp_andCreatesNoState() {
        append("")
        XCTAssertEqual(manager._testLiveStepCount(), 0)
        begin()
        append("a ")
        append("")
        XCTAssertEqual(content, "a")
        append("b")
        XCTAssertEqual(content, "a b")
    }

    // MARK: - Isolation and resets

    func testAppend_heldTail_isPerTaskStepKey() {
        let other = taskID + 1
        let idA = UUID(), idB = UUID()
        manager.beginStreaming(stepID: stepID, taskID: taskID, messageID: idA, role: .softwareEngineer)
        manager.beginStreaming(stepID: stepID, taskID: other, messageID: idB, role: .softwareEngineer)
        append("A", messageID: idA)
        append("\n\n", messageID: idA)
        manager.append(stepID: stepID, taskID: other, messageID: idB, role: .softwareEngineer, content: "B")
        manager.append(stepID: stepID, taskID: other, messageID: idB, role: .softwareEngineer, content: "!")
        XCTAssertEqual(manager.streamingContent(stepID: stepID, taskID: other), "B!",
                       "task A's held run must not be delivered into task B's preview")
        append("a", messageID: idA)
        XCTAssertEqual(content, "A\n\na")
    }

    func testReplaceContent_dropsTheHeldTail() {
        let id = UUID()
        begin(messageID: id)
        append("abc ", messageID: id)
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: id, role: .softwareEngineer, content: "abc")
        append("d", messageID: id)
        XCTAssertEqual(content, "abcd", "the rewind is the buffer's new truth; the old tail belonged to the old one")
    }

    func testReplaceContent_normalizesBothEnds_afterStrippingTokens() {
        let id = UUID()
        begin(messageID: id)
        append("x", messageID: id)
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: id, role: .softwareEngineer,
                               content: "  Plan <|end|>\n")
        XCTAssertEqual(content, "Plan")
    }

    func testReplaceContent_whitespaceOnly_onNoPreview_doesNotMaterialize() {
        let before = manager.structuralVersion
        manager.replaceContent(stepID: stepID, taskID: taskID, messageID: UUID(), role: .softwareEngineer,
                               content: "\n\n")
        XCTAssertFalse(manager.hasPreview(stepID: stepID, taskID: taskID))
        XCTAssertEqual(manager.structuralVersion, before)
    }

    func testBeginStreaming_dropsTheHeldTail() {
        begin()
        append("abc ")
        begin()
        append("d")
        XCTAssertEqual(content, "d", "a fresh stream has received nothing — the retry path re-enters here")
    }

    /// The content assertion alone cannot see a carried held run — the recreated preview drops its
    /// leading run, which eats any carried whitespace — so the key's liveness is asserted right
    /// after the reset: a held run, or a stream, that survived it keeps the key live.
    ///
    /// RED: keep `heldTrailingWhitespace` in the state `commit` leaves → the live count is 1.
    func testCommit_dropsTheHeldTail() {
        begin()
        append("abc ")
        manager.commit(stepID: stepID, taskID: taskID)
        XCTAssertEqual(manager._testLiveStepCount(), 0, "nothing of the committed stream may survive")
        begin()
        append("d")
        XCTAssertEqual(content, "d")
    }

    func testClear_dropsTheHeldTail() {
        begin()
        append("abc ")
        manager.clear(stepID: stepID, taskID: taskID)
        XCTAssertEqual(manager._testLiveStepCount(), 0, "nothing of the cleared stream may survive")
        begin()
        append("d")
        XCTAssertEqual(content, "d")
    }

    func testClearAll_dropsTheHeldTail() {
        begin()
        append("abc ")
        manager.clearAll()
        XCTAssertEqual(manager._testLiveStepCount(), 0, "nothing of the cleared streams may survive")
        begin()
        append("d")
        XCTAssertEqual(content, "d")
    }

    /// The stream is reset with the rest of the step's state — a fresh stream has received
    /// nothing, so a closer arriving first pairs with nothing. The `_dropsTheHeldTail` tests above
    /// cannot see this through content: `d` carries no `>`, so a carried-over stream stays silent
    /// there. `beginStreaming` replaces the whole state, so the other three rows append WITHOUT a
    /// `begin()` after their reset — one would wipe whatever the reset failed to — and assert the
    /// key is not live in between.
    ///
    /// RED: carry `stream` into the state `commit` / `clear` / `clearAll` leave, or into
    /// `beginStreaming`'s fresh state → `<|x` + `|>` pair across the reset and `""` shows where the
    /// fresh stream has `"|>"`; for the first three the live count reads 1, not 0.
    func testResets_dropTheStream_notOnlyTheHeldTail() {
        begin()
        append("<|x")
        XCTAssertEqual(content, "<|x")
        begin()
        append("|>")
        XCTAssertEqual(content, "|>", "beginStreaming: the fresh stream holds only `|>` — nothing to pair with")
        manager.clearAll()

        let resets: [(String, () -> Void)] = [
            ("commit", { self.manager.commit(stepID: self.stepID, taskID: self.taskID) }),
            ("clear", { self.manager.clear(stepID: self.stepID, taskID: self.taskID) }),
            ("clearAll", { self.manager.clearAll() }),
        ]
        for (name, reset) in resets {
            begin()
            append("<|x")
            XCTAssertEqual(content, "<|x", name)
            reset()
            XCTAssertEqual(manager._testLiveStepCount(), 0, "\(name): no stream may survive the reset")
            append("|>")
            XCTAssertEqual(content, "|>", "\(name): the fresh stream holds only `|>` — nothing to pair with")
            manager.clearAll()
        }
    }

    /// The per-key guards in `clear`/`clearAll` enumerate the dictionaries by hand: a held run
    /// with no preview behind it must still be clearable, or it is delivered into the next
    /// stream on the key.
    func testClear_emptyExceptForHeldTail_stillClears() {
        append("\n\n")
        manager.clear(stepID: stepID, taskID: taskID)
        append("d")
        XCTAssertEqual(content, "d", "a stale held run must not leak into the next stream")
    }

    func testClearAll_emptyExceptForHeldTails_stillClears() {
        append("\n\n")
        manager.clearAll()
        append("d")
        XCTAssertEqual(content, "d")
    }

    // MARK: - Equivalence (measured, not argued)

    /// Everything the alphabet can build, cut at random SCALAR boundaries into deltas.
    private func randomStream(
        from alphabet: [String], using rng: inout SeededGenerator
    ) -> (eager: String, deltas: [String]) {
        var eager = ""
        for _ in 0..<Int.random(in: 0...24, using: &rng) {
            eager += alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]
        }
        let scalars = Array(eager.unicodeScalars)
        let deltaCount = Int.random(in: 1...8, using: &rng)
        var cuts = Set<Int>()
        while cuts.count < deltaCount - 1, cuts.count < scalars.count {
            cuts.insert(Int.random(in: 0...scalars.count, using: &rng))
        }
        let bounds = [0] + cuts.sorted() + [scalars.count]
        let deltas = zip(bounds, bounds.dropFirst()).map { lower, upper -> String in
            var delta = ""
            delta.unicodeScalars.append(contentsOf: scalars[lower..<upper])
            return delta
        }
        return (eager, deltas)
    }

    private static let whitespaceScalars = ["\n", " ", "\u{00A0}", "\u{3000}", "\r\n", "\u{2028}"]

    /// Token-dense garbage — the alphabet of `ModelTokenCleaner` tail tests plus the whitespace
    /// scalars `clean` trims. Until the evening of 2026-09-14 the re-stripping manager had no
    /// byte-level oracle here (one pass pulled a `<` and a `|` together into a token a later pass
    /// removed; a mangled opener reached a farther closer once a deletion shortened the span) and
    /// this test claimed only `clean`-normal edges. The manager now strips the RAW stream, so the
    /// commit value is the oracle on any input: `content == clean(prefix)` after every append,
    /// and the probe lands on the held run intact. A bare U+0301 is in the alphabet so a delta
    /// that fuses onto the buffer's last `>` is exercised (the cleaner matches bytes), and the
    /// comparison is by bytes — `==` on `String` is canonical equivalence.
    func testAppend_edgesAreCleanNormal_onRandomSplitsOfTokenDenseStreams() {
        let alphabet = [
            "<|channel|>", "<|", "|>", "<|tool_call>", "{", "a", "aaaaaaaaaaaa",
            "<|start\nmid|>", "|", "<", ">", "👩‍💻", "é", "\u{0301}", "e\u{0301}",
        ] + Self.whitespaceScalars
        let seed: UInt64 = 20_260_914
        var rng = SeededGenerator(seed: seed)
        var prefixesEndingInWhitespace = 0

        for trial in 0..<5000 {
            let (eager, deltas) = randomStream(from: alphabet, using: &rng)
            let step = "trial-\(trial)"
            let id = UUID()
            var prefix = ""
            for delta in deltas {
                manager.append(stepID: step, taskID: taskID, messageID: id, role: .softwareEngineer, content: delta)
                prefix += delta
                let shown = manager.streamingContent(stepID: step, taskID: taskID) ?? ""
                let expected = ModelTokenCleaner.clean(prefix)
                XCTAssertTrue(
                    Array(shown.utf8) == Array(expected.utf8),
                    "seed \(seed) trial \(trial): \(shown.debugDescription) is not the commit value \(expected.debugDescription) "
                        + "after \(delta.debugDescription) over \(eager.debugDescription)")
                if ModelTokenCleaner.stripTokens(prefix).unicodeScalars.last
                    .map(ModelTokenCleaner.edgeWhitespace.contains) == true {
                    prefixesEndingInWhitespace += 1
                }
            }
            manager.append(stepID: step, taskID: taskID, messageID: id, role: .softwareEngineer, content: "Z")
            let shown = manager.streamingContent(stepID: step, taskID: taskID) ?? ""
            XCTAssertTrue(shown.hasSuffix("Z"), "seed \(seed) trial \(trial): the probe must land")
            XCTAssertEqual(shown, ModelTokenCleaner.clean(eager + "Z"), "seed \(seed) trial \(trial): the held run must be delivered intact in front of the probe")
            manager.clear(stepID: step, taskID: taskID)
        }
        XCTAssertGreaterThanOrEqual(prefixesEndingInWhitespace, 1000, "seed \(seed): too few prefixes ended in whitespace")
    }

    /// The user-facing claim, on streams a model actually produces — whole sentinels, a refused
    /// span, braces, prose, whitespace, graphemes, decomposed text: after EVERY append the preview
    /// equals `ModelTokenCleaner.clean` of everything appended so far, which is the value commit
    /// persists. The bubble cannot shift when the turn lands. The test above is the same equality
    /// on garbage; the two shapes that used to be its documented exceptions are
    /// `testAppend_pulledTogetherToken_isWhatCommitPersists` and
    /// `testAppend_keptOpener_doesNotReachALaterCloserThroughADeletion`.
    func testAppend_equalsTheCommitValue_onRandomSplitsOfWellFormedStreams() {
        let alphabet = [
            "<|channel|>", "<|end|>", "{", "a", "aaaaaaaaaaaa", "<|start\nmid|>",
            "👩‍💻", "é", "e\u{0301}", "Hello, world.",
        ] + Self.whitespaceScalars
        let seed: UInt64 = 20_260_914
        var rng = SeededGenerator(seed: seed)
        var prefixesEndingInWhitespace = 0

        for trial in 0..<5000 {
            let (eager, deltas) = randomStream(from: alphabet, using: &rng)
            let step = "trial-\(trial)"
            let id = UUID()
            var prefix = ""
            for delta in deltas {
                manager.append(stepID: step, taskID: taskID, messageID: id, role: .softwareEngineer, content: delta)
                prefix += delta
                let expected = ModelTokenCleaner.clean(prefix)
                let shown = manager.streamingContent(stepID: step, taskID: taskID) ?? ""
                XCTAssertEqual(
                    shown, expected,
                    "seed \(seed) trial \(trial): after \(delta.debugDescription) over \(eager.debugDescription)")
                let stripped = ModelTokenCleaner.stripTokens(prefix)
                if stripped.unicodeScalars.last.map(CharacterSet.whitespacesAndNewlines.contains) == true {
                    prefixesEndingInWhitespace += 1
                }
            }
            manager.append(stepID: step, taskID: taskID, messageID: id, role: .softwareEngineer, content: "Z")
            XCTAssertEqual(
                manager.streamingContent(stepID: step, taskID: taskID), ModelTokenCleaner.clean(eager + "Z"),
                "seed \(seed) trial \(trial): the held run must be delivered intact in front of the probe")
            manager.clear(stepID: step, taskID: taskID)
        }
        XCTAssertGreaterThanOrEqual(prefixesEndingInWhitespace, 1000, "seed \(seed): too few prefixes ended in whitespace")
    }

    // MARK: - Cost: O(delta), never a rescan of the buffer

    /// The tail scan reads the DELTA from its end and stops at the first visible scalar, so a
    /// stream of visible deltas costs a constant per delta however long the buffer grows; the
    /// token gate keeps its own linear bound — it is handed the WHOLE delta, tail included, so its
    /// window is delta-sized, as the eager append sized it. Two arms for the gate: deltas without
    /// `>` (its first fact answers, work ≈ Σ delta) and deltas ending in a bare `>` (its window
    /// runs on every call, work ≈ Σ (2·delta + overlap)) — the second is what a whole-buffer
    /// window would inflate.
    ///
    /// RED: scan the whole buffer for its trailing run on every append → the tail work grows
    /// as Θ(N²/delta) and fails the ratio by two orders of magnitude.
    func testAppend_visibleDeltas_tailScanIsConstantPerDelta() {
        let deltaSize = 200
        let deltaCount = 500
        let total = (deltaSize + 1) * deltaCount
        let delta = String(repeating: "a", count: deltaSize) + "\n"

        begin()
        StreamingPreviewManager._testResetTailScanWork()
        ModelTokenCleaner._testResetGateWork()
        for _ in 0..<deltaCount { append(delta) }

        XCTAssertEqual(content?.count, total - 1, "sanity: the stream really was assembled (last newline held)")
        let scanned = StreamingPreviewManager._testTailScanWork()
        XCTAssertLessThanOrEqual(
            scanned, deltaCount * 4,
            "tail scan examined \(scanned) scalars for \(deltaCount) deltas — that is a buffer rescan, not a delta scan")
        let gate = ModelTokenCleaner._testGateWork()
        XCTAssertLessThan(gate, total * 2, "the token gate must stay delta-sized on a delta without `>`")
        XCTAssertGreaterThanOrEqual(gate, total, "the gate must still see every delta it was handed, tail included")

        let closing = String(repeating: "a", count: deltaSize - 1) + ">\n"
        begin()
        ModelTokenCleaner._testResetGateWork()
        for _ in 0..<deltaCount { append(closing) }
        let windowed = ModelTokenCleaner._testGateWork()
        XCTAssertLessThan(windowed, total * 3, "a `>` in every delta runs the window every call — delta-sized, never the buffer")
        XCTAssertGreaterThanOrEqual(windowed, total * 2, "anti-vacuum: both facts read every such delta")
    }

    /// The trap the split-first order exists for: k whitespace-only deltas must cost O(k) in
    /// total. Only the TRAILING scan is counted here; the leading drop and the `.count` of the
    /// held run when it is finally delivered are each O(held) and paid once.
    ///
    /// RED: replace the whitespace-only early return with "append the delta, then detach the
    /// trailing run" → every delta re-walks every held newline, Θ(k²), three orders of
    /// magnitude over the bound.
    func testAppend_thousandWhitespaceOnlyDeltas_tailScanIsLinear() {
        let k = 2000
        begin()
        append("prose")
        StreamingPreviewManager._testResetTailScanWork()
        ModelTokenCleaner._testResetStripWork()
        for _ in 0..<k { append("\n") }
        XCTAssertEqual(ModelTokenCleaner._testStripWork(), 0,
                       "whitespace-only deltas must never hand the buffer to the strip — a kept span in the last window would be re-walked per delta")
        append("x")

        XCTAssertEqual(content, "prose" + String(repeating: "\n", count: k) + "x")
        let scanned = StreamingPreviewManager._testTailScanWork()
        XCTAssertLessThanOrEqual(
            scanned, 2 * (k + 1),
            "tail scan examined \(scanned) scalars for \(k) whitespace-only deltas — quadratic")
        XCTAssertGreaterThanOrEqual(scanned, k, "every held delta was looked at once")
    }
}
