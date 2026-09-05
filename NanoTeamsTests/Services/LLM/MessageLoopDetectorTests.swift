import XCTest

@testable import NanoTeams

/// Run 6 regression: Code Reviewer emitted 14 consecutive near-identical
/// "I'm sorry, I can't create files…" messages (interleaved with user nudges)
/// that the since-deleted `collapseRedundantAssistantTextRuns` couldn't compact. The program had
/// no escape hatch; 27 iterations wasted until the run was killed.
/// `ConversationRepairService.detectMessageLoop` is the new detector.
final class MessageLoopDetectorTests: XCTestCase {

    // MARK: - Happy path

    func testDetect_threeIdenticalRefusals_isRefusalLoop() {
        let messages: [ChatMessage] = [
            .init(role: .system, content: "You are CR"),
            .init(role: .user, content: "Review the code."),
            .init(role: .assistant, content: "I'm sorry, but I don't have the ability to create files."),
            .init(role: .user, content: "Please try again."),
            .init(role: .assistant, content: "I'm sorry, but I don't have the ability to create files in this environment."),
            .init(role: .user, content: "Take another pass."),
            .init(role: .assistant, content: "I'm sorry, but I don't have the ability to create files."),
        ]
        let outcome = ConversationRepairService.detectMessageLoop(conversationMessages: messages)
        guard case .refusalLoop(let count, let sample) = outcome else {
            return XCTFail("Expected refusalLoop, got \(outcome)")
        }
        XCTAssertEqual(count, 3)
        XCTAssertTrue(sample.contains("I'm sorry"))
    }

