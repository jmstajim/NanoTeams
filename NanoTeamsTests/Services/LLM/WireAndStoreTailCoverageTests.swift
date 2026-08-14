import XCTest

@testable import NanoTeams

/// Wave 10 — three small tails in the LLM layer that a caller can reach today and nothing did.
///
/// Grouped by "what the user or the model actually sees when it fires": a deletion refusal, a
/// wire rendering, and the live buffer the stuck-detector reads.
final class WireAndStoreTailCoverageTests: XCTestCase {

    // MARK: - LMStudioModelDeletionError

    /// The only rendering of a failed model deletion, shown in the Downloaded Models card. Two of
    /// the four arms had never rendered, and they are the two that carry a VALUE — the id that
    /// was refused, and the underlying Trash failure. An arm that dropped its payload would leave
    /// the user with "couldn't delete" and no way to tell which model or why, in a card whose
    /// whole purpose is reclaiming tens of gigabytes.
    ///
    /// RED: drop the interpolated `id` / `underlying.localizedDescription` from either arm → that
    /// arm's payload assertion fails.
    func testDeletionError_everyArmRendersAndCarriesItsPayload() {
        let underlying = NSError(
            domain: "NSCocoaErrorDomain", code: 513,
            userInfo: [NSLocalizedDescriptionKey: "permission denied by the Finder"])

        let messages = [
            LMStudioModelDeletionError.remoteServer.errorDescription ?? "",
            LMStudioModelDeletionError.modelsFolderNotFound.errorDescription ?? "",
            LMStudioModelDeletionError.invalidModelID("../../etc").errorDescription ?? "",
            LMStudioModelDeletionError.trashFailed(underlying: underlying).errorDescription ?? "",
        ]

        XCTAssertTrue(messages[2].contains("../../etc"),
                      "the refused id must appear or the user cannot tell which row failed; got: \(messages[2])")
        XCTAssertTrue(messages[3].contains("permission denied by the Finder"),
                      "the underlying reason is the only actionable half; got: \(messages[3])")
        XCTAssertEqual(Set(messages).count, 4, "each arm must render distinctly")
        XCTAssertFalse(messages.contains(where: \.isEmpty))
    }

    /// The hand-written `==`. Its `default: false` arm — the one that answers "these are
    /// different kinds of failure" — was never taken, so nothing checked that the equality is a
    /// comparison rather than a constant. `trashFailed` deliberately ignores its `Error` payload
    /// (`Error` is not `Equatable`), which is exactly the kind of asymmetry a test has to state
    /// so it reads as a decision rather than an omission.
    ///
    /// RED: replace the `default` arm with `true` → every cross-kind assertion below fails.
    func testDeletionError_equalityDistinguishesKinds() {
        let a = LMStudioModelDeletionError.invalidModelID("x")
        let b = LMStudioModelDeletionError.invalidModelID("y")
        XCTAssertEqual(a, LMStudioModelDeletionError.invalidModelID("x"))
        XCTAssertNotEqual(a, b, "the id participates in equality")

        XCTAssertNotEqual(a, .remoteServer)
        XCTAssertNotEqual(LMStudioModelDeletionError.remoteServer, .modelsFolderNotFound)
        XCTAssertNotEqual(LMStudioModelDeletionError.modelsFolderNotFound,
                          .trashFailed(underlying: NSError(domain: "d", code: 1)))

        // Documented asymmetry: two Trash failures compare equal regardless of cause.
        XCTAssertEqual(
            LMStudioModelDeletionError.trashFailed(underlying: NSError(domain: "d", code: 1)),
            LMStudioModelDeletionError.trashFailed(underlying: NSError(domain: "other", code: 99)))
    }

    // MARK: - Request builder

