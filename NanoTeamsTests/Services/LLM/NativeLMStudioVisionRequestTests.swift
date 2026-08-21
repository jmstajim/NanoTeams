import XCTest
@testable import NanoTeams

/// Tests for `NativeLMStudioClient.buildRequest` vision / multimodal path.
/// Existing `NativeChatInputTests` pins the wire-format (discriminated union
/// with `type`/`content`/`data_url` keys); these tests pin the upstream
/// *detection* and *invariants* in the builder:
///
/// 1. A message carrying `imageContent` flips `input` from `.text` to
///    `.multimodal`.
/// 2. The `store` field is set to `false` when images are present (vision =
///    "fresh chat, no server-side storage" per `NativeLMStudioClient+RequestBuilder`).
/// 3. When there's no text part (e.g. image-only prompt), the multimodal
///    array contains only image parts — no empty `.text("")` leaks in.
/// 4. Multiple `ImageContent` entries on a single message all appear as
///    `.image` parts.
/// 5. An empty `imageContent` array does NOT trigger the multimodal path
///    (guard: `!img.isEmpty`).
/// 6. System prompt handling is unchanged in multimodal mode (stateful
///    continuation still omits by default).
final class NativeLMStudioVisionRequestTests: XCTestCase {

    // MARK: - Helpers

    private func config(model: String = "vision-model") -> LLMConfig {
        LLMConfig(provider: .lmStudio,
                  baseURLString: "http://localhost:1234",
                  modelName: model)
    }

    private func imagePNG(base64: String = "aGVsbG8=") -> ImageContent {
        ImageContent(base64Data: base64, mimeType: "image/png")
    }

    // MARK: - Multimodal detection

    func testBuildRequest_imageContentPresent_producesMultimodalInput() {
        let messages = [
            ChatMessage(role: .user, content: "Describe this image.",
                        imageContent: [imagePNG()])
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )

        guard case .multimodal(let parts) = request.input else {
            return XCTFail("Expected `.multimodal` input, got \(request.input)")
        }
        XCTAssertGreaterThanOrEqual(parts.count, 2,
                                    "Text + image parts should both appear")
    }

    func testBuildRequest_noImageContent_producesTextInput() {
        let messages = [
            ChatMessage(role: .user, content: "Plain text only")
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )

        guard case .text = request.input else {
            return XCTFail("Expected `.text` input, got \(request.input)")
        }
    }

    /// Empty `imageContent` array (not nil) must NOT trigger multimodal —
    /// guard uses `!img.isEmpty`. A regression where the builder treats
    /// `imageContent: []` as "has images" would emit multimodal with no
    /// image parts, causing API errors.
    func testBuildRequest_emptyImageContentArray_doesNotTriggerMultimodal() {
        let messages = [
            ChatMessage(role: .user, content: "Plain text with empty img array",
                        imageContent: [])
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )

        guard case .text = request.input else {
            return XCTFail("Empty imageContent should stay on the text path")
        }
    }

    // MARK: - `store` flag — always false

    /// `store: false` on every request, image-bearing or not. It used to be
    /// image-conditional (vision forced a fresh chat); with response chains gone
    /// nothing ever resumes a stored response, so the flag is uniformly off.
    func testBuildRequest_withImages_storeIsFalse() {
        let messages = [
            ChatMessage(role: .user, content: "Analyze",
                        imageContent: [imagePNG()])
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )
        XCTAssertFalse(request.store,
                       "Vision requests must NOT be stored on the server (fresh chat)")
    }

