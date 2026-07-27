import XCTest

@testable import NanoTeams

/// The two accessors below exist only here and in the sibling builder suites: `NativeChatInput`
/// and `MultimodalInputPart` are bare `Encodable` enums with no production reader.
private extension NativeLMStudioClient.NativeChatInput {
    /// The conversation text, whichever shape `input` took. The multimodal form keeps the whole
    /// conversation in one leading `.text` part and appends the images after it.
    var conversationText: String? {
        switch self {
        case .text(let s): return s
        case .multimodal(let parts):
            for part in parts { if case .text(let s) = part { return s } }
            return nil
        }
    }

    var imageCount: Int {
        guard case .multimodal(let parts) = self else { return 0 }
        return parts.reduce(0) { count, part in
            if case .image = part { return count + 1 }
            return count
        }
    }
}

/// Append-at-`count` is the only prefix-preserving mutation of a conversation, and the whole
/// stateless design rests on it. These pin that the property survives BOTH wire renderings —
/// which is not obvious, because Ollama merges consecutive user-side turns, so an append at the
/// array level is a *rewrite* of the last wire message.
///
/// The negatives matter as much as the positives: `testInsertBeforeTail_*` is the executable
/// reason the planning phase must never insert a turn ahead of the brief, and the reason
/// `ConversationAppendInvariantTests` guards every mutation site.
final class PromptPrefixWireParityTests: XCTestCase {

    // MARK: - Fixtures

    private var tools: [ToolSchema] {
        [ToolSchema(name: "read_file", description: "Read a file",
                    parameters: JSONSchema(type: "object"))]
    }

