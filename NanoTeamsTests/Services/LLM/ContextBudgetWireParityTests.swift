import XCTest

@testable import NanoTeams

/// Same file-private accessor the two LM Studio builder suites carry — `NativeChatInput` is a
/// bare `Encodable` enum with no reader, and it has no production caller that needs one.
private extension NativeLMStudioClient.NativeChatInput {
    var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

/// The measurement surfaces must price the request the WIRE actually sends.
///
/// `toolSchemaTextForMeasurement` mirrors the request builders' append rule, and that rule has
/// two halves. It owned only the first (`tools.isEmpty`) and dropped the second
/// (`!systemPrompt.contains(harmonyBodyMarker)`) — so for every role step, where `PromptBuilder`
/// renders the catalog INTO the system message via the `{toolCalling}` chip and both builders
/// therefore skip the append, the catalog was counted twice. It is the largest single block this
/// app builds, so the overcount ran ~50-60% of a first payload: it inflated every cache-miss
/// token figure and, worse, made `warnIfContextBudgetExceeded` fire on prompts that fit — which
/// in turn silenced the cache-miss reporter for the rest of that step (exemption 3).
final class ContextBudgetWireParityTests: XCTestCase {

    private var tools: [ToolSchema] {
        [
            ToolSchema(
                name: "read_file", description: "Read a file",
                parameters: JSONSchema(type: "object")),
            ToolSchema(
                name: "write_file", description: "Write a file",
                parameters: JSONSchema(type: "object")),
        ]
    }

