import XCTest
@testable import NanoTeams

final class ToolCallAccumulatorTests: XCTestCase {
    var accumulator: ToolCallAccumulator!

    override func setUp() {
        super.setUp()
        accumulator = ToolCallAccumulator()
    }

    override func tearDown() {
        accumulator = nil
        super.tearDown()
    }

    // MARK: - Existing Test

    func testStreamingToolCallDeltasAreAssembled() {
        let d0 = StreamEvent.ToolCallDelta(
            index: 0,
            id: "call_1",
            name: "write_artifact",
            argumentsDelta: "{\"kind\":\"plan\""
        )

        let d1 = StreamEvent.ToolCallDelta(
            index: 0,
            id: nil,
            name: nil,
            argumentsDelta: ",\"name\":\"P\",\"content\":\"Hi\"}"
        )

        accumulator.absorb([d0])
        accumulator.absorb([d1])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].providerID, "call_1")
        XCTAssertEqual(calls[0].name, "write_artifact")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"kind\":\"plan\",\"name\":\"P\",\"content\":\"Hi\"}")
    }

    // MARK: - Multiple Tool Calls

    func testMultipleToolCallsParallel() {
        let deltas: [StreamEvent.ToolCallDelta] = [
            StreamEvent.ToolCallDelta(index: 0, id: "call_0", name: "read_file", argumentsDelta: "{\"path\":\"a.txt\"}"),
            StreamEvent.ToolCallDelta(index: 1, id: "call_1", name: "write_file", argumentsDelta: "{\"path\":\"b.txt\"}"),
            StreamEvent.ToolCallDelta(index: 2, id: "call_2", name: "git_status", argumentsDelta: "{}")
        ]

        accumulator.absorb(deltas)

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].name, "read_file")
        XCTAssertEqual(calls[0].providerID, "call_0")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"path\":\"a.txt\"}")
        XCTAssertEqual(calls[1].name, "write_file")
        XCTAssertEqual(calls[1].providerID, "call_1")
        XCTAssertEqual(calls[1].argumentsJSON, "{\"path\":\"b.txt\"}")
        XCTAssertEqual(calls[2].name, "git_status")
        XCTAssertEqual(calls[2].providerID, "call_2")
        XCTAssertEqual(calls[2].argumentsJSON, "{}")
    }

    func testMultipleAbsorbCalls() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "call_0", name: "edit_code_in_file", argumentsDelta: "{\"path\":")
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "\"main.swift\",")
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "\"content\":\"hello\"}")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].argumentsJSON, "{\"path\":\"main.swift\",\"content\":\"hello\"}")
    }

    // MARK: - ID and Name Handling

    func testIdOverwrittenByLaterDelta() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "a", name: "tool", argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "b", name: nil, argumentsDelta: nil)
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].providerID, "b")
    }

    func testNameOverwrittenByLaterDelta() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "call_1", name: "old_name", argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: "new_name", argumentsDelta: nil)
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "new_name")
    }

    func testEmptyIdIgnored() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "original_id", name: "tool", argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "", name: nil, argumentsDelta: nil)
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].providerID, "original_id")
    }

    func testEmptyNameIgnored() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "call_1", name: "original_tool", argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: "", argumentsDelta: nil)
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "original_tool")
    }

    func testNilIdIgnored() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "keep_this", name: "tool", argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "{}")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].providerID, "keep_this")
    }

    func testNilNameIgnored() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: "keep_name", argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "{}")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "keep_name")
    }

    // MARK: - Arguments Accumulation

    func testArgumentsAccumulate() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: "tool", argumentsDelta: "AAA")
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "BBB")
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "CCC")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].argumentsJSON, "AAABBBCCC")
    }

    func testNilArgumentsDeltaIgnored() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: "tool", argumentsDelta: "first")
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "second")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].argumentsJSON, "firstsecond")
    }

    func testEmptyArgumentsDeltaIgnored() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: "tool", argumentsDelta: "data")
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].argumentsJSON, "data")
    }

    // MARK: - Index Handling

    func testNilIndexDefaultsToZero() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: nil, id: "call_nil", name: "tool_nil_idx", argumentsDelta: "{}")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "tool_nil_idx")
        XCTAssertEqual(calls[0].providerID, "call_nil")
    }

    func testExplicitIndexZero() {
        // Absorb with nil index first, then explicit index 0 — should merge into same entry
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: nil, id: "call_x", name: "my_tool", argumentsDelta: "part1")
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "part2")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "my_tool")
        XCTAssertEqual(calls[0].providerID, "call_x")
        XCTAssertEqual(calls[0].argumentsJSON, "part1part2")
    }

    // MARK: - Finalize Behavior

    func testFinalizeEmptyAccumulator() {
        let calls = accumulator.finalize()
        XCTAssertTrue(calls.isEmpty)
    }

    func testFinalizeFiltersEmptyNames() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "call_0", name: nil, argumentsDelta: "{}")
        ])

        let calls = accumulator.finalize()
        XCTAssertTrue(calls.isEmpty, "Tool call with empty name (default from nil) should be filtered out")
    }

    func testFinalizeFiltersWhitespaceOnlyNames() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "call_0", name: "  \n", argumentsDelta: "{}")
        ])

        let calls = accumulator.finalize()
        XCTAssertTrue(calls.isEmpty, "Tool call with whitespace-only name should be filtered out")
    }

    func testFinalizeSortsByIndex() {
        // Absorb in reverse order: 2, 0, 1
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 2, id: "c2", name: "tool_two", argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: "c0", name: "tool_zero", argumentsDelta: nil)
        ])
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 1, id: "c1", name: "tool_one", argumentsDelta: nil)
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].name, "tool_zero")
        XCTAssertEqual(calls[0].providerID, "c0")
        XCTAssertEqual(calls[1].name, "tool_one")
        XCTAssertEqual(calls[1].providerID, "c1")
        XCTAssertEqual(calls[2].name, "tool_two")
        XCTAssertEqual(calls[2].providerID, "c2")
    }

    func testFinalizeAllowsNilProviderID() {
        accumulator.absorb([
            StreamEvent.ToolCallDelta(index: 0, id: nil, name: "no_id_tool", argumentsDelta: "{\"key\":\"val\"}")
        ])

        let calls = accumulator.finalize()
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].providerID)
        XCTAssertEqual(calls[0].name, "no_id_tool")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"key\":\"val\"}")
    }

    // MARK: - Partial Hashable

    func testPartialHashable() {
        let a = ToolCallAccumulator.Partial(providerID: "id1", name: "tool", arguments: "{}")
        let b = ToolCallAccumulator.Partial(providerID: "id1", name: "tool", arguments: "{}")
        let c = ToolCallAccumulator.Partial(providerID: "id2", name: "tool", arguments: "{}")
        let d = ToolCallAccumulator.Partial(providerID: "id1", name: "other", arguments: "{}")
        let e = ToolCallAccumulator.Partial(providerID: "id1", name: "tool", arguments: "{\"x\":1}")
        let f = ToolCallAccumulator.Partial(providerID: nil, name: "tool", arguments: "{}")

        // Equal
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)

        // Not equal — different providerID
        XCTAssertNotEqual(a, c)

        // Not equal — different name
        XCTAssertNotEqual(a, d)

        // Not equal — different arguments
        XCTAssertNotEqual(a, e)

        // Not equal — nil vs non-nil providerID
        XCTAssertNotEqual(a, f)

        // Set deduplication
        let set: Set<ToolCallAccumulator.Partial> = [a, b, c]
        XCTAssertEqual(set.count, 2, "a and b should deduplicate in a Set")
    }
}