    func testDetect_curlyApostropheRefusal_isRefusalLoop() {
        // Model may emit curly `’` instead of straight `'`. Regex must handle both.
        let fancy = "I\u{2019}m sorry, but I cannot create files in this environment."
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: fancy),
            .init(role: .user, content: "try again"),
            .init(role: .assistant, content: fancy),
            .init(role: .user, content: "try again"),
            .init(role: .assistant, content: fancy),
        ]
        let outcome = ConversationRepairService.detectMessageLoop(conversationMessages: messages)
        if case .refusalLoop = outcome { /* ok */ } else {
            XCTFail("Expected refusalLoop for curly-apostrophe refusal; got \(outcome)")
        }
    }

    /// `sample` is the NEWEST refusal — the one the Supervisor question quotes back. The old
    /// walk collected newest-first and read `recent[0]`; the split walk returns oldest-first, so
    /// the classifier must read the LAST entry. Three refusals in different wording make the
    /// two ends distinguishable; the identical-refusal vectors above cannot tell them apart.
    ///
    /// RED: change `sample:` in `classifyMessageLoop` to `recent[0]` → this reads the oldest
    /// refusal ("…create files.") instead of the newest ("…write to this sandbox.").
    func testDetect_refusalLoop_sampleIsTheNewestRefusal() {
        let oldest = "I'm sorry, but I don't have the ability to create files."
        let newest = "I'm sorry, but I can't write to this sandbox."
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: oldest),
            .init(role: .user, content: "Please try again."),
            .init(role: .assistant, content: "I'm sorry, but I cannot modify the repository."),
            .init(role: .user, content: "Take another pass."),
            .init(role: .assistant, content: newest),
        ]
        let outcome = ConversationRepairService.detectMessageLoop(conversationMessages: messages)
        guard case .refusalLoop(let count, let sample) = outcome else {
            return XCTFail("Expected refusalLoop, got \(outcome)")
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(sample, newest, "the sample must be the wire's LAST refusal, not its first")
        XCTAssertEqual(
            ConversationRepairService.classifyMessageLoop(
                recentNoToolAssistantContents: ConversationRepairService.recentNoToolAssistantContents(in: messages)),
            outcome, "the split spelling agrees with the reference on the same wire")
    }

    // MARK: - Repetitive non-refusal

    func testDetect_threeIdenticalNonRefusals_isRepetitive() {
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: "Okay, continuing with the task."),
            .init(role: .user, content: "proceed"),
            .init(role: .assistant, content: "Okay, continuing with the task."),
            .init(role: .user, content: "proceed"),
            .init(role: .assistant, content: "Okay, continuing with the task."),
        ]
        let outcome = ConversationRepairService.detectMessageLoop(conversationMessages: messages)
        guard case .repetitiveNonTool(let count) = outcome else {
            return XCTFail("Expected repetitiveNonTool, got \(outcome)")
        }
        XCTAssertEqual(count, 3)
    }

    // MARK: - Ring ≡ walk

    /// The tool loop no longer calls `detectMessageLoop` per iteration: it keeps
    /// `StepExecutionState.recentNoToolAssistantContents` — seeded by the same tail walk at
    /// step entry, pushed once per appended assistant turn through the same membership
    /// predicate — and hands that ring to `classifyMessageLoop`. This pins that the two
    /// spellings cannot disagree: for every wire and every split point, seed-then-push equals
    /// the walk, and the classifier over the ring equals the reference `detectMessageLoop`.
    ///
    /// Randomised, because the discriminating inputs (a refusal run longer than the window,
    /// three refusals in different wording, `toolCalls: []` versus `nil`, empty and nil content)
    /// are exactly the ones a hand-written vector list forgets. Seeded per trial
    /// (`SeededGenerator`), so a failing trial replays from the number in its message and the
    /// dumped wire can be pasted into a hand vector — `xcodebuild` strips assertion messages
    /// (CLAUDE.md Testing Conventions #7), and a system-seeded counter-example is gone by the
    /// next run.
    ///
    /// What this does NOT pin: the classifier's own semantics. `detectMessageLoop` is composed
    /// from the same `classifyMessageLoop`, so a classifier-only mutation (say, `sample:` reading
    /// the oldest entry) changes both sides identically — measured on 2026-09-03, that mutation
    /// left all 399 targeted tests green. `testDetect_refusalLoop_sampleIsTheNewestRefusal` below
    /// pins that half against a hand-written wire.
    ///
    /// RED: delete the `removeFirst` in `pushMessageLoopContent` → `.refusalLoop(count:)` reports
    /// 4+ on long refusal runs while the reference says 3 (and the ring stops equalling the walk).
    func testRing_seedThenPush_agreesWithTheWireWalk_onRandomisedConversations() {
        let refusalA = "I'm sorry, but I don't have the ability to create files."
        let refusalB = "I can't write to this sandbox."
        let contents: [String?] = [refusalA, refusalB, "Okay, continuing.", "", nil]
        let call = ChatToolCall(id: "c", name: "read_file", argumentsJSON: "{}")
        let toolCallShapes: [[ChatToolCall]?] = [[call], nil, []]
        let roles: [MessageRole] = [.assistant, .user, .tool, .system]

        for trial in 0..<400 {
            let seed = UInt64(trial) &* 0x9E37_79B9_7F4A_7C15
            var rng = SeededGenerator(seed: seed)
            let n = Int.random(in: 0...60, using: &rng)
            var wire: [ChatMessage] = []
            for i in 0..<n {
                let role = roles[Int.random(in: 0..<roles.count, using: &rng)]
                if role == .assistant {
                    let content = Bool.random(using: &rng)
                        ? contents[Int.random(in: 0..<contents.count, using: &rng)]
                        : "distinct \(i)"
                    wire.append(ChatMessage(
                        role: .assistant, content: content,
                        toolCalls: toolCallShapes[Int.random(in: 0..<toolCallShapes.count, using: &rng)]))
                } else {
                    wire.append(ChatMessage(role: role, content: "m\(i)"))
                }
            }
            let k = Int.random(in: 0...n, using: &rng)

            var ring = ConversationRepairService.recentNoToolAssistantContents(in: Array(wire[..<k]))
            for message in wire[k...] where ConversationRepairService.qualifiesForMessageLoop(message) {
                ConversationRepairService.pushMessageLoopContent(message.content!, into: &ring)
            }

            let dump = wire.map { message in
                "\(message.role)/\(message.toolCalls.map { "\($0.count)" } ?? "nil")/\(message.content ?? "nil")"
            }.joined(separator: " | ")
            XCTAssertEqual(
                ring, ConversationRepairService.recentNoToolAssistantContents(in: wire),
                "trial \(trial) seed=\(seed) n=\(n) k=\(k): seed-then-push must equal the walk "
                    + "over the whole wire; wire: \(dump)")
            XCTAssertEqual(
                ConversationRepairService.classifyMessageLoop(recentNoToolAssistantContents: ring),
                ConversationRepairService.detectMessageLoop(conversationMessages: wire),
                "trial \(trial) seed=\(seed) n=\(n) k=\(k): the classifier over the ring must "
                    + "equal the reference detector; wire: \(dump)")
        }
    }

    /// The reference detector and the split halves keep the same window guard at every
    /// `window`, not just 3 — a `window` of 1 would make every single reply a "loop".
    ///
    /// RED: drop `guard window >= 2 else { return .noLoop }` from `classifyMessageLoop` → the
    /// `window: 1` row classifies three refusals as a `.refusalLoop`.
    func testClassify_windowBelowTwo_isNoLoop_forEveryInput() {
        let three = ["I'm sorry, I can't.", "I'm sorry, I can't.", "I'm sorry, I can't."]
        XCTAssertEqual(
            ConversationRepairService.classifyMessageLoop(recentNoToolAssistantContents: three, window: 1),
            .noLoop)
        XCTAssertEqual(
            ConversationRepairService.classifyMessageLoop(recentNoToolAssistantContents: three, window: 0),
            .noLoop)
        XCTAssertNotEqual(
            ConversationRepairService.classifyMessageLoop(recentNoToolAssistantContents: three, window: 3),
            .noLoop, "anti-vacuum: the same input IS a loop at the real window")
    }

    // MARK: - No loop

    func testDetect_variedResponses_isNoLoop() {
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: "Starting work on the review."),
            .init(role: .user, content: "proceed"),
            .init(role: .assistant, content: "Found issue 1 in Calculator.swift line 42."),
            .init(role: .user, content: "continue"),
            .init(role: .assistant, content: "Found issue 2 in Display.swift line 10."),
        ]
        let outcome = ConversationRepairService.detectMessageLoop(conversationMessages: messages)
        XCTAssertEqual(outcome, .noLoop)
    }

    func testDetect_onlyTwoIdenticalRefusals_isNoLoop() {
        // Window default is 3; under-threshold must not fire.
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: "I'm sorry, I can't create files."),
            .init(role: .user, content: "try again"),
            .init(role: .assistant, content: "I'm sorry, I can't create files."),
        ]
        let outcome = ConversationRepairService.detectMessageLoop(conversationMessages: messages)
        XCTAssertEqual(outcome, .noLoop)
    }

    func testDetect_emptyMessages_isNoLoop() {
        XCTAssertEqual(
            ConversationRepairService.detectMessageLoop(conversationMessages: []),
            .noLoop
        )
    }

    func testDetect_ignoresAssistantToolCallMessages() {
        // An assistant message with toolCalls doesn't count as a text-only response,
        // so a single interspersed tool call should break the loop.
        let toolCall = ChatToolCall(id: "x", name: "read_file", argumentsJSON: "{}")
        let messages: [ChatMessage] = [
            .init(role: .assistant, content: "I'm sorry, I can't."),
            .init(role: .user, content: "try again"),
            .init(role: .assistant, content: nil, toolCallID: nil, toolCalls: [toolCall]),
            .init(role: .tool, content: "result"),
            .init(role: .assistant, content: "I'm sorry, I can't."),
            .init(role: .user, content: "try again"),
            .init(role: .assistant, content: "I'm sorry, I can't."),
        ]
        // The detector walks back; it will collect: the last 3 text-only assistants.
        // Those are the 3 refusals (the tool-call assistant is skipped). So this IS
        // still a refusalLoop — which is correct: the model resumed its refusal
        // pattern after a tool attempt.
        let outcome = ConversationRepairService.detectMessageLoop(conversationMessages: messages)
        if case .refusalLoop = outcome { /* ok */ } else {
            XCTFail("Expected refusalLoop; refusals are counted across tool-call-interleaved turns. Got \(outcome)")
        }
    }

    // MARK: - Fingerprint normalization

    /// The membership rule has ONE home (`qualifiesForMessageLoop`) and BOTH sides of the
    /// ring-≡-walk comparison read it, so a mutation of the predicate moves both sides at once
    /// and the randomized equivalence sweep stays green. This vector pins the rule itself: an
    /// assistant turn that CARRIES tool calls never counts, even when it also carries text
    /// (`testDetect_ignoresAssistantToolCallMessages` gives its tool-call turn `content: nil`, so
    /// the content clause alone kept it green under that mutation — measured 2026-09-03).
    ///
    /// RED: drop `(message.toolCalls?.isEmpty ?? true)` from `qualifiesForMessageLoop` → the three
    /// refusal-worded tool-call turns qualify and the first wire classifies `.refusalLoop`.
    func testDetect_assistantTurnWithToolCallsAndText_neverCountsTowardTheLoop() {
        let call = ChatToolCall(id: "x", name: "read_file", argumentsJSON: "{}")
        let refusal = "I'm sorry, I can't."
        let toolTurn = ChatMessage(role: .assistant, content: refusal, toolCallID: nil, toolCalls: [call])
        let withToolCalls: [ChatMessage] = [
            toolTurn, .init(role: .tool, content: "r"),
            toolTurn, .init(role: .tool, content: "r"),
            toolTurn, .init(role: .tool, content: "r"),
        ]
        XCTAssertEqual(
            ConversationRepairService.detectMessageLoop(conversationMessages: withToolCalls), .noLoop,
            "three refusal-worded turns that each carry a tool call are tool work, not a loop")

        // Two text-only refusals after them still do not reach the window of three.
        let twoTextOnly = withToolCalls + [
            .init(role: .assistant, content: refusal), .init(role: .user, content: "go on"),
            .init(role: .assistant, content: refusal),
        ]
        XCTAssertEqual(
            ConversationRepairService.detectMessageLoop(conversationMessages: twoTextOnly), .noLoop,
            "only the two text-only refusals qualify; the tool-call turns must not fill the window")
        XCTAssertFalse(ConversationRepairService.qualifiesForMessageLoop(toolTurn))
    }

    func testFingerprint_handlesTrailingWhitespace() {
        let a = "I'm sorry, I can't do that."
        let b = "I'm sorry, I can't do that.   \n\n"
        XCTAssertEqual(
            ConversationRepairService.normalizeForLoopFingerprint(a),
            ConversationRepairService.normalizeForLoopFingerprint(b)
        )
    }

    func testFingerprint_collapsesInnerWhitespace() {
        let a = "I'm sorry I can't do that"
        let b = "I'm  sorry    I can't\tdo   that"
        XCTAssertEqual(
            ConversationRepairService.normalizeForLoopFingerprint(a),
            ConversationRepairService.normalizeForLoopFingerprint(b)
        )
    }

    // MARK: - Refusal classifier

    func testIsRefusalContent_catchesCommonPhrases() {
        XCTAssertTrue(ConversationRepairService.isRefusalContent("I'm sorry, but I can't."))
        XCTAssertTrue(ConversationRepairService.isRefusalContent("I cannot do that."))
        XCTAssertTrue(ConversationRepairService.isRefusalContent("I don't have access."))
        XCTAssertTrue(ConversationRepairService.isRefusalContent("Unable to complete the task."))
    }

    func testIsRefusalContent_ignoresNormalText() {
        XCTAssertFalse(ConversationRepairService.isRefusalContent("Here is the code review."))
        XCTAssertFalse(ConversationRepairService.isRefusalContent("Found 3 issues."))
    }

    // MARK: - False-positive and false-negative guards
    //
    // The refusal regex is intentionally broad ("i can't", "do not allow",
    // "no permission"). That breadth is a trade-off: we catch paraphrased
    // refusals at the cost of false-matching productive text that starts with
    // "I can't" or "I'm sorry". These tests document the current status quo so
    // a future detector upgrade (positive-action classifier, volume-based
    // fallback) has a clear starting point.

    /// Known false positives: productive sentences that begin with a first-person
    /// inability phrase. The model is reporting a local constraint, not declining
    /// the work. Current regex matches — flip to `XCTAssertFalse` when the
    /// classifier learns to distinguish report-from-refusal.
    func testIsRefusalContent_productiveSentences_currentlyOverMatch() {
        let productiveButMatches = [
            "I can't thank you enough — the API design is clean.",
            "I'm sorry the prior plan was incomplete; here's the updated version.",
        ]
        for text in productiveButMatches {
            XCTAssertTrue(
                ConversationRepairService.isRefusalContent(text),
                "KNOWN_GAP: productive sentence triggers refusal match — \(text)"
            )
        }
    }

    /// Known false negatives: environment refusals that don't mention a
    /// first-person inability phrase. Currently miss — tighten regex or add a
    /// positive-action classifier to promote to `XCTAssertTrue`.
    func testIsRefusalContent_environmentRefusals_currentlyUnderMatch() {
        let refusalsButMiss = [
            "As an AI, I have to operate within the sandbox.",
            "Without filesystem access, this is the extent of help possible.",
        ]
        for text in refusalsButMiss {
            XCTAssertFalse(
                ConversationRepairService.isRefusalContent(text),
                "KNOWN_GAP: env-only refusal missed — \(text)"
            )
        }
    }

    // MARK: - Run 7 evidence — sandbox/environment refusal variants

    /// Run 7 CR emitted these exact phrases. Earlier detector missed them because
    /// they say "sandbox doesn't allow" / "environment doesn't allow" instead of
    /// "I can't" / "I'm sorry". Regex must catch the intent, not just one surface form.
    func testIsRefusalContent_sandboxDoesntAllow() {
        XCTAssertTrue(ConversationRepairService.isRefusalContent(
            "I'm ready to create the files, but this sandbox doesn't allow writing or patching source code."
        ))
    }

    func testIsRefusalContent_environmentDoesNotAllow() {
        XCTAssertTrue(ConversationRepairService.isRefusalContent(
            "I'm prepared to create the files, but this sandbox does not allow writing or patching source code."
        ))
    }

    func testIsRefusalContent_noPermission() {
        XCTAssertTrue(ConversationRepairService.isRefusalContent(
            "I don\u{2019}t have permission to modify files in this environment."
        ))
    }

    func testIsRefusalContent_dontHaveWriteAccess() {
        XCTAssertTrue(ConversationRepairService.isRefusalContent(
            "I\u{2019}m ready to add the files, but I don\u{2019}t have write access in this environment."
        ))
    }

    /// End-to-end: replay Run 7's first 5 CR messages (3 code dumps + 2 refusals)
    /// → no loop yet. Add third refusal variant → loop fires.
    func testDetect_run7ReplaySandboxRefusals_firesOnThirdVariant() {
        let codeDump = "Below are the full contents of the two new files..."
        let ref1 = "I\u{2019}m ready to add the two files, but in this environment I don\u{2019}t have permission to write."
        let ref2 = "I\u{2019}m ready to create the files, but this sandbox doesn\u{2019}t allow writing or patching source code."
        let ref3 = "I\u{2019}m ready to add the files, but I don\u{2019}t have write access in this environment."

        let msgs: [ChatMessage] = [
            .init(role: .assistant, content: codeDump),
            .init(role: .user, content: "submit the review"),
            .init(role: .assistant, content: ref1),
            .init(role: .user, content: "try again"),
            .init(role: .assistant, content: ref2),
            .init(role: .user, content: "try again"),
            .init(role: .assistant, content: ref3),
        ]
        let outcome = ConversationRepairService.detectMessageLoop(conversationMessages: msgs)
        if case .refusalLoop(let count, _) = outcome {
            XCTAssertEqual(count, 3, "Three consecutive sandbox/permission refusals must trigger")
        } else {
            XCTFail("Expected refusalLoop after 3 Run-7-style refusal variants; got \(outcome)")
        }
    }
}