    func testBuildRequest_withoutImages_storeIsAlsoFalse() {
        let messages = [ChatMessage(role: .user, content: "Plain")]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )
        XCTAssertFalse(request.store,
                       "Text-only requests must not be stored either — no chain resumes them")
    }

    // MARK: - Multimodal part structure

    func testBuildRequest_multipleImagesOnOneMessage_allBecomeImageParts() {
        let messages = [
            ChatMessage(role: .user, content: "Compare these",
                        imageContent: [
                            imagePNG(base64: "AAAA"),
                            imagePNG(base64: "BBBB"),
                            imagePNG(base64: "CCCC"),
                        ])
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )

        guard case .multimodal(let parts) = request.input else {
            return XCTFail("Expected multimodal")
        }

        var imageCount = 0
        for part in parts {
            if case .image = part { imageCount += 1 }
        }
        XCTAssertEqual(imageCount, 3,
                       "Every ImageContent entry must surface as its own `.image` part")
    }

    /// When there's no text AND an image is present, `inputString` becomes
    /// empty — the builder must skip appending a `.text("")` leading part
    /// rather than sending an empty text segment.
    func testBuildRequest_imageOnly_noEmptyTextLeaks() {
        let messages = [
            ChatMessage(role: .user, content: "",
                        imageContent: [imagePNG()])
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )

        guard case .multimodal(let parts) = request.input else {
            return XCTFail("Expected multimodal")
        }

        for part in parts {
            if case .text(let s) = part {
                XCTAssertFalse(s.isEmpty, "Leading empty text part must NOT be emitted")
            }
        }
    }

    func testBuildRequest_imagesAcrossMultipleMessages_allCollected() {
        let messages = [
            ChatMessage(role: .user, content: "First",
                        imageContent: [imagePNG(base64: "XXX")]),
            ChatMessage(role: .user, content: "Second",
                        imageContent: [imagePNG(base64: "YYY")]),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )

        guard case .multimodal(let parts) = request.input else {
            return XCTFail("Expected multimodal")
        }
        var imageCount = 0
        for part in parts {
            if case .image = part { imageCount += 1 }
        }
        XCTAssertEqual(imageCount, 2)
    }

    // MARK: - System prompt interactions

    func testBuildRequest_multimodal_stateless_includesSystemPrompt() {
        let messages = [
            ChatMessage(role: .system, content: "You are a vision assistant."),
            ChatMessage(role: .user, content: "Describe",
                        imageContent: [imagePNG()]),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )
        XCTAssertNotNil(request.systemPrompt)
        XCTAssertTrue(request.systemPrompt!.contains("vision assistant"))
    }

    /// Multimodal follows the same rule as every other request: `system_prompt`
    /// always ships and `store` is always false. The old builder special-cased
    /// images to force `store:false`; now the whole surface is uniform.
    func testBuildRequest_multimodal_carriesSystemPromptAndNeverStores() {
        let messages = [
            ChatMessage(role: .system, content: "vision system"),
            ChatMessage(role: .user, content: "Describe again",
                        imageContent: [imagePNG()]),
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )

        XCTAssertNotNil(request.systemPrompt)
        XCTAssertTrue(request.systemPrompt!.contains("vision system"))
        XCTAssertFalse(request.store)
    }

    // MARK: - Wire-format pinning

    /// End-to-end wire shape: the top-level `input` JSON must be an array
    /// whose image elements use `data_url` with a `data:` URI. This pins
    /// both the schema (LM Studio's discriminated union format) and the
    /// data-URL prefix conventions.
    func testBuildRequest_multimodal_wireShape_usesDataURLScheme() throws {
        let messages = [
            ChatMessage(role: .user, content: "Hi",
                        imageContent: [ImageContent(base64Data: "ABC",
                                                    mimeType: "image/jpeg")])
        ]
        let request = NativeLMStudioClient.buildRequest(
            config: config(), messages: messages, tools: []
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let inputArray = json["input"] as? [[String: Any]]
        XCTAssertNotNil(inputArray, "Multimodal input must serialize as a JSON array")

        let imagePart = inputArray?.first { ($0["type"] as? String) == "image" }
        XCTAssertNotNil(imagePart, "Must contain an image part")
        let dataURL = imagePart?["data_url"] as? String ?? ""
        XCTAssertTrue(dataURL.hasPrefix("data:image/jpeg;base64,"),
                      "Image part must use `data:` URI scheme, got `\(dataURL)`")
        XCTAssertTrue(dataURL.hasSuffix("ABC"),
                      "Base64 payload must be preserved end-to-end")
    }
}