    private func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: text)
    }

    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }

    /// What `PromptBuilder` produces: the `## Tool Calling` header lives in the user-editable
    /// template and the chip supplies the body, whose first line IS the marker.
    private func roleStepSystemPrompt() -> String {
        "You are an engineer.\n\n## Tool Calling\n"
            + NativeLMStudioClient.buildToolSchemaBody(tools: tools)
            + "\n\n## Final reminder\nShip it."
    }

    // MARK: - The gate itself

    func testMeasurement_returnsEmpty_whenTheSystemPromptAlreadyCarriesTheCatalog() {
        XCTAssertEqual(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools,
                messages: [system(roleStepSystemPrompt()), user("go")]),
            "",
            "the builders skip the append here, so pricing a copy invents payload")
    }

    /// The complement, and the case that keeps the parameter honest: a static system prompt with
    /// no marker (every direct-LLM-call service, and a `.legacyConversation` replay that carries
    /// no system turn at all) genuinely gets the catalog appended on the wire.
    func testMeasurement_returnsTheSection_whenNoSystemMessageCarriesTheMarker() {
        let text = NativeLMStudioClient.toolSchemaTextForMeasurement(
            tools: tools, messages: [system("Plain prompt."), user("go")])
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("read_file"))

        XCTAssertFalse(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools, messages: [user("no system turn at all")]
            ).isEmpty,
            "a rebuilt conversation with no system turn still gets the catalog on the wire")
    }

    func testMeasurement_noTools_isAlwaysEmpty() {
        XCTAssertEqual(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: [], messages: [system("Plain prompt.")]),
            "")
    }

    /// The one real false-negative risk of anchoring on a substring: a `read_file` on a template
    /// file, or a wire-preview pasted into the chat, quotes the marker in a NON-system turn. The
    /// builders merge only `.system` contents, so this must too.
    func testMeasurement_ignoresTheMarkerInNonSystemMessages() {
        let quoted = ChatMessage(
            role: .tool,
            content: "file contents:\n" + NativeLMStudioClient.harmonyBodyMarker)
        XCTAssertFalse(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools, messages: [system("Plain prompt."), quoted]
            ).isEmpty,
            "a tool result quoting the marker must not zero the catalog's cost")
    }

    /// The builders join EVERY `.system` message, so a marker in the second one counts.
    func testMeasurement_detectsTheMarkerInASecondSystemMessage() {
        XCTAssertEqual(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools,
                messages: [system("Role prompt."), system(roleStepSystemPrompt())]),
            "")
    }

    // MARK: - Corner cases: what counts as "the system prompt"

    /// `compactMap(\.content)` drops nil-content turns on both the builders and here, so a nil
    /// system message must not shadow a real one that follows it.
    func testMeasurement_looksPastANilContentSystemMessage() {
        XCTAssertEqual(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools,
                messages: [
                    ChatMessage(role: .system, content: nil),
                    system(roleStepSystemPrompt()),
                ]),
            "",
            "a nil turn contributes nothing, but it must not hide the turn that carries the marker")
    }

    /// The join is `\n\n`, so a marker split across two system turns is NOT contiguous in the
    /// merged prompt — and the builders, joining identically, will append. Asserted as parity
    /// rather than as a value: the point is that both sides read the same string.
    func testMeasurement_markerSplitAcrossTwoSystemTurns_matchesTheBuilder() {
        let messages = [
            system("Call tools using this Harmony"),
            system(" format:"),
            user("go"),
        ]
        let config = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
        let merged = messages.filter { $0.role == .system }.compactMap(\.content)
            .joined(separator: "\n\n")
        let wire = OllamaClient.buildRequest(config: config, messages: messages, tools: tools)
        let wireSystem = wire.messages.first { $0.role == "system" }?.content ?? ""

        XCTAssertEqual(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools, messages: messages).isEmpty,
            wireSystem == merged)
    }

    func testMeasurement_systemContentIsExactlyTheMarker() {
        XCTAssertEqual(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools,
                messages: [system(NativeLMStudioClient.harmonyBodyMarker)]),
            "",
            "the marker is the anchor — carrying it, and nothing else, still means the builder "
                + "will not append")
    }

    func testMeasurement_emptyMessages_stillPricesTheCatalog() {
        XCTAssertFalse(
            NativeLMStudioClient.toolSchemaTextForMeasurement(tools: tools, messages: []).isEmpty,
            "with no system turn there is nothing to carry the catalog, so the wire appends it")
    }

    /// `## Tool Calling` written by hand in a template, without the chip, must NOT be mistaken
    /// for the real block — that is why the anchor is the body marker and not the header. A role
    /// whose prose mentions the heading would otherwise be measured as if it carried a catalog
    /// it never received.
    func testMeasurement_aBareToolCallingHeadingIsNotTheCatalog() {
        XCTAssertFalse(
            NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools,
                messages: [system("## Tool Calling\n\nSee the docs for how to call tools.")]
            ).isEmpty,
            "prose using that heading gets the catalog appended on the wire, so it must be priced")
    }

    // MARK: - Parity with both builders

    /// The SSOT pin: whichever way the gate is changed, it has to move on all three sides at
    /// once. `helper.isEmpty` must mean exactly "the builder appended nothing".
    func testMeasurement_agreesWithBothBuilders() {
        let config = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")

        for (label, messages) in [
            ("catalog inline", [system(roleStepSystemPrompt()), user("go")]),
            ("plain system prompt", [system("Plain prompt."), user("go")]),
            ("no system turn", [user("go")]),
        ] {
            for toolSet in [tools, []] {
                let merged = messages
                    .filter { $0.role == .system }
                    .compactMap(\.content)
                    .joined(separator: "\n\n")
                let appendedNothing = NativeLMStudioClient.toolSchemaTextForMeasurement(
                    tools: toolSet, messages: messages).isEmpty

                let ollama = OllamaClient.buildRequest(
                    config: config, messages: messages, tools: toolSet)
                let ollamaSystem = ollama.messages.first { $0.role == "system" }?.content ?? ""
                XCTAssertEqual(
                    appendedNothing, ollamaSystem == merged,
                    "Ollama disagrees with the measurement gate — \(label), tools: \(toolSet.count)")

                let lmStudio = NativeLMStudioClient.buildRequest(
                    config: config, messages: messages, tools: toolSet)
                XCTAssertEqual(
                    appendedNothing, (lmStudio.systemPrompt ?? "") == merged,
                    "LM Studio disagrees with the measurement gate — \(label), tools: \(toolSet.count)")
            }
        }
    }

    // MARK: - End to end: the estimate equals what goes on the wire

    /// The headline regression. Pre-fix this over-counted by the whole catalog: the estimate for
    /// a role step read ~50-60% above the bytes the request actually carried.
    ///
    /// Tolerance covers what the estimator does not model — the builders' `[Assistant]` /
    /// `[Tool Result]` labels and their `\n\n` joins — not the catalog, which is thousands of
    /// tokens and would blow straight through it.
    func testEstimate_matchesTheBytesTheWireCarries_forARoleStep() {
        let messages = [
            system(roleStepSystemPrompt()),
            user(String(repeating: "supervisor brief ", count: 400)),
            ChatMessage(role: .assistant, content: "working on it"),
        ]
        XCTAssertTrue(
            messages[0].content!.contains(NativeLMStudioClient.harmonyBodyMarker),
            "precondition: this fixture must be shaped like a real role step")

        let config = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
        let wire = OllamaClient.buildRequest(config: config, messages: messages, tools: tools)
        let expected = wire.messages.reduce(0) {
            $0 + WorkFolderContextPromptPlanner.estimateTokens($1.content)
        }

        let actual = ContextBudgetPolicy.estimateTokens(
            messages: messages,
            toolSchemaText: NativeLMStudioClient.toolSchemaTextForMeasurement(
                tools: tools, messages: messages))

        XCTAssertEqual(
            Double(actual), Double(expected), accuracy: Double(expected) / 100,
            "the estimate must price the request the wire actually sends")
    }

    // MARK: - Tool-call envelopes

    /// A tool-calling assistant turn, priced against BOTH builders.
    ///
    /// The streaming path truncates the Harmony envelope out of the assistant CONTENT and files
    /// the calls under `ChatMessage.toolCalls`, so `content` is nil for an envelope-only turn.
    /// The estimator read only `content` and therefore priced that turn at zero while both wires
    /// carry the whole envelope — `argumentsJSON` included.
    ///
    /// The 1% tolerance above does NOT cover this. It was sized for the builders' `[Assistant]` /
    /// `[Tool Result]` labels and `\n\n` joins — a fixed few tokens per message. A tool-call
    /// argument is unbounded: `create_artifact` and `write_file` carry the entire body, so one
    /// turn blows straight through the band exactly as the tool catalog did.
    func testEstimate_matchesTheBytesTheWireCarries_withToolCalls() {
        let messages = [
            system(roleStepSystemPrompt()),
            user("write the release notes"),
            ChatMessage(
                role: .assistant, content: nil,
                toolCalls: [ChatToolCall(
                    id: "tc-1", name: "create_artifact",
                    argumentsJSON: #"{"name":"Release Notes","content":""#
                        + String(repeating: "shipped a thing. ", count: 300) + #""}"#)]),
            ChatMessage(role: .tool, content: #"{"ok":true}"#, toolCallID: "tc-1"),
        ]
        let toolSchemaText = NativeLMStudioClient.toolSchemaTextForMeasurement(
            tools: tools, messages: messages)
        let actual = ContextBudgetPolicy.estimateTokens(
            messages: messages, toolSchemaText: toolSchemaText)

        let ollamaConfig = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
        let ollama = OllamaClient.buildRequest(
            config: ollamaConfig, messages: messages, tools: tools)
        let ollamaExpected = ollama.messages.reduce(0) {
            $0 + WorkFolderContextPromptPlanner.estimateTokens($1.content)
        }
        XCTAssertEqual(
            Double(actual), Double(ollamaExpected), accuracy: Double(ollamaExpected) / 100,
            "Ollama re-materializes the envelope; the estimate must include it")

        let lmConfig = LLMConfig(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
        let lmStudio = NativeLMStudioClient.buildRequest(
            config: lmConfig, messages: messages, tools: tools)
        let lmExpected = WorkFolderContextPromptPlanner.estimateTokens(lmStudio.systemPrompt ?? "")
            + WorkFolderContextPromptPlanner.estimateTokens(lmStudio.input.textValue ?? "")
        XCTAssertEqual(
            Double(actual), Double(lmExpected), accuracy: Double(lmExpected) / 100,
            "LM Studio carries the same envelope, so the same estimate must hold for it")
    }

    /// The estimator has ONE number for a request; that only stays honest while both providers
    /// put the same bytes on the wire. Pinned here rather than left to the two assertions above
    /// so a divergence names itself instead of showing up as a tolerance failure.
    func testBothBuilders_carryTheSameToolCallBytes() {
        let messages = [
            system("Plain prompt."),
            ChatMessage(
                role: .assistant, content: "checking",
                toolCalls: [ChatToolCall(id: "a", name: "git_status", argumentsJSON: "{}")]),
        ]
        let config = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
        let envelope = #"<|call|>{"name":"git_status","arguments":{}}<|end|>"#

        let ollama = OllamaClient.buildRequest(config: config, messages: messages, tools: [])
        XCTAssertTrue(
            ollama.messages.contains { $0.content.contains(envelope) })

        let lmStudio = NativeLMStudioClient.buildRequest(
            config: config, messages: messages, tools: [])
        XCTAssertTrue(lmStudio.input.textValue!.contains(envelope))
    }
}