    private var ollamaConfig: LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
    }

    private var lmStudioConfig: LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
    }

    private func system(_ t: String) -> ChatMessage { ChatMessage(role: .system, content: t) }
    private func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, content: t) }
    private func assistant(_ t: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: t)
    }
    private func tool(_ t: String) -> ChatMessage { ChatMessage(role: .tool, content: t) }

    /// One string per message the Ollama wire actually carries, images included.
    private func ollamaWire(_ messages: [ChatMessage]) -> [String] {
        OllamaClient.buildRequest(config: ollamaConfig, messages: messages, tools: tools)
            .messages
            .map { "\($0.role)\u{1}\($0.content)\u{1}\(($0.images ?? []).joined(separator: ","))" }
    }

    private func lmStudioInput(_ messages: [ChatMessage])
        -> NativeLMStudioClient.NativeChatInput
    {
        NativeLMStudioClient.buildRequest(
            config: lmStudioConfig, messages: messages, tools: tools
        ).input
    }

    private func firstDivergence(_ a: [String], _ b: [String]) -> Int? {
        for i in 0..<min(a.count, b.count) where a[i] != b[i] { return i }
        return nil
    }

    /// A conversation whose brief-like turn is NOT at the tail — an assistant turn follows it.
    /// This is the shape the planning phase actually reaches after one exploration turn, and the
    /// only shape in which "insert before the brief" is distinguishable from "append".
    private var midPhaseWire: [ChatMessage] {
        [system("s"), user("the task"), user("## Planning phase\nexplore"),
         assistant("reading"), tool("{\"ok\":true}")]
    }

    // MARK: - Append at count preserves the prefix on both wires

    func testAppendAtCount_keepsTheLMStudioInputStringAByteExactPrefix() {
        let before = [system("s"), user("a"), assistant("b")]
        let after = before + [user("c")]

        guard let b = lmStudioInput(before).conversationText,
              let a = lmStudioInput(after).conversationText
        else { return XCTFail("expected a text input") }

        XCTAssertTrue(a.hasPrefix(b), "an append must leave the sent bytes untouched")
        XCTAssertGreaterThan(a.count, b.count)
    }

    /// The append-after-an-assistant-turn case: the run boundary is closed, so the new turn
    /// becomes its own wire message and nothing earlier moves at all.
    func testAppendAfterAnAssistantTurn_addsAWholeOllamaMessageAndTouchesNothing() {
        let before = [system("s"), user("a"), assistant("b")]
        let after = before + [user("c")]

        let b = ollamaWire(before)
        let a = ollamaWire(after)

        XCTAssertNil(firstDivergence(b, a), "every previously sent message must be identical")
        XCTAssertEqual(a.count, b.count + 1)
    }

    /// The subtle case, and the one the whole safety argument rests on: appending a user-side
    /// turn after another user-side turn is an array append but a wire REWRITE — Ollama merges
    /// the run. It stays safe only because the merged message is the LAST one.
    func testAppendAfterAUserTurn_rewritesOnlyTheLastOllamaMessage() {
        let before = [system("s"), user("a"), assistant("b"), tool("{}")]
        let after = before + [user("nudge")]

        let b = ollamaWire(before)
        let a = ollamaWire(after)

        XCTAssertEqual(a.count, b.count, "the tool result and the nudge merge into one message")
        let divergence = firstDivergence(b, a)
        XCTAssertEqual(
            divergence, b.count - 1,
            "the merge may only ever touch the tail; anything earlier is a real prefix break")
        XCTAssertTrue(
            a[b.count - 1].hasPrefix(b[b.count - 1].dropLast()),
            "the old merged content must survive as a prefix of the new one")
    }

    // MARK: - Insert before the tail breaks both wires (the negative)

    func testInsertBeforeTail_breaksTheOllamaPrefixAtANonTailMessage() {
        var after = midPhaseWire
        after.insert(user("Supervisor:\nalso check the parser"), at: 2)

        let b = ollamaWire(midPhaseWire)
        let a = ollamaWire(after)

        guard let divergence = firstDivergence(b, a) else {
            return XCTFail("an insert before the tail must diverge somewhere")
        }
        XCTAssertLessThan(
            divergence, b.count - 1,
            "this is the hazard: the break is NOT tail-local, so the server re-prefills from here")
    }

    func testInsertBeforeTail_breaksTheLMStudioInputString() {
        var after = midPhaseWire
        after.insert(user("Supervisor:\nalso check the parser"), at: 2)

        guard let b = lmStudioInput(midPhaseWire).conversationText,
              let a = lmStudioInput(after).conversationText
        else { return XCTFail("expected a text input") }

        XCTAssertFalse(
            a.hasPrefix(b),
            "LM Studio joins the whole conversation into one string — an insert diverges it")
    }

    // MARK: - Fingerprint granularity vs the Ollama wire

    /// Documented coarseness, in the benign direction. `PromptPrefixFingerprint.chain` hashes per
    /// `ChatMessage`, one level finer-grained than Ollama's merged wire message, so a tail-only
    /// merge reads as a pure append and `appendedTokens` under-counts what the server re-prefills.
    /// Under-counting only ever NARROWS the rate-comparison branch, so it cannot manufacture a
    /// false positive.
    func testFingerprint_seesATailOnlyMergeAsAPureAppend_whichIsTheBenignDirection() {
        let before = [system("s"), user("a"), assistant("b"), tool("{}")]
        let after = before + [user("nudge")]

        let verdict = PrefixCachePolicy.compare(
            previous: PromptPrefixFingerprint.chain(messages: before, toolSchemaText: ""),
            current: PromptPrefixFingerprint.chain(messages: after, toolSchemaText: ""),
            discardedTokens: 0)
        XCTAssertEqual(verdict, .reused(segments: 4), "the fingerprint sees a pure append")

        XCTAssertNotNil(
            firstDivergence(ollamaWire(before), ollamaWire(after)),
            "…while the wire's last message really did change")
    }

    /// The half that must NOT be missed: a divergence that is not tail-local is reported.
    func testFingerprint_neverMissesANonTailWireDivergence() {
        var after = midPhaseWire
        after.insert(user("Supervisor:\nalso check the parser"), at: 2)

        let verdict = PrefixCachePolicy.compare(
            previous: PromptPrefixFingerprint.chain(messages: midPhaseWire, toolSchemaText: ""),
            current: PromptPrefixFingerprint.chain(messages: after, toolSchemaText: ""),
            discardedTokens: 5000)
        XCTAssertEqual(verdict.diagnosis?.cause, .conversationRewritten(atSegment: 2))
    }

    // MARK: - Single-use image strip: the provider asymmetry

    /// LM Studio appends images as trailing multimodal parts, so dropping them leaves the
    /// conversation TEXT byte-identical — the strip is nearly free.
    func testImageStrip_LMStudio_leavesTheTextPrefixIntact() {
        let withImage = [
            system("s"), user("a"),
            ChatMessage(
                role: .user, content: "look at this",
                imageContent: [ImageContent(base64Data: "AAAA", mimeType: "image/png")]),
        ]
        var stripped = withImage
        stripped[2].imageContent = nil

        let before = lmStudioInput(withImage)
        let after = lmStudioInput(stripped)

        XCTAssertEqual(before.imageCount, 1)
        XCTAssertEqual(after.imageCount, 0)
        XCTAssertEqual(
            before.conversationText, after.conversationText,
            "the text half of the LM Studio input is untouched by the strip")
    }

    /// Ollama puts the base64 in the `images` field of the merged user message AT ITS POSITION,
    /// so the same strip is a genuine mid-array break. The exemption is provider-blind — this
    /// records that it is nonetheless needed for two different reasons.
    func testImageStrip_Ollama_changesTheMessageAtItsPosition() {
        let withImage = [
            system("s"),
            ChatMessage(
                role: .user, content: "look at this",
                imageContent: [ImageContent(base64Data: "AAAA", mimeType: "image/png")]),
            assistant("I see a button"),
            user("click it"),
        ]
        var stripped = withImage
        stripped[1].imageContent = nil

        let b = ollamaWire(withImage)
        let a = ollamaWire(stripped)

        guard let divergence = firstDivergence(b, a) else {
            return XCTFail("dropping the image must change the Ollama wire")
        }
        XCTAssertLessThan(
            divergence, b.count - 1,
            "the image rides a message in the middle of the conversation, not the tail")
    }

    // MARK: - Corners

    func testEmptyConversation_and_systemOnlyConversation_produceAStableSegmentZero() {
        let empty = PromptPrefixFingerprint.chain(messages: [], toolSchemaText: "")
        XCTAssertEqual(empty.count, 1, "segment 0 exists even with no system message")

        let systemOnly = PromptPrefixFingerprint.chain(
            messages: [system("s")], toolSchemaText: "")
        XCTAssertEqual(systemOnly.count, 1)
        XCTAssertNotEqual(empty, systemOnly)

        XCTAssertEqual(
            PromptPrefixFingerprint.chain(messages: [system("s")], toolSchemaText: ""),
            systemOnly,
            "the same input must fold identically across calls (FNV, not a seeded Hasher)")
    }

    func testNonASCIIContent_foldsByBytesAndStaysStable() {
        let cjk = user("проверка 检查 🧑‍🚀 café")
        let combining = user("cafe\u{0301}")  // same grapheme, different bytes

        let a = PromptPrefixFingerprint.chain(messages: [cjk], toolSchemaText: "")
        let b = PromptPrefixFingerprint.chain(messages: [cjk], toolSchemaText: "")
        XCTAssertEqual(a, b, "non-ASCII must fold deterministically")

        XCTAssertNotEqual(
            PromptPrefixFingerprint.chain(messages: [user("café")], toolSchemaText: ""),
            PromptPrefixFingerprint.chain(messages: [combining], toolSchemaText: ""),
            "different bytes are a different prefix, even at the same grapheme")
    }

    func testImages_foldByShapeOnly_atBothSizeExtremes() {
        func message(_ base64: String) -> ChatMessage {
            ChatMessage(
                role: .user, content: "x",
                imageContent: [ImageContent(base64Data: base64, mimeType: "image/png")])
        }
        let empty = PromptPrefixFingerprint.chain(messages: [message("")], toolSchemaText: "")
        let huge = PromptPrefixFingerprint.chain(
            messages: [message(String(repeating: "A", count: 10_000_000))], toolSchemaText: "")
        XCTAssertNotEqual(empty, huge, "byte length is part of the shape")

        let sameShapeDifferentPayload = PromptPrefixFingerprint.chain(
            messages: [message(String(repeating: "B", count: 4))], toolSchemaText: "")
        XCTAssertEqual(
            PromptPrefixFingerprint.chain(messages: [message("AAAA")], toolSchemaText: ""),
            sameShapeDifferentPayload,
            "equal mime + equal length fold the same — the payload itself is never hashed")
    }
}
