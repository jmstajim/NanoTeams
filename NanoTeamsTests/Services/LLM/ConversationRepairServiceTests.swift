import XCTest

@testable import NanoTeams

final class ConversationRepairServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - repairConversationIfNeeded

    func testRepairConversation_repairsPoisonedTail() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Build a feature"),
            ChatMessage(
                role: .assistant,
                content: nil,
                toolCalls: [ChatToolCall(id: "tc1", name: "read_file", argumentsJSON: "{\"path\":\"/bad\"}")]
            ),
            ChatMessage(role: .tool, content: "Error: file not found", toolCallID: "tc1", carriesErrorDirection: true),
            ChatMessage(role: .user, content: "Please continue without that file"),
        ]

        let originalCount = messages.count
        ConversationRepairService.repairConversationIfNeeded(&messages)

        // Poisoned tail (assistant+tool+user) replaced with single recovery user message
        XCTAssertEqual(messages.count, originalCount - 2, "Should remove 3 messages and add 1")
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertTrue(messages.last?.content?.contains("server error") ?? false)
    }

    /// The repair deletes the assistant turn the recovery message refers to —
    /// the message must therefore NAME the failed call (tool + args) so the
    /// model knows what not to repeat [Laban2025].
    func testRepairConversation_recoveryMessageNamesFailedCall() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Build a feature"),
            ChatMessage(
                role: .assistant,
                content: nil,
                toolCalls: [ChatToolCall(id: "tc1", name: "edit_file", argumentsJSON: "{\"path\":\"/x\"}")]
            ),
            ChatMessage(role: .tool, content: "Error", toolCallID: "tc1", carriesErrorDirection: true),
            ChatMessage(role: .user, content: "guidance"),
        ]
        ConversationRepairService.repairConversationIfNeeded(&messages)

        let recovery = messages.last?.content ?? ""
        XCTAssertTrue(recovery.contains("edit_file"), "must name the failed tool. Got: \(recovery)")
        XCTAssertTrue(recovery.contains("/x"), "must quote the failing arguments")
        XCTAssertFalse(recovery.contains("The tool call before this note"),
                       "generic phrasing only when the tool list is unavailable")
        XCTAssertTrue(recovery.hasPrefix("The edit_file("),
                      "the note names the call relative to itself, never as 'your previous' (playbook §3.8). Got: \(recovery)")
    }

    /// Oversized arguments are truncated in the recovery message — the repair
    /// must not re-inject a huge payload it just removed.
    func testRepairConversation_recoveryMessageTruncatesLongArgs() {
        let longArgs = "{\"content\":\"" + String(repeating: "a", count: 1000) + "\"}"
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "s"),
            ChatMessage(role: .user, content: "u"),
            ChatMessage(
                role: .assistant, content: nil,
                toolCalls: [ChatToolCall(id: "tc1", name: "write_file", argumentsJSON: longArgs)]
            ),
            ChatMessage(role: .tool, content: "Error", toolCallID: "tc1", carriesErrorDirection: true),
            ChatMessage(role: .user, content: "g"),
        ]
        ConversationRepairService.repairConversationIfNeeded(&messages)
        XCTAssertLessThan(messages.last?.content?.count ?? .max, 500)
    }

    /// The wire since 2026-09-14: the direction rides the failed call's own tool turn, so the tail
    /// is `assistant(toolCalls) → tool(carriesErrorDirection)` with no user turn after it — and it is still
    /// the poisoned shape, recognised by the flag.
    func testRepairConversation_repairsErrorTail_whenTheDirectionRidesTheToolTurn() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Build a feature"),
            ChatMessage(
                role: .assistant, content: nil,
                toolCalls: [ChatToolCall(id: "tc1", name: "read_file", argumentsJSON: "{\"path\":\"/bad\"}")],
                reasoning: "Read it first."),
            ChatMessage(
                role: .tool,
                content: "{\"ok\":false,\"error\":{\"code\":\"FILE_NOT_FOUND\"}}\n\nTool 'read_file': [FILE_NOT_FOUND] fix or choose another approach.",
                toolCallID: "tc1", carriesErrorDirection: true),
        ]
        XCTAssertTrue(ConversationRepairService.repairConversationIfNeeded(&messages))
        XCTAssertEqual(messages.count, 3, "assistant + tool removed, one recovery turn appended")
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertTrue(messages.last?.content?.contains("read_file") ?? false, "names the failed call")
        XCTAssertTrue(messages.last?.content?.contains("server error") ?? false)
    }

    /// The healthy tail every iteration ends on — `assistant(toolCalls) → tool` with results
    /// that succeeded — is not poisoned. Without the flag and without a trailing user turn the
    /// repair must stay out, or a retryable 503 during model loading would delete good work.
    func testRepairConversation_leavesAHealthyToolTailUnchanged() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "s"),
            ChatMessage(role: .user, content: "u"),
            ChatMessage(role: .assistant, content: nil,
                        toolCalls: [ChatToolCall(id: "tc1", name: "read_file", argumentsJSON: "{}")]),
            ChatMessage(role: .tool, content: "{\"ok\":true,\"data\":\"…\"}", toolCallID: "tc1"),
        ]
        let before = messages
        XCTAssertFalse(ConversationRepairService.repairConversationIfNeeded(&messages))
        XCTAssertEqual(messages, before)
    }

    /// An error ENVELOPE without the flag is not the signal — the repair reads structure, never
    /// content: a transcript that lost the flag, or a tool whose text merely mentions an error,
    /// is left alone unless a guidance turn closes the tail.
    func testRepairConversation_errorLookingContentWithoutTheFlag_isNotRepaired() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .assistant, content: nil,
                        toolCalls: [ChatToolCall(id: "tc1", name: "read_file", argumentsJSON: "{}")]),
            ChatMessage(role: .tool, content: "{\"ok\":false,\"error\":{\"code\":\"X\"}}", toolCallID: "tc1"),
        ]
        XCTAssertFalse(ConversationRepairService.repairConversationIfNeeded(&messages))
        XCTAssertEqual(messages.count, 2)
    }

    /// Several results, one of them flagged: the whole batch belongs to the failed assistant
    /// turn and goes with it.
    func testRepairConversation_batchWithOneFlaggedResult_removesTheWholeTail() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "u"),
            ChatMessage(role: .assistant, content: nil,
                        toolCalls: [ChatToolCall(id: "a", name: "read_file", argumentsJSON: "{}"),
                                    ChatToolCall(id: "b", name: "list_files", argumentsJSON: "{}")]),
            ChatMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "a"),
            ChatMessage(role: .tool, content: "{\"ok\":false}\n\nTool 'list_files': [X] …", toolCallID: "b", carriesErrorDirection: true),
        ]
        XCTAssertTrue(ConversationRepairService.repairConversationIfNeeded(&messages))
        XCTAssertEqual(messages.count, 2, "user + one recovery turn")
        XCTAssertEqual(messages.first?.content, "u")
    }

    /// The flag stands in for the `.user` direction turn the wire carried until 2026-09-14, and
    /// that turn could only repair the tail from the END: a direction on an earlier result of the
    /// batch left `tool(err) → user → tool(ok)`, which ends on a tool turn and was resent
    /// untouched. Reading "a flagged result anywhere in the trailing run" widened the repair to
    /// delete a later SUCCESSFUL result of the same batch — a write already on disk — and to tell
    /// the model both calls "had invalid arguments".
    /// RED: the repair scans the whole trailing run for the flag → it replaces this tail.
    func testRepairConversation_flaggedResultFollowedByASuccessfulOne_isLeftAlone() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "u"),
            ChatMessage(role: .assistant, content: nil,
                        toolCalls: [ChatToolCall(id: "a", name: "list_files", argumentsJSON: "{}"),
                                    ChatToolCall(id: "b", name: "write_file", argumentsJSON: "{}")]),
            ChatMessage(role: .tool, content: "{\"ok\":false}\n\nTool 'list_files': [X] …", toolCallID: "a", carriesErrorDirection: true),
            ChatMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "b"),
        ]
        let before = messages
        XCTAssertFalse(ConversationRepairService.repairConversationIfNeeded(&messages))
        XCTAssertEqual(messages, before, "a batch whose last result succeeded is not a poisoned tail")
    }

    /// The legacy shape keeps working without the flag — a transcript persisted before
    /// 2026-09-14 replays the direction as its own user turn and carried no flag.
    func testRepairConversation_legacyGuidanceTail_needsNoFlag() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .assistant, content: nil,
                        toolCalls: [ChatToolCall(id: "tc1", name: "edit_file", argumentsJSON: "{}")]),
            ChatMessage(role: .tool, content: "Error", toolCallID: "tc1"),
            ChatMessage(role: .user, content: "guidance"),
        ]
        XCTAssertTrue(ConversationRepairService.repairConversationIfNeeded(&messages))
        XCTAssertEqual(messages.count, 1)
    }

    func testRepairConversation_leavesHealthyConversationUnchanged() {
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there"),
        ]

        let originalCount = messages.count
        ConversationRepairService.repairConversationIfNeeded(&messages)

        XCTAssertEqual(messages.count, originalCount, "Healthy conversation should not be modified")
    }

    // MARK: - cleanHarmonyTokens

    func testCleanHarmonyTokens_stripsChannelAndConstrain() {
        let input = "<|channel|>final Here is my analysis <|constrain|>requirements"
        let result = ConversationRepairService.cleanHarmonyTokens(input)

        XCTAssertFalse(result.contains("<|channel|>"))
        XCTAssertFalse(result.contains("<|constrain|>"))
        XCTAssertTrue(result.contains("Here is my analysis"))
    }

    func testCleanHarmonyTokens_stripsImStartAndFunctions() {
        let input = "Hello <|im_start|>assistant world <|start|>functions.read_file"
        let result = ConversationRepairService.cleanHarmonyTokens(input)

        XCTAssertFalse(result.contains("<|im_start|>"))
        XCTAssertFalse(result.contains("<|start|>"))
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("world"))
    }

    // MARK: - isThinkingDrift

    // Regression for Run 13: qwen3.5-35b-a3b SWE step emitted a ~61,630-char
    // thinking trace with empty content and no tool call, consuming 215s and
    // timing out the run. The predicate fires on that exact shape.
    func testIsThinkingDrift_hugeThinkingEmptyContentNoToolCalls_returnsTrue() {
        XCTAssertTrue(ConversationRepairService.isThinkingDrift(
            thinkingLength: 61_630,
            contentLength: 0,
            toolCallCount: 0
        ))
    }

    func testIsThinkingDrift_atThreshold_returnsTrue() {
        XCTAssertTrue(ConversationRepairService.isThinkingDrift(
            thinkingLength: ConversationRepairService.thinkingDriftLengthThreshold,
            contentLength: 0,
            toolCallCount: 0
        ))
    }

    func testIsThinkingDrift_belowThreshold_returnsFalse() {
        XCTAssertFalse(ConversationRepairService.isThinkingDrift(
            thinkingLength: 5_000,
            contentLength: 0,
            toolCallCount: 0
        ))
    }

    func testIsThinkingDrift_contentPresent_returnsFalse() {
        // Long thinking alongside any user-visible content is not "drift" —
        // other branches (refusal, repetitive-non-tool) can classify it.
        XCTAssertFalse(ConversationRepairService.isThinkingDrift(
            thinkingLength: 50_000,
            contentLength: 42,
            toolCallCount: 0
        ))
    }

    func testIsThinkingDrift_hasToolCall_returnsFalse() {
        // A tool call IS a concrete action — never classify as drift even if
        // thinking is long.
        XCTAssertFalse(ConversationRepairService.isThinkingDrift(
            thinkingLength: 80_000,
            contentLength: 0,
            toolCallCount: 1
        ))
    }

    // MARK: - reasoningChannelToolCallNames

    // Every fixture below is a VERBATIM shape lifted from the MeditationApp work folder's
    // network logs (291 logs, 9–25 Aug 2026). 33 responses carried a `<|call|>` envelope
    // inside `[reasoning]`; before the reasoning route was removed, 39 of those envelopes
    // really executed — 15 of them mutating (`write_file`, `edit_file` ×2, `git_commit` ×3
    // incl. one `--amend`, `create_managed_task`, `manage_role` ×3, …). This predicate does
    // not resurrect that route: it only names what the model wrote so the nudge can say WHY
    // the turn produced nothing.

    /// `tasks/0/runs/273` #43, 2026-08-25 — the one well-formed reasoning-channel turn that
    /// happened AFTER the route was removed. Two envelopes, `content` empty, generation ends
    /// on `<|end|>`. Both names must come back, in written order.
    func testReasoningNames_twoWellFormedEnvelopes_returnsBothInOrder() {
        let thinking = ##"""
        Given uncertainty, the safest high-value move: request_changes on the worker.
        
        Let me write the request_changes comment.
        
        <|call|>{"name":"manage_role","arguments":{"task_id":35,"action":"request_changes","role_id":"startup_software_engineer","comment":"Delete the orphaned BreathingView.swift."}}<|end|>
        <|call|>{"name":"update_scratchpad","arguments":{"content":"# MeditationApp — ledger"}}<|end|>
        """##
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking),
            ["manage_role", "update_scratchpad"]
        )
    }

    /// Truncated payload — the model opened `<|call|>` and stopped mid-arguments, with no
    /// `<|end|>`. This is NOT "a call written in the wrong channel": nothing callable was
    /// finished, so the targeted nudge would name a defect the model does not have.
    /// Same fixture as `NoToolCallsBranchOrderingTests.testReasoningOnlyEnvelope_…`.
    func testReasoningNames_truncatedEnvelope_returnsEmpty() {
        let thinking = ##"""
        Let me try. <|call|>{"name":"write_file","arguments":{"path":"x"
        """##
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking), [],
            "An unfinished envelope is not a dispatchable call in the wrong channel"
        )
    }

    /// `tasks/0/runs/48`, 2026-08-11 — the opening sentinel itself is broken (`<|call|` with
    /// no closing `|>`, no `<|end|>`). Four consecutive turns looked like this. The same
    /// reasoning trace shows the model believed it had called tools: "I see I made two calls
    /// in sequence using <|call|> tags".
    ///
    /// **This expectation flipped on 2026-09-05, and the flip is the point.** It used to
    /// assert `[]`, on the reasoning that a mangled sentinel is a formatting failure rather
    /// than a mis-channelled call — true while `HarmonySentinelNormalizer` could not read the
    /// shape, because naming a channel would have described a defect the model did not have.
    /// The normalizer now repairs the truncated canonical sentinel (`CastleSurvivorsNT` task
    /// 12, `RealOrnithRunEnvelopeTests`), so these two envelopes ARE dispatchable — and the
    /// only thing still wrong with them is the channel they were written in. That is now the
    /// accurate diagnosis, so it is the one the nudge should carry.
    ///
    /// Still diagnosis only: `reasoningChannelToolCallNames` feeds nudge TEXT and nothing
    /// else, and `performStreamingCall` keeps its no-route-out-of-`thinkingCollected` rule
    /// (2026-08-25). Reading the reasoning channel better is not executing from it.
    func testReasoningNames_brokenOpeningSentinel_namesTheMisChannelledCalls() {
        let thinking = ##"""
        The system wants me to actually call tools properly. Let me try again.
        
        <|call|{"name":"list_tasks"}
        
        <|call|{"name":"list_files","arguments":{"path":"MeditationApp"}}
        """##
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking),
            ["list_tasks", "list_files"],
            "a repairable sentinel in the reasoning channel is a mis-channelled call, and the nudge that names the channel is the accurate one"
        )
    }

    /// The companion negative the flip above must NOT drag with it: a sentinel this file
    /// cannot repair still yields nothing. A run that CAN carry a tool name
    /// (`<|call|read_file{`) is refused by the normalizer for the reason
    /// `MangledSentinelIdentityTests` records — a repair that rewrites the run would take
    /// `read_file` with it — so there is no call to be mis-channelled.
    ///
    /// This test read `<|call| {"name":"list_tasks"}` until 2026-09-07, when the whitespace
    /// gap became repairable and the fixture stopped being unrepairable. The negative it
    /// guards is unchanged; only the shape that demonstrates it moved.
    func testReasoningNames_unrepairableSentinel_stillReturnsEmpty() {
        let thinking = ##"""
        I could write <|call|list_tasks{"limit":5} but let me think first.
        """##
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking), [],
            "an unrepairable sentinel is a formatting failure, not a mis-channelled call"
        )
    }

    /// **The price of the 2026-09-07 whitespace gap, stated rather than discovered.**
    /// `<|call| {` is repairable now, so prose that WRITES that shape mid-sentence is read
    /// as a call — here, as a call mis-channelled into reasoning.
    ///
    /// The discriminator that would remove it is "the sentinel begins its line", and it was
    /// rejected on a measurement, not on taste: `hasNormalizableOccurrence` is also the
    /// per-delta stream gate and receives a bounded WINDOW, which it cannot tell from a whole
    /// buffer, so a window opening mid-line would report normalizable, `normalize` on the full
    /// buffer would repair nothing, and `sawHarmonyMarker` would close with `earliestLower ==
    /// nil` — the truncation rewind skipped, visible prose frozen mid-turn, and a nudge about
    /// an envelope that was never there. That is the failure `c3959d4c` recorded when the same
    /// shortcut was tried for the ChatML wrapper, and it is strictly worse than this nudge.
    ///
    /// The exposure is bounded by what it takes to reach it: a COMPLETE, valid call payload
    /// written inside prose. A model quoting the taught format writes `<|call|>{…}` with its
    /// `>`, which has always dispatched, so the gap widens an opening that already existed
    /// rather than opening a new one.
    func testReasoningNames_proseWritingTheGapShape_isReadAsACall_acceptedCost() {
        let thinking = ##"""
        I could write <|call| {"name":"list_tasks"} but let me think first.
        """##
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking), ["list_tasks"],
            "characterises an accepted false positive — if this flips, the gap rule changed"
        )
    }

    /// Reasoning that only TALKS about calling tools must not be read as calling them —
    /// otherwise every planning trace becomes a mis-channelled call.
    func testReasoningNames_proseOnly_returnsEmpty() {
        let thinking = "I should call read_file on ContentView.swift, then run the build."
        XCTAssertEqual(ConversationRepairService.reasoningChannelToolCallNames(in: thinking), [])
    }

    func testReasoningNames_emptyThinking_returnsEmpty() {
        XCTAssertEqual(ConversationRepairService.reasoningChannelToolCallNames(in: ""), [])
    }

    /// `tasks/0/runs/263` #15 wrote `git_diff` four times in one reasoning block; the old
    /// route executed it four times. The nudge must say the name once.
    func testReasoningNames_repeatedIdenticalEnvelopes_deduplicates() {
        let one = ##"<|call|>{"name":"git_diff","arguments":{"max_lines":400}}<|end|>"##
        let thinking = Array(repeating: one, count: 4).joined(separator: "\n")
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking), ["git_diff"]
        )
    }

    // MARK: - reasoningChannelToolCallNames: the function-tag form

    // Verbatim from `MeditationApp` task 111 run 2 (2026-09-13): `qwythos-9b-claude-mythos-5-1m-mlx`
    // on LM Studio under `toolCalling: native`. 3 of 10 responses wrote the model's own template
    // form inside `[reasoning]` and stopped — `finish_reason: stop`, no `tool_calls`, empty
    // content, because the server parses that form outside reasoning only. The detector read
    // `<|call|>` alone, so each of the three reached the producing-role "Missing deliverables"
    // nudge instead of the one naming the channel. Still diagnosis only: nothing here dispatches.

    /// Response 20:26:48 — one sentence, one call, nothing after it.
    func testReasoningNames_functionTagCall_namesIt() {
        let thinking = ##"""
        Let me look at the MeditationApp directory structure to understand what files exist.
        
        <tool_call>
        <function=list_files>
        <parameter=path>
        MeditationApp
        </parameter>
        </function>
        </tool_call>
        
        """##
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking), ["list_files"])
    }

    /// Response 20:27:09 — a markdown list with backticks and `()` ahead of the call.
    func testReasoningNames_functionTagCallAfterMarkdownProse_namesIt() {
        let thinking = ##"""
        Now I have a clear picture of the current state:
        
        1. **Widget Bundle**: `WidgetBundle.swift` exists and has `StreaksWidget()` and `QuickStartWidget()` registered
        2. **StreaksWidget**: This exists as a separate file `StreaksWidget.swift`
        3. **QuickStartWidget**: This exists as a separate file `QuickStartWidget.swift`
        
        Let me now read the actual widget files to understand their structure and what data they currently use.
        
        <tool_call>
        <function=read_file>
        <parameter=path>
        MeditationApp/StreaksWidget.swift
        </parameter>
        </function>
        </tool_call>
        
        """##
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking), ["read_file"])
    }

    /// The same rule as `testReasoningNames_truncatedEnvelope_returnsEmpty`: an unfinished
    /// call is not a callable one written in the wrong channel.
    func testReasoningNames_functionTagWithoutItsCloser_returnsEmpty() {
        let thinking = ##"""
        Let me read it.
        
        <tool_call>
        <function=read_file>
        <parameter=path>
        MeditationApp/SessionHistoryStore.swift
        """##
        XCTAssertEqual(ConversationRepairService.reasoningChannelToolCallNames(in: thinking), [])
    }

    /// The function tag alone is how prose DESCRIBES the form; the call is the wrapped tag.
    func testReasoningNames_functionTagWithoutTheToolCallWrapper_returnsEmpty() {
        let thinking = "The form is <function=read_file><parameter=path>a.swift</parameter></function> — noted."
        XCTAssertEqual(ConversationRepairService.reasoningChannelToolCallNames(in: thinking), [])
    }

    /// An exact literal, never case-folded — the rule `HarmonySentinelNormalizer` states for
    /// its own `<tool_call>`.
    func testReasoningNames_functionTagUnderAnUppercaseWrapper_returnsEmpty() {
        let thinking = "<TOOL_CALL>\n<function=read_file>\n</function>\n</TOOL_CALL>"
        XCTAssertEqual(ConversationRepairService.reasoningChannelToolCallNames(in: thinking), [])
    }

    func testReasoningNames_proseBetweenWrapperAndFunctionTag_returnsEmpty() {
        let thinking = "<tool_call> is the wrapper, and then <function=read_file></function>"
        XCTAssertEqual(ConversationRepairService.reasoningChannelToolCallNames(in: thinking), [])
    }

    func testReasoningNames_functionTagGap_fourWhitespaceIsAdjacent_fiveIsNot() {
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(
                in: "<tool_call>\n\n\t <function=read_file></function></tool_call>"),
            ["read_file"])
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(
                in: "<tool_call>\n\n\t  <function=read_file></function></tool_call>"),
            [])
    }

    func testReasoningNames_functionTagWithEmptyOrInvalidName_returnsEmpty() {
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(
                in: "<tool_call><function=></function></tool_call>"),
            [])
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(
                in: "<tool_call><function=read file></function></tool_call>"),
            [])
    }

    func testReasoningNames_severalFunctionTagCalls_inWrittenOrderWithoutRepeats() {
        let thinking = """
        <tool_call>
        <function=read_file>
        <parameter=path>
        a.swift
        </parameter>
        </function>
        </tool_call>
        <tool_call>
        <function=list_files>
        </function>
        </tool_call>
        <tool_call>
        <function=read_file>
        </function>
        </tool_call>
        """
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking),
            ["read_file", "list_files"])
    }

    /// A closer belongs to the call it follows: an abandoned call must not borrow the
    /// `</function>` of the next one.
    func testReasoningNames_abandonedFunctionTagThenCompleteOne_namesOnlyTheComplete() {
        let thinking = """
        <tool_call>
        <function=write_file>
        <parameter=path>
        x.swift
        <tool_call>
        <function=read_file>
        </function>
        </tool_call>
        """
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking), ["read_file"])
    }

    /// Both forms in one block: the Harmony names first, then the function-tag names, one
    /// list without repeats.
    func testReasoningNames_bothForms_harmonyFirstThenFunctionTag() {
        let thinking = ##"""
        <tool_call>
        <function=read_file>
        </function>
        </tool_call>
        <|call|>{"name":"list_files","arguments":{"path":"."}}<|end|>
        <tool_call>
        <function=list_files>
        </function>
        </tool_call>
        """##
        XCTAssertEqual(
            ConversationRepairService.reasoningChannelToolCallNames(in: thinking),
            ["list_files", "read_file"])
    }
}
