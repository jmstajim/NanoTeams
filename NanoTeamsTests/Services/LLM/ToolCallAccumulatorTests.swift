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

    // MARK: - Raw-duplicate probe (per-delta half of duplicate detection)

    /// Raw-only oracle: the byte-identity half of the OLD per-delta check, verbatim —
    /// `"name\u{1F}args"` collision over the finalized calls.
    private func rawOracle() -> Bool {
        var seen = Set<String>()
        for call in accumulator.finalize() {
            if !seen.insert("\(call.name)\u{1F}\(call.argumentsJSON)").inserted { return true }
        }
        return false
    }

    private func delta(_ idx: Int, id: String? = nil, name: String? = nil,
                       args: String? = nil) -> StreamEvent.ToolCallDelta {
        StreamEvent.ToolCallDelta(index: idx, id: id, name: name, argumentsDelta: args)
    }

    /// Two byte-identical calls, framed differently (one whole, one split across
    /// three deltas), must read as duplicates at exactly the same point the old
    /// whole-rebuild check saw them — parity asserted after EVERY absorb.
    func testRawDuplicate_detectedAcrossDifferentDeltaFraming() {
        let steps: [[StreamEvent.ToolCallDelta]] = [
            [delta(0, id: "a", name: "read_file", args: "{\"path\":\"x.txt\"}")],
            [delta(1, id: "b", name: "read_file", args: "{\"path\":")],
            [delta(1, args: "\"x.")],
            [delta(1, args: "txt\"}")],
        ]
        for (i, event) in steps.enumerated() {
            accumulator.absorb(event)
            XCTAssertEqual(accumulator.hasRawDuplicate, rawOracle(),
                           "parity diverged after absorb \(i)")
        }
        XCTAssertTrue(accumulator.hasRawDuplicate)
    }

    func testRawDuplicate_bothCallsInOneCoalescedEvent() {
        accumulator.absorb([
            delta(0, id: "a", name: "git_status", args: "{}"),
            delta(1, id: "b", name: "git_status", args: "{}"),
        ])
        XCTAssertTrue(accumulator.hasRawDuplicate)
        XCTAssertEqual(accumulator.hasRawDuplicate, rawOracle())
    }

    func testDistinctCalls_noRawDuplicate_atAnyPoint() {
        let steps: [[StreamEvent.ToolCallDelta]] = [
            [delta(0, id: "a", name: "read_file", args: "{\"path\":\"a.txt\"}")],
            [delta(1, id: "b", name: "read_file", args: "{\"path\":")],
            [delta(1, args: "\"b.txt\"}")],
        ]
        for event in steps {
            accumulator.absorb(event)
            XCTAssertFalse(accumulator.hasRawDuplicate)
            XCTAssertEqual(accumulator.hasRawDuplicate, rawOracle())
        }
    }

    /// The two-tier split, pinned: whitespace-differing duplicates are NOT the raw
    /// probe's job (no O(1) signature over-approximates JSON canonical equality) —
    /// they are caught by `containsDuplicateToolCalls`, which the streaming loop
    /// runs behind `toolDeltaScanGate` instead of per delta.
    func testCanonicalDuplicate_isNotRaw_butCanonicalPathCatchesIt() {
        accumulator.absorb([
            delta(0, id: "a", name: "write_file", args: "{\"path\":\"x\",\"content\":\"hi\"}"),
            delta(1, id: "b", name: "write_file", args: "{ \"content\" : \"hi\", \"path\" : \"x\" }"),
        ])
        XCTAssertFalse(accumulator.hasRawDuplicate)
        XCTAssertTrue(LLMExecutionService.containsDuplicateToolCalls(accumulator.finalize()))
    }

    func testSingleCall_neverRawDuplicate() {
        accumulator.absorb([delta(0, id: "a", name: "read_file", args: "{\"path\":\"x\"}")])
        XCTAssertFalse(accumulator.hasRawDuplicate)
    }

    /// Nameless partials are invisible to `finalize()` and must be invisible to the
    /// probe too — two identical UNNAMED payloads are not a duplicate CALL.
    func testUnnamedPartials_areIgnoredByTheProbe() {
        accumulator.absorb([
            delta(0, args: "{\"x\":1}"),
            delta(1, args: "{\"x\":1}"),
        ])
        XCTAssertFalse(accumulator.hasRawDuplicate)
        XCTAssertEqual(accumulator.hasRawDuplicate, rawOracle())
    }

    /// Empty-args duplicates: two calls that carry a name and no argument bytes.
    func testRawDuplicate_emptyArgsPair() {
        accumulator.absorb([
            delta(0, id: "a", name: "list_files"),
            delta(1, id: "b", name: "list_files"),
        ])
        XCTAssertEqual(accumulator.hasRawDuplicate, rawOracle())
        XCTAssertTrue(accumulator.hasRawDuplicate)
    }

    /// WIRING PIN (CLAUDE.md #57): the canonical probe in the `toolCallDeltas`
    /// branch of `performStreamingCall` must sit behind `toolDeltaScanGate` —
    /// restoring the per-delta call is the mutation this catches. Anti-vacuum:
    /// both identifiers must exist in the branch at all.
    func testStreamingWiring_canonicalProbeIsCadenceGated() throws {
        let url = RatchetSourceScan.repoRoot
            .appendingPathComponent("NanoTeams/Services/LLM/LLMExecutionService+Streaming.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let branchStart = source.range(of: "if !event.toolCallDeltas.isEmpty {") else {
            return XCTFail("toolCallDeltas branch not found — the pin's subject moved")
        }
        // The branch ends where the usage-capture lines resume.
        guard let branchEnd = source.range(of: "if let u = event.tokenUsage",
                                           range: branchStart.upperBound..<source.endIndex) else {
            return XCTFail("end anchor not found — the pin's subject moved")
        }
        let branch = source[branchStart.lowerBound..<branchEnd.lowerBound]
        XCTAssertTrue(branch.contains("hasRawDuplicate"),
                      "per-delta raw probe vanished from the toolCallDeltas branch")
        guard let canonical = branch.range(of: "containsDuplicateToolCalls") else {
            return XCTFail("canonical probe vanished from the toolCallDeltas branch")
        }
        guard let gate = branch.range(of: "toolDeltaScanGate.shouldScan") else {
            return XCTFail("cadence gate vanished from the toolCallDeltas branch")
        }
        XCTAssertTrue(gate.lowerBound < canonical.lowerBound,
                      "canonical probe runs before/without the cadence gate — the "
                          + "per-delta full JSON parse is back (CLAUDE.md #106)")
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
