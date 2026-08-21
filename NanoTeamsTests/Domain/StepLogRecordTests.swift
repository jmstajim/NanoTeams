import XCTest

@testable import NanoTeams

/// Codable pins for the step-log record union and the `logCommit` stamp.
final class StepLogRecordTests: XCTestCase {

    private let encoder = JSONCoderFactory.makeJSONLEncoder()
    private let decoder = JSONCoderFactory.makeDateDecoder()

    private func roundTrip(_ entry: StepLogEntry) throws -> StepLogEntry {
        try decoder.decode(StepLogEntry.self, from: encoder.encode(entry))
    }

    func testConversationRecord_roundTrips() throws {
        // Millisecond-aligned createdAt: the shared ISO 8601 strategy carries
        // fractional seconds to ms — the same precision task.json has always
        // had — and an unaligned Date would differ in sub-ms bits after decode.
        let msg = LLMMessage(
            createdAt: Date(timeIntervalSince1970: 1_755_800_000.123),
            role: .assistant, content: "hello", thinking: "think")
        let back = try roundTrip(StepLogEntry(seq: 3, record: .conversation(msg)))
        XCTAssertEqual(back.seq, 3)
        guard case .conversation(let m) = back.record else { return XCTFail("wrong case") }
        XCTAssertEqual(m, msg)
    }

    func testToolCallAndMessageRecords_roundTripByID() throws {
        let call = StepToolCall(name: "read_file", argumentsJSON: #"{"path":"a"}"#)
        let back = try roundTrip(StepLogEntry(seq: 1, record: .toolCall(call)))
        guard case .toolCall(let t) = back.record else { return XCTFail("wrong case") }
        XCTAssertEqual(t.id, call.id)

        let sm = StepMessage(role: .supervisor, content: "note")
        let back2 = try roundTrip(StepLogEntry(seq: 2, record: .message(sm)))
        guard case .message(let m) = back2.record else { return XCTFail("wrong case") }
        XCTAssertEqual(m.id, sm.id)
    }

    func testWireAndTruncateRecords_roundTrip() throws {
        let wire = ChatMessage(role: .user, content: "prompt")
        let back = try roundTrip(StepLogEntry(seq: 5, record: .wire(wire)))
        guard case .wire(let w) = back.record else { return XCTFail("wrong case") }
        XCTAssertEqual(w, wire)

        let back2 = try roundTrip(StepLogEntry(seq: 6, record: .truncate(stream: .conversation, keep: 4)))
        guard case .truncate(let stream, let keep) = back2.record else { return XCTFail("wrong case") }
        XCTAssertEqual(stream, .conversation)
        XCTAssertEqual(keep, 4)
    }

    func testUnknownKind_throwsRatherThanMisreads() {
        let data = Data(#"{"seq":1,"record":{"kind":"hologram"}}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(StepLogEntry.self, from: data))
    }

    /// `logCommit` is encoded only when non-nil — legacy tasks re-encoded after a
    /// read must not grow the key, and a nil round-trips as nil.
    func testStepExecution_logCommit_encodeOnlyWhenPresent() throws {
        var step = StepExecution(id: "engineer", role: .softwareEngineer, title: "T")
        let plain = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        XCTAssertFalse(String(data: plain, encoding: .utf8)!.contains("logCommit"))

        step.logCommit = StepLogCommit(seq: 9, conversation: 2, wire: 1, toolCalls: 1, messages: 0)
        let stamped = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        let back = try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: stamped)
        XCTAssertEqual(back.logCommit,
                       StepLogCommit(seq: 9, conversation: 2, wire: 1, toolCalls: 1, messages: 0))
    }
}
