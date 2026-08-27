import XCTest
@testable import NanoTeams

/// Pins the fingerprint's core contract: the index of the first differing hash IS the number of
/// wire segments the server can still reuse.
final class PromptPrefixFingerprintTests: XCTestCase {

    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    private func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: text) }
    private func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }

    // MARK: - Shape

    func testChain_alwaysHasASystemSegment_evenWithNoSystemMessage() {
        XCTAssertEqual(PromptPrefixFingerprint.chain(messages: []).count, 1)
        XCTAssertEqual(PromptPrefixFingerprint.chain(messages: [user("hi")]).count, 2)
    }

    func testChain_oneSegmentPerNonSystemMessage() {
        let messages = [system("s"), user("a"), assistant("b"), user("c")]
        XCTAssertEqual(PromptPrefixFingerprint.chain(messages: messages).count, 4)
    }

    func testChain_multipleSystemMessages_collapseIntoTheSingleLeadingSegment() {
        let split = PromptPrefixFingerprint.chain(messages: [system("a"), system("b"), user("x")])
        let joined = PromptPrefixFingerprint.chain(messages: [system("a\n\nb"), user("x")])
        XCTAssertEqual(split, joined, "both builders join every system message with a blank line")
    }

    func testChain_isDeterministicAcrossCalls() {
        let messages = [system("s"), user("a")]
        XCTAssertEqual(
            PromptPrefixFingerprint.chain(messages: messages),
            PromptPrefixFingerprint.chain(messages: messages),
            "explicit FNV-1a, not per-process-seeded Hasher")
    }

    // MARK: - Append-only is the whole point

    func testAppending_extendsTheChainAndPreservesEveryEarlierHash() {
        let before = PromptPrefixFingerprint.chain(messages: [system("s"), user("a")])
        let after = PromptPrefixFingerprint.chain(messages: [system("s"), user("a"), assistant("b")])

        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(Array(after.prefix(before.count)), before)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength(before, after), before.count)
    }

    // MARK: - Divergence localisation

    func testMidArrayRewrite_truncatesTheCommonPrefixAtThatIndex() {
        let before = PromptPrefixFingerprint.chain(
            messages: [system("s"), user("a"), assistant("b"), user("c")])
        let after = PromptPrefixFingerprint.chain(
            messages: [system("s"), user("a"), assistant("CHANGED"), user("c")])

        // segment 0 = system, 1 = "a", 2 = the rewritten one.
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength(before, after), 2)
    }

    func testSystemPromptChange_losesEverything() {
        let before = PromptPrefixFingerprint.chain(messages: [system("s"), user("a")])
        let after = PromptPrefixFingerprint.chain(messages: [system("DIFFERENT"), user("a")])
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength(before, after), 0)
    }

    func testToolSchemaChange_alsoLosesEverything() {
        let messages = [system("s"), user("a")]
        let before = PromptPrefixFingerprint.chain(messages: messages, toolSchemaText: "read_file")
        let after = PromptPrefixFingerprint.chain(messages: messages, toolSchemaText: "read_file git_status")
        XCTAssertEqual(
            PromptPrefixFingerprint.commonPrefixLength(before, after), 0,
            "the catalog is rendered INTO the system prompt, so a tool appearing mid-run is a full miss")
    }

    func testTruncationWithIntactHead_reportsTheSurvivingHead() {
        let long = PromptPrefixFingerprint.chain(
            messages: [system("s"), user("a"), assistant("b"), user("c")])
        let sliced = PromptPrefixFingerprint.chain(messages: [system("s"), user("a")])
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength(long, sliced), 2)
    }

    // MARK: - Wire-invisible fields must NOT move the fingerprint

    func testFreshlyMintedToolCallIDs_doNotCountAsDivergence() {
        let a = ChatMessage(role: .tool, content: "result", toolCallID: UUID().uuidString)
        let b = ChatMessage(role: .tool, content: "result", toolCallID: UUID().uuidString)
        XCTAssertEqual(
            PromptPrefixFingerprint.chain(messages: [a]),
            PromptPrefixFingerprint.chain(messages: [b]),
            "tool_call_id reaches neither provider's wire; hashing it would be a false positive")
    }

    func testChatToolCallID_doesNotCountButNameAndArgumentsDo() {
        let base = { (id: String, args: String) in
            ChatMessage(
                role: .assistant,
                toolCalls: [ChatToolCall(id: id, name: "read_file", argumentsJSON: args)])
        }
        XCTAssertEqual(
            PromptPrefixFingerprint.chain(messages: [base("id-1", "{}")]),
            PromptPrefixFingerprint.chain(messages: [base("id-2", "{}")]))
        XCTAssertNotEqual(
            PromptPrefixFingerprint.chain(messages: [base("id-1", "{}")]),
            PromptPrefixFingerprint.chain(messages: [base("id-1", "{\"path\":\"a\"}")]),
            "Ollama re-materializes name+arguments as wire text")
    }

    func testIsToolError_isNotSerialisedAndSoIsNotFingerprinted() {
        XCTAssertEqual(
            PromptPrefixFingerprint.chain(messages: [ChatMessage(role: .tool, content: "x", isToolError: true)]),
            PromptPrefixFingerprint.chain(messages: [ChatMessage(role: .tool, content: "x", isToolError: false)]))
    }

    // MARK: - Roles and separators

    func testSameContentDifferentRole_diverges() {
        XCTAssertNotEqual(
            PromptPrefixFingerprint.chain(messages: [user("x")]),
            PromptPrefixFingerprint.chain(messages: [assistant("x")]))
    }

    func testConcatenationAmbiguity_isAvoided() {
        XCTAssertNotEqual(
            PromptPrefixFingerprint.chain(messages: [user("ab")]),
            PromptPrefixFingerprint.chain(messages: [user("a"), user("b")]))
    }

    // MARK: - Images fold by shape

    func testImagePayloadOfDifferentSize_diverges() {
        let small = ChatMessage(
            role: .user, content: "look",
            imageContent: [ImageContent(base64Data: "AAAA", mimeType: "image/png")])
        let large = ChatMessage(
            role: .user, content: "look",
            imageContent: [ImageContent(base64Data: "AAAAAAAA", mimeType: "image/png")])
        XCTAssertNotEqual(
            PromptPrefixFingerprint.chain(messages: [small]),
            PromptPrefixFingerprint.chain(messages: [large]))
    }

    func testStrippingAnImage_diverges() {
        let withImage = ChatMessage(
            role: .user, content: "look",
            imageContent: [ImageContent(base64Data: "AAAA", mimeType: "image/png")])
        let stripped = ChatMessage(role: .user, content: "look")
        XCTAssertNotEqual(
            PromptPrefixFingerprint.chain(messages: [withImage]),
            PromptPrefixFingerprint.chain(messages: [stripped]),
            "the single-use image strip is a real prefix change; it is exempted by the caller, not hidden here")
    }

    // MARK: - chainAndTokens parity (the fused walk)

    /// `chainAndTokens` replaced THREE whole-conversation walks per request (the
    /// ledger's pricing, the chain, and the budget warning's second pricing) with
    /// one. Its contract is exact parity on both halves — the chain
    /// element-for-element, the price to the token — including the per-string
    /// rounding granularity and the image asymmetry (base64 priced in full,
    /// hashed by shape).
    ///
    /// RED: flip the lead-byte class test in `foldCounting` (`byte < 0x80` →
    /// `byte <= 0x80`) and the Cyrillic fixture diverges; drop the role fold and
    /// every chain fixture diverges.
    private func assertParity(_ messages: [ChatMessage], toolSchemaText: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        let fused = PromptPrefixFingerprint.chainAndTokens(
            messages: messages, toolSchemaText: toolSchemaText)
        XCTAssertEqual(fused.chain,
                       PromptPrefixFingerprint.chain(messages: messages,
                                                     toolSchemaText: toolSchemaText),
                       "chain diverged", file: file, line: line)
        XCTAssertEqual(fused.totalPromptTokens,
                       ContextBudgetPolicy.estimateTokens(messages: messages,
                                                          toolSchemaText: toolSchemaText),
                       "price diverged", file: file, line: line)
    }

    func testFused_parityOnPlainASCIIConversation() {
        assertParity([system("You are helpful."), user("hello"), assistant("hi there")])
    }

    /// The estimator is two-class (#82: ~0.78x ASCII, ~0.45x Cyrillic rates) —
    /// the fused byte-level classifier must reproduce the scalar classes exactly.
    func testFused_parityOnCyrillicAndMixedText() {
        assertParity([system("Ты — ассистент."),
                      user("Привет, мир! ascii tail"),
                      assistant("Ответ: 42 🚀 (emoji is one scalar pair)")])
        assertParity([user(String(repeating: "щ", count: 999))])
    }

    func testFused_parityWithToolSchemaText() {
        assertParity([user("q")], toolSchemaText: "## Tools\n{\"name\":\"read_file\"}")
    }

    func testFused_parityOnToolCallTurns() {
        let call = ChatMessage(
            role: .assistant, content: "",
            toolCalls: [ChatToolCall(id: "c1", name: "read_file",
                                     argumentsJSON: "{\"path\":\"a\"}")])
        let result = ChatMessage(role: .tool, content: "file body", toolCallID: "x")
        assertParity([system("s"), user("u"), call, result])
    }

    /// Base64 is PRICED in full but HASHED by shape — the one part of the walk
    /// where the two halves deliberately read different bytes.
    func testFused_parityOnImageTurn() {
        let image = ChatMessage(
            role: .user, content: "look",
            imageContent: [ImageContent(base64Data: String(repeating: "QUJD", count: 500),
                                        mimeType: "image/png")])
        assertParity([system("s"), image, assistant("seen")])
    }

    /// The premise the image fold rests on since 2026-08-25: the payload length is
    /// read with `.utf8.count` (O(1) on a native String) instead of `.count`
    /// (O(graphemes) — a walk of a multi-megabyte payload, once per image per wire
    /// request, in the branch whose whole purpose is NOT to touch the payload).
    ///
    /// The substitution is only sound because base64 is ASCII-only, so the two
    /// spellings agree. That is an assumption about the DATA, not about Swift, so it
    /// is asserted rather than believed — over the full base64 alphabet including
    /// padding, and over a payload long enough that a grapheme-breaking difference
    /// would show.
    ///
    /// RED: change either fold site back to `.count` → these stay green (the values
    /// agree, which is the point); change one site and not the other → `assertParity`
    /// above diverges, which is the guard that matters.
    func testImagePayloadLength_utf8CountAgreesWithCountOverTheBase64Alphabet() {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        XCTAssertEqual(alphabet.count, alphabet.utf8.count,
                       "base64 alphabet must be ASCII for .utf8.count to be a drop-in")
        let payload = String(repeating: alphabet, count: 400)
        XCTAssertEqual(payload.count, payload.utf8.count)

        // And the fold really is by SHAPE: two different payloads of equal length
        // produce the same chain, while a different length does not.
        func chain(_ b64: String) -> [UInt64] {
            PromptPrefixFingerprint.chain(messages: [
                ChatMessage(role: .user, content: "look",
                            imageContent: [ImageContent(base64Data: b64, mimeType: "image/png")])
            ])
        }
        XCTAssertEqual(chain(String(repeating: "QUJD", count: 8)),
                       chain(String(repeating: "WXYZ", count: 8)),
                       "equal-length payloads must fold identically — the documented trade")
        XCTAssertNotEqual(chain(String(repeating: "QUJD", count: 8)),
                          chain(String(repeating: "QUJD", count: 9)),
                          "a length change must move the chain, or the shape fold says nothing")
    }

    /// An image payload must not be WALKED to price it, on either surface.
    ///
    /// Both `chainAndTokens` (once per wire request, `PromptPrefixLedger:151`) and
    /// `ContextBudgetPolicy.estimateTokens` (once per request via `PrefixCachePolicy`)
    /// priced images with `WorkFolderContextPromptPlanner.estimateTokens(base64Data)`,
    /// a full scalar walk — so a screenshot in the conversation was traversed at least
    /// twice per request, forever, i.e. Θ(requests × payload) across a run.
    ///
    /// Base64's alphabet is ASCII-only by construction, so the two-class estimate needs
    /// no walk at all: `ascii == utf8.count`, `nonAscii == 0`. The premise is asserted
    /// below rather than believed.
    ///
    /// Measured through the planner's own work seam (`_testScalarWork`), the idiom
    /// `Ratchet/WallClockPerformancePinTests` requires — work done, never wall-clock.
    ///
    /// RED: restore either `estimateTokens(image.base64Data)` call → the walked-scalar
    /// count jumps by the payload length and both bounds fail.
    func testImagePayloadIsPricedWithoutWalkingIt() {
        typealias Planner = WorkFolderContextPromptPlanner
        let payload = String(repeating: "QUJD", count: 25_000)   // 100k ASCII chars
        let prose = "look at this"
        let messages = [
            ChatMessage(role: .user, content: prose,
                        imageContent: [ImageContent(base64Data: payload, mimeType: "image/png")])
        ]

        // The premise the O(1) pricing rests on.
        XCTAssertEqual(payload.count, payload.utf8.count,
                       "base64 must be ASCII-only for the walk-free estimate to be exact")

        Planner._testResetScalarWork()
        let fused = PromptPrefixFingerprint.chainAndTokens(messages: messages)
        let fusedWalk = Planner._testScalarWork()

        Planner._testResetScalarWork()
        let budget = ContextBudgetPolicy.estimateTokens(messages: messages)
        let budgetWalk = Planner._testScalarWork()

        // Parity is unchanged — this is a cost fix, not a pricing change.
        XCTAssertEqual(fused.totalPromptTokens, budget,
                       "the two surfaces must still agree to the token")

        // Neither may walk the payload. The generous ceiling is the prose plus slack:
        // what must NOT appear in the count is the 100k-character payload.
        for (name, walked) in [("chainAndTokens", fusedWalk), ("ContextBudgetPolicy", budgetWalk)] {
            XCTAssertLessThan(
                walked, 1_000,
                "\(name) walked \(walked) scalars for a message whose prose is "
                    + "\(prose.count) characters — it is traversing the "
                    + "\(payload.count)-character image payload to price it")
        }
    }

    func testFused_parityOnMultipleSystemMessages() {
        assertParity([system("first"), user("u"), system("second"), assistant("a")])
    }

    func testFused_parityOnEdges() {
        assertParity([])
        assertParity([user("")])
        assertParity([ChatMessage(role: .user, content: nil)])
        assertParity([system("only system")])
        // A nil-content system message (skipped by the joiner, priced as zero)
        // and a system message CARRYING an image — the two arms the fused walk
        // handles "so the parity is exact by construction, not by an assumption
        // about system turns".
        assertParity([ChatMessage(role: .system, content: nil), user("u")])
        assertParity([ChatMessage(role: .system, content: "s",
                                  imageContent: [ImageContent(base64Data: "QUJD",
                                                              mimeType: "image/png")]),
                      user("u")])
    }

    // MARK: - commonPrefixLength edges

    func testCommonPrefixLength_edges() {
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([], []), 0)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([1, 2, 3], []), 0)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([1, 2, 3], [1, 2, 3]), 3)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([1, 2, 3], [1, 2]), 2)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([9, 2], [1, 2]), 0)
    }
}
