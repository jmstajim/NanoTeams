import XCTest
@testable import NanoTeams

final class NativeLMStudioWireTypesTests: XCTestCase {

    // MARK: - ChatEndEvent — nested format

    func testChatEndEvent_nestedFormat_decodesCorrectly() throws {
        let json = """
        {
            "result": {
                "response_id": "resp-abc",
                "stats": {
                    "input_tokens": 100,
                    "total_output_tokens": 50
                }
            }
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NativeLMStudioClient.ChatEndEvent.self, from: json)
        XCTAssertEqual(event.stats?.inputTokens, 100)
        XCTAssertEqual(event.stats?.outputTokens, 50)
    }

    // MARK: - ChatEndEvent — flat format

    func testChatEndEvent_flatFormat_decodesCorrectly() throws {
        let json = """
        {
            "response_id": "resp-xyz",
            "stats": {
                "input_tokens": 200,
                "total_output_tokens": 75
            }
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NativeLMStudioClient.ChatEndEvent.self, from: json)
        XCTAssertEqual(event.stats?.inputTokens, 200)
        XCTAssertEqual(event.stats?.outputTokens, 75)
    }

    // MARK: - Stats — alternative field names

    func testStats_tokensInTokensOut_format() throws {
        let json = """
        {
            "tokens_in": 150,
            "tokens_out": 80
        }
        """.data(using: .utf8)!
        let stats = try JSONDecoder().decode(NativeLMStudioClient.ChatEndEvent.Stats.self, from: json)
        XCTAssertEqual(stats.inputTokens, 150)
        XCTAssertEqual(stats.outputTokens, 80)
    }

    func testStats_inputTokensTotalOutputTokens_format() throws {
        let json = """
        {
            "input_tokens": 300,
            "total_output_tokens": 120
        }
        """.data(using: .utf8)!
        let stats = try JSONDecoder().decode(NativeLMStudioClient.ChatEndEvent.Stats.self, from: json)
        XCTAssertEqual(stats.inputTokens, 300)
        XCTAssertEqual(stats.outputTokens, 120)
    }

    /// Absent counts decode to ABSENT, not to zero.
    ///
    /// Until 2026-08-19 this asserted `0` for both, and the zeros travelled: `SSEEventParser` built
    /// a `TokenUsage(0, 0)` out of them, which is non-nil, which meant `GenerationSampleRecorder`
    /// never raised `.noTokensReported` — so a benchmark run that measured nothing rendered as a
    /// finished run of dashes. A count the server did not send has to be distinguishable from one
    /// it sent as zero.
    func testStats_missingFields_areAbsentRatherThanZero() throws {
        let json = "{}".data(using: .utf8)!
        let stats = try JSONDecoder().decode(NativeLMStudioClient.ChatEndEvent.Stats.self, from: json)
        XCTAssertNil(stats.inputTokens)
        XCTAssertNil(stats.outputTokens)
        XCTAssertNil(stats.tokensPerSecond)
        XCTAssertNil(stats.reasoningOutputTokens)
    }

    /// The complement, and the reason the line above is not pedantry: a server that really does
    /// report zero is recorded as having reported it.
    func testStats_explicitZeroIsAMeasurement() throws {
        let json = #"{"input_tokens":0,"total_output_tokens":0}"#.data(using: .utf8)!
        let stats = try JSONDecoder().decode(NativeLMStudioClient.ChatEndEvent.Stats.self, from: json)
        XCTAssertEqual(stats.inputTokens, 0)
        XCTAssertEqual(stats.outputTokens, 0)
    }

    func testStats_inputTokensTakesPrecedenceOverTokensIn() throws {
        let json = """
        {
            "input_tokens": 500,
            "tokens_in": 100,
            "total_output_tokens": 200,
            "tokens_out": 50
        }
        """.data(using: .utf8)!
        let stats = try JSONDecoder().decode(NativeLMStudioClient.ChatEndEvent.Stats.self, from: json)
        XCTAssertEqual(stats.inputTokens, 500)
        XCTAssertEqual(stats.outputTokens, 200)
    }

    // MARK: - ChatEndEvent — no stats

    func testChatEndEvent_noStats_statsIsNil() throws {
        let json = """
        {
            "response_id": "resp-only"
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NativeLMStudioClient.ChatEndEvent.self, from: json)
        XCTAssertNil(event.stats)
    }

    // MARK: - MessageDeltaEvent

    func testMessageDeltaEvent_decodesContent() throws {
        let json = """
        {"content": "Hello world"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NativeLMStudioClient.MessageDeltaEvent.self, from: json)
        XCTAssertEqual(event.content, "Hello world")
    }

    func testMessageDeltaEvent_nilContent() throws {
        let json = "{}".data(using: .utf8)!
        let event = try JSONDecoder().decode(NativeLMStudioClient.MessageDeltaEvent.self, from: json)
        XCTAssertNil(event.content)
    }

    // MARK: - ErrorEvent

    func testErrorEvent_decodesMessage() throws {
        let json = """
        {"message": "Model not loaded"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NativeLMStudioClient.ErrorEvent.self, from: json)
        XCTAssertEqual(event.message, "Model not loaded")
    }

    // MARK: - NativeModelListResponse

    func testNativeModelListResponse_decodesModels() throws {
        let json = """
        {
            "models": [
                {"key": "model-a", "type": "llm"},
                {"key": "model-b", "type": "embedding"},
                {"key": "model-c"}
            ]
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(NativeLMStudioClient.NativeModelListResponse.self, from: json)
        XCTAssertEqual(response.models.count, 3)
        XCTAssertEqual(response.models[0].key, "model-a")
        XCTAssertEqual(response.models[0].type, "llm")
        XCTAssertEqual(response.models[1].key, "model-b")
        XCTAssertEqual(response.models[1].type, "embedding")
        XCTAssertNil(response.models[2].type)
    }

    // MARK: - OpenAIModelListResponse

    func testOpenAIModelListResponse_decodesData() throws {
        let json = """
        {
            "data": [
                {"id": "gpt-4"},
                {"id": "gpt-3.5-turbo"}
            ]
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(NativeLMStudioClient.OpenAIModelListResponse.self, from: json)
        XCTAssertEqual(response.data.count, 2)
        XCTAssertEqual(response.data[0].id, "gpt-4")
        XCTAssertEqual(response.data[1].id, "gpt-3.5-turbo")
    }

    // MARK: - PromptProcessingProgressEvent

    func testPromptProcessingProgressEvent_decodesProgress() throws {
        let json = """
        {"progress": 0.75}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(NativeLMStudioClient.PromptProcessingProgressEvent.self, from: json)
        XCTAssertEqual(event.progress, 0.75, accuracy: 0.001)
    }
}
