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

    // MARK: - commonPrefixLength edges

    func testCommonPrefixLength_edges() {
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([], []), 0)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([1, 2, 3], []), 0)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([1, 2, 3], [1, 2, 3]), 3)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([1, 2, 3], [1, 2]), 2)
        XCTAssertEqual(PromptPrefixFingerprint.commonPrefixLength([9, 2], [1, 2]), 0)
    }
}
