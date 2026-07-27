import XCTest

@testable import NanoTeams

/// `repairConversationIfNeeded` truncates the poisoned tail, which is a prefix reset — but a
/// NECESSARY one: the alternative is an unrecoverable HTTP 500 loop. That makes it an exemption
/// rather than a defect, and an exemption has to be armed only when the reset actually happened.
/// The flag is a consumed one-shot, so arming it on a no-op repair would swallow the next genuine
/// cache miss instead.
///
/// Splits into three halves: the pure return contract, the prefix cost the exemption exists to
/// cover, and a source pin on the wiring (the retry arm is inside a `while` loop around a live
/// stream, so the arming itself has no behavioural seam).
final class ConversationRepairPrefixCostTests: XCTestCase {

    // MARK: - Fixtures

    private func system(_ t: String) -> ChatMessage { ChatMessage(role: .system, content: t) }
    private func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, content: t) }
    private func assistant(calls: [ChatToolCall]) -> ChatMessage {
        ChatMessage(role: .assistant, content: nil, toolCalls: calls)
    }
    private func toolResult(_ t: String, id: String = "tc-1") -> ChatMessage {
        ChatMessage(role: .tool, content: t, toolCallID: id)
    }
    private func call(_ name: String, _ args: String = "{}") -> ChatToolCall {
        ChatToolCall(id: "tc-1", name: name, argumentsJSON: args)
    }

    /// The exact shape the repair looks for: assistant(toolCalls) → tool(error) → user(guidance).
    private var poisoned: [ChatMessage] {
        [
            system("s"), user("do the work"),
            assistant(calls: [call("write_file", #"{"path":"a.swift"}"#)]),
            toolResult(#"{"ok":false}"#),
            user("that failed, try again"),
        ]
    }

    // MARK: - The return contract

    func testRepair_returnsTrue_whenItActuallyRepairs() {
        var messages = poisoned
        XCTAssertTrue(ConversationRepairService.repairConversationIfNeeded(&messages))
        XCTAssertEqual(messages.count, 3, "assistant + tool + user collapse into one user turn")
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertTrue(messages.last?.content?.contains("write_file") ?? false)
    }

    /// Every early guard, individually. A `false` here is what keeps the exemption from being
    /// armed for a repair that never happened.
    func testRepair_returnsFalse_forEveryEarlyGuard() {
        var tooShort: [ChatMessage] = [system("s"), user("a")]
        XCTAssertFalse(
            ConversationRepairService.repairConversationIfNeeded(&tooShort), "fewer than 3")

        var empty: [ChatMessage] = []
        XCTAssertFalse(ConversationRepairService.repairConversationIfNeeded(&empty), "empty")

        var tailIsNotUser = Array(poisoned.dropLast()) + [assistant(calls: [call("x")])]
        XCTAssertFalse(
            ConversationRepairService.repairConversationIfNeeded(&tailIsNotUser),
            "the tail must be the guidance turn")

        var noToolResults: [ChatMessage] = [
            system("s"), assistant(calls: [call("x")]), user("guidance"),
        ]
        XCTAssertFalse(
            ConversationRepairService.repairConversationIfNeeded(&noToolResults),
            "no tool result between them ⇒ not the poisoned shape")

        var assistantWithoutCalls: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "prose"), toolResult("{}"), user("guidance"),
        ]
        XCTAssertFalse(
            ConversationRepairService.repairConversationIfNeeded(&assistantWithoutCalls),
            "an assistant turn with no tool calls is not the poisoned shape")
    }

    func testRepair_atExactlyThreeMessages_isTheBoundary() {
        var exactlyThree: [ChatMessage] = [
            assistant(calls: [call("read_file")]), toolResult("{}"), user("guidance"),
        ]
        XCTAssertTrue(
            ConversationRepairService.repairConversationIfNeeded(&exactlyThree),
            "`count >= 3` — three is inside the guard, not outside it")
        XCTAssertEqual(exactlyThree.count, 1)
    }

    func testRepair_leavesNothingBehind_whenEveryMessageIsPoisoned() {
        var messages: [ChatMessage] = [
            assistant(calls: [call("a"), call("b")]),
            toolResult("{}", id: "tc-1"), toolResult("{}", id: "tc-2"),
            toolResult("{}", id: "tc-3"), toolResult("{}", id: "tc-4"),
            toolResult("{}", id: "tc-5"),
            user("guidance"),
        ]
        XCTAssertTrue(ConversationRepairService.repairConversationIfNeeded(&messages))
        XCTAssertEqual(messages.count, 1, "1 assistant + 5 tools + 1 user removed, 1 appended")
    }

    /// The failed-call description slices `argumentsJSON` at 200 UTF-8-agnostic characters.
    /// `String.prefix` is grapheme-based, so a multi-byte body cannot be split mid-character.
    func testRepair_nonASCIIArguments_truncateWithoutSplittingAGrapheme() {
        let body = String(repeating: "проверка 检查 🧑‍🚀 ", count: 40)
        var messages: [ChatMessage] = [
            assistant(calls: [call("write_file", body)]), toolResult("{}"), user("guidance"),
        ]
        XCTAssertTrue(ConversationRepairService.repairConversationIfNeeded(&messages))

        let described = messages.last?.content ?? ""
        XCTAssertTrue(described.contains("write_file"))
        XCTAssertFalse(
            described.unicodeScalars.contains { $0.value == 0xFFFD },
            "no replacement character — the truncation must respect grapheme boundaries")
    }

    // MARK: - The prefix cost the exemption covers

    /// Makes the exemption's necessity explicit rather than assumed: the repair diverges the
    /// chain at a real index, so without the flag this WOULD be reported as a defect.
    func testRepairedTail_reallyDoesDivergeTheChain() {
        var repaired = poisoned
        XCTAssertTrue(ConversationRepairService.repairConversationIfNeeded(&repaired))

        let verdict = PrefixCachePolicy.compare(
            previous: PromptPrefixFingerprint.chain(messages: poisoned, toolSchemaText: ""),
            current: PromptPrefixFingerprint.chain(messages: repaired, toolSchemaText: ""),
            discardedTokens: 9_999)
        XCTAssertEqual(
            verdict.diagnosis?.cause, .conversationRewritten(atSegment: 2),
            "the truncation replaces the assistant turn — an exemption, not a non-event")
    }

    /// …and that the damage is TAIL-LOCAL, unlike the collapse helper this file's sibling
    /// deleted. The surviving head is what keeps the retry cheap.
    func testRepairedTail_damageIsBoundedToTheTail() {
        let head = [system("s"), user("do the work")]
        var repaired = poisoned
        _ = ConversationRepairService.repairConversationIfNeeded(&repaired)

        XCTAssertEqual(
            Array(repaired.prefix(head.count)), head,
            "everything before the poisoned tail must survive byte-identical")
    }

    // MARK: - The wiring (source pin)

    /// The retry arm lives inside a `while` loop around a live LLM stream, so there is no
    /// behavioural seam that reaches it without a server. The pin holds the two halves together:
    /// the repair must be called for its RESULT, and the flag must be armed in the same breath.
    func testTheRetrySiteArmsThePrefixResetFlagFromTheRepairsResult() throws {
        let repairNeedle = "repairConversation" + "IfNeeded(&conversation)"
        let flagNeedle = "expectedPrefixReset" + "Pending = true"

        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(
                "NanoTeams/Services/LLM/LLMExecutionService+StepLifecycle.swift")
        let lines = try String(contentsOf: path, encoding: .utf8).components(separatedBy: "\n")

        guard let repairLine = lines.firstIndex(where: { $0.contains(repairNeedle) }) else {
            return XCTFail("the retry-path repair call is gone — this pin is now vacuous")
        }
        XCTAssertTrue(
            lines[repairLine].contains("if "),
            "the repair must be called for its Bool result, not discarded")

        let window = lines[repairLine...min(repairLine + 3, lines.count - 1)]
        XCTAssertTrue(
            window.contains { $0.contains(flagNeedle) },
            "a repair that is not followed by arming the reset flag reports its own deliberate "
                + "truncation as a cache defect on the very next request")
    }
}
