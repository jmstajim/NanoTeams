import XCTest

@testable import NanoTeams

final class NativeChatInputTests: XCTestCase {

    // MARK: - NativeChatInput Encoding

    func testTextInput_encodesAsString() throws {
        let input = NativeLMStudioClient.NativeChatInput.text("hello world")
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertEqual(json, "\"hello world\"")
    }

    func testMultimodalInput_encodesAsArray() throws {
        let parts: [NativeLMStudioClient.MultimodalInputPart] = [
            .text("Describe this image"),
            .image(dataURL: "data:image/png;base64,iVBORw0KGgo="),
        ]
        let input = NativeLMStudioClient.NativeChatInput.multimodal(parts)
        let data = try JSONEncoder().encode(input)
        let array = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

        XCTAssertEqual(array.count, 2)

        // First part: {"type": "text", "content": "..."}
        XCTAssertEqual(array[0]["type"] as? String, "text")
        XCTAssertEqual(array[0]["content"] as? String, "Describe this image")

        // Second part: {"type": "image", "data_url": "data:..."}
        XCTAssertEqual(array[1]["type"] as? String, "image")
        XCTAssertEqual(array[1]["data_url"] as? String, "data:image/png;base64,iVBORw0KGgo=")
    }

    func testEmptyMultimodal_encodesAsEmptyArray() throws {
        let input = NativeLMStudioClient.NativeChatInput.multimodal([])
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertEqual(json, "[]")
    }

    // MARK: - MultimodalInputPart Encoding

    func testMultimodalInputPart_textPart_encodesTypeAndContent() throws {
        let part = NativeLMStudioClient.MultimodalInputPart.text("Hello")
        let data = try JSONEncoder().encode(part)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "text")
        XCTAssertEqual(json["content"] as? String, "Hello")
        XCTAssertEqual(json.count, 2, "Should only have 'type' and 'content' keys")
    }

    func testMultimodalInputPart_imagePart_encodesDataURL() throws {
        let part = NativeLMStudioClient.MultimodalInputPart.image(dataURL: "data:image/jpeg;base64,abc")
        let data = try JSONEncoder().encode(part)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "image")
        XCTAssertEqual(json["data_url"] as? String, "data:image/jpeg;base64,abc")
        XCTAssertEqual(json.count, 2, "Should only have 'type' and 'data_url' keys")
    }

    // MARK: - NativeChatRequest with Multimodal Input

    func testNativeChatRequest_withMultimodalInput_encodesCorrectly() throws {
        let parts: [NativeLMStudioClient.MultimodalInputPart] = [
            .text("Analyze"),
            .image(dataURL: "data:image/png;base64,data"),
        ]
        let request = NativeLMStudioClient.NativeChatRequest(
            model: "vision-model",
            systemPrompt: "You are an assistant",
            input: .multimodal(parts),
            previousResponseID: nil,
            store: false,
            stream: true,
            maxOutputTokens: nil,
            temperature: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["model"] as? String, "vision-model")
        XCTAssertFalse(json["store"] as! Bool)

        // input should be an array (multimodal)
        let input = json["input"] as? [[String: Any]]
        XCTAssertNotNil(input)
        XCTAssertEqual(input?.count, 2)

        // Verify image part uses data_url
        let imagePart = input?[1]
        XCTAssertEqual(imagePart?["type"] as? String, "image")
        XCTAssertNotNil(imagePart?["data_url"] as? String)
    }

    func testNativeChatRequest_withTextInput_encodesAsString() throws {
        let request = NativeLMStudioClient.NativeChatRequest(
            model: "text-model",
            systemPrompt: nil,
            input: .text("Hello"),
            previousResponseID: nil,
            store: true,
            stream: true,
            maxOutputTokens: nil,
            temperature: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["input"] as? String, "Hello")
        XCTAssertTrue(json["store"] as! Bool)
    }
}
