import XCTest

@testable import NanoTeams

/// The mode a step's conversation was written under is PINNED on the step, because a
/// transcript is byte-faithful to one protocol and cannot be replayed under the other.
final class StepExecutionToolCallingModeTests: XCTestCase {

    private func step(mode: ToolCallingMode? = nil,
                      wire: [ChatMessage] = [],
                      display: [LLMMessage] = []) -> StepExecution {
        StepExecution(
            id: "swe", role: .softwareEngineer, title: "work",
            llmConversation: display, wireTranscript: wire, toolCallingMode: mode)
    }

    // MARK: - Codable

    func testPinnedMode_roundTrips() throws {
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        for mode in ToolCallingMode.allCases {
            let data = try encoder.encode(step(mode: mode))
            XCTAssertEqual(try decoder.decode(StepExecution.self, from: data).toolCallingMode, mode)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"toolCallingMode\""))
        }
    }

    /// A fresh step writes no key: every pre-existing `task.json` re-encoded after a read must
    /// not grow one, and a decoder reading an absent key must answer `nil`, not a default.
    func testNoMode_encodesNoKey_andDecodesToNil() throws {
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(step())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("toolCallingMode"))
        XCTAssertNil(try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: data).toolCallingMode)
    }

    func testLegacyJSON_withoutTheKey_decodesToNil() throws {
        let json = #"{"id":"swe","role":"softwareEngineer","title":"work"}"#
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: Data(json.utf8))
        XCTAssertNil(decoded.toolCallingMode)
    }

    // MARK: - The replay rule

    func testFreshStep_replaysNothing_soTheNextEntryResolves() {
        XCTAssertNil(step().replayToolCallingMode)
    }

    func testPinnedMode_wins() {
        XCTAssertEqual(step(mode: .native, wire: [ChatMessage(role: .user, content: "x")]).replayToolCallingMode, .native)
        XCTAssertEqual(step(mode: .promptTaught).replayToolCallingMode, .promptTaught)
    }

    /// A transcript with no pin was written by a build that knew one protocol only. Both
    /// records count — a legacy step may carry the display record and no wire transcript.
    func testUnpinnedTranscript_isPromptTaught() {
        XCTAssertEqual(step(wire: [ChatMessage(role: .user, content: "x")]).replayToolCallingMode, .promptTaught)
        XCTAssertEqual(step(display: [LLMMessage(role: .user, content: "x")]).replayToolCallingMode, .promptTaught)
    }

    func testReset_clearsThePin() {
        var s = step(mode: .native, wire: [ChatMessage(role: .user, content: "x")])
        s.reset()
        XCTAssertNil(s.toolCallingMode)
        XCTAssertNil(s.replayToolCallingMode, "the re-run resolves afresh")
    }
}