    /// A `.system` message that is NOT the first one. `buildRequest` hoists EVERY system message
    /// into `system_prompt`, and `input` must carry none of them — emitting one would send the
    /// system prompt twice, once labelled and once not, on every request of a conversation that
    /// carries a mid-stream system turn.
    ///
    /// The loop's `case .system: break` arm was the target this test was written for, and probing
    /// found something more interesting than coverage: the property is guarded TWICE, and either
    /// guard alone is sufficient. `nonSystemMessages` filters `role != .system` before the loop
    /// (which is why the arm never executes and shows as uncovered), and the arm itself skips a
    /// system message should one ever reach it. Both mutations were measured and neither is
    /// observable on its own — dropping the filter leaves the arm to skip, and making the arm
    /// append leaves the filter to exclude.
    ///
    /// That redundancy is the reason to keep the test rather than to delete it: nothing else
    /// stated the property, so a refactor that removed BOTH — the natural one, since each looks
    /// redundant in the presence of the other — would ship the system prompt twice per request
    /// with no signal.
    ///
    /// RED: `for msg in messages` AND `case .system: textParts.append(msg.content ?? "")` together
    /// → the `SYSTEM-BETA` assertion fails. Either alone is silent, by design.
    func testBuildRequest_midConversationSystemMessage_isNotEchoedIntoInput() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "SYSTEM-ALPHA"),
            ChatMessage(role: .user, content: "first"),
            ChatMessage(role: .system, content: "SYSTEM-BETA"),
            ChatMessage(role: .assistant, content: "reply"),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1", modelName: "m"),
            messages: messages,
            tools: [])

        XCTAssertTrue(request.systemPrompt?.contains("SYSTEM-ALPHA") == true)
        XCTAssertTrue(request.systemPrompt?.contains("SYSTEM-BETA") == true,
                      "both system turns are hoisted")

        guard case .text(let input) = request.input else {
            return XCTFail("expected a plain-text input for an image-free conversation")
        }
        XCTAssertTrue(input.contains("first"))
        XCTAssertTrue(input.contains("[Assistant]\nreply"))
        XCTAssertFalse(input.contains("SYSTEM-BETA"),
                       "a system turn must not be echoed into `input`; got: \(input)")
    }

    /// An `array` parameter with no declared `items`, rendered into the Harmony EXAMPLE call that
    /// ships with every tool in the catalog. Small models verbatim-copy that example, so the
    /// placeholder is not decoration — it is what the next tool call will look like.
    ///
    /// `[]` is the honest answer when the schema declines to say what the elements are. The
    /// alternative — guessing a scalar, as the `items`-bearing arm does — would teach the model an
    /// element type the tool never promised, and this renderer sits in segment 0 of every request,
    /// so a wrong guess is repeated on every turn of every run.
    ///
    /// RED: return `"[\"...\"]"` for the item-less case → the `"tags":[]` assertion fails.
    func testToolSchemaSection_arrayWithoutItems_exemplifiesItAsAnEmptyArray() {
        func arrayProp(_ description: String, items: JSONSchemaLeaf?) -> JSONSchemaProperty {
            JSONSchemaProperty(
                type: "array", description: description,
                properties: nil, required: nil, items: items, enumValues: nil)
        }

        let tool = ToolSchema(
            name: "label_files",
            description: "Attach labels to files.",
            parameters: JSONSchema(
                type: "object",
                properties: [
                    "tags": arrayProp("free-form labels", items: nil),
                    "paths": arrayProp("file paths", items: .string()),
                ],
                required: ["paths", "tags"]))

        let section = NativeLMStudioClient.buildToolSchemaSection(tools: [tool])

        XCTAssertTrue(section.contains("\"tags\":[]"),
                      "an item-less array must exemplify as an empty array; got: \(section)")
        XCTAssertTrue(section.contains("\"paths\":[\"...\"]"),
                      "a typed array still shows a representative element; got: \(section)")

        // The flat parameter list beside the example reports the declared element type where
        // there is one, and stays bare where there is not — same distinction, other surface.
        XCTAssertTrue(section.contains("- paths (array of string, required)"), "got: \(section)")
        XCTAssertTrue(section.contains("- tags (array, required)"), "got: \(section)")
    }
}
