import XCTest

@testable import NanoTeams

/// `AskCallIndex` must answer EXACTLY what the `toolCalls` passes it replaces
/// answered — `filter { ask }` positions and `lastIndex(where: ask)` — and must
/// pay for the appended SUFFIX only when extended. The oracle is the verbatim
/// filter over the array, never the index's own parts (CLAUDE.md #158).
final class AskCallIndexTests: XCTestCase {

    private typealias TN = ToolNames

    private func call(_ name: String, id: UUID = UUID()) -> StepToolCall {
        StepToolCall(id: id, name: name, argumentsJSON: "{}")
    }

    private func ask() -> StepToolCall { call(TN.askSupervisor) }
    private func work() -> StepToolCall { call("read_file") }

    /// The OLD law, spelled independently of the index.
    private func oraclePositions(_ calls: [StepToolCall]) -> [Int] {
        calls.indices.filter { calls[$0].name == TN.askSupervisor }
    }

    /// Deterministic LCG (the `ThinkingResolverTests` idiom) — 30 arrays mixing
    /// asks and tool work, including all-ask, no-ask and single-element shapes.
    private func pseudoRandomArrays() -> [[StepToolCall]] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % bound
        }
        return (0..<30).map { _ in
            let n = 1 + next(40)
            let askEvery = 1 + next(5)
            return (0..<n).map { i in i % askEvery == 0 || next(4) == 0 ? ask() : work() }
        }
    }

    // MARK: - Parity with the filter oracle

    /// RED: in `init(toolCalls:extending:)` change `== ToolNames.askSupervisor` to
    /// `!=` → positions are the complement and parity fails on the first array;
    /// make `lastPosition` return `positions.first` → the two-ask arrays disagree.
    func testPositions_matchFilterOracle_onPseudoRandomSequences() {
        var arraysWithTwoAsks = 0
        for calls in pseudoRandomArrays() {
            let index = AskCallIndex(toolCalls: calls)
            let expected = oraclePositions(calls)
            XCTAssertEqual(index.positions, expected)
            XCTAssertEqual(index.count, expected.count)
            XCTAssertEqual(index.isEmpty, !calls.contains { $0.name == TN.askSupervisor })
            XCTAssertEqual(
                index.lastPosition.map { calls[$0].id },
                calls.last(where: { $0.name == TN.askSupervisor })?.id,
                "`lastPosition` must be `lastIndex(where: ask)`")
            if expected.count >= 2 { arraysWithTwoAsks += 1 }
        }
        XCTAssertGreaterThan(arraysWithTwoAsks, 0,
                             "anti-vacuum: the fixture must contain arrays where first ≠ last ask")
    }

    /// The refuter's shape: an ask, then tool work, then a cap park. "Trailing
    /// call only" answers nil here; `lastIndex(where:)` answers 0.
    ///
    /// RED: make `lastPosition` return `positions.last` only when it equals
    /// `describedCount - 1` (trailing-only) → nil.
    func testLastPosition_findsAnEarlierAsk_afterToolWork() {
        let calls = [ask(), work(), work()]
        let index = AskCallIndex(toolCalls: calls)
        XCTAssertEqual(index.lastPosition, 0)
        XCTAssertEqual(index.positions, [0])
    }

    // MARK: - Extending

    /// RED: make `isPrefix(of:)` return `false` (full rescan every time) → the
    /// extending init examines 67, not 3.
    func testExtending_afterAppends_equalsFullScan_andExaminesOnlyTheSuffix() {
        var calls = (0..<64).map { $0 % 7 == 0 ? ask() : work() }
        AskCallIndexProbe.reset()
        let first = AskCallIndex(toolCalls: calls)
        XCTAssertEqual(AskCallIndexProbe.examined(), 64, "anti-vacuum: the first build scans everything")

        calls += [work(), ask(), work()]
        AskCallIndexProbe.reset()
        let extended = AskCallIndex(toolCalls: calls, extending: first)

        XCTAssertEqual(AskCallIndexProbe.examined(), 3, "only the appended suffix is examined")
        XCTAssertEqual(extended.positions, oraclePositions(calls))
        XCTAssertEqual(extended, AskCallIndex(toolCalls: calls), "extending equals a fresh full scan")
    }

    /// RED: make `isPrefix(of:)` return `false` → the extending init rescans the
    /// unchanged 64-call array and `examined` reads 64, not 0.
    func testExtending_unchangedArray_examinesNothing() {
        let calls = (0..<64).map { $0 % 5 == 0 ? ask() : work() }
        let first = AskCallIndex(toolCalls: calls)
        AskCallIndexProbe.reset()
        let again = AskCallIndex(toolCalls: calls, extending: first)
        XCTAssertEqual(AskCallIndexProbe.examined(), 0)
        XCTAssertEqual(again, first)
    }

    /// An index over an EMPTY array describes a prefix of anything — the boundary
    /// case of `describedCount == 0`, where there is no last id to compare (and so
    /// no `toolCalls[-1]` read). The cadence is NOT discriminating here: a rescan
    /// from 0 also examines 3 and also yields `[1]`.
    ///
    /// RED: change `== ToolNames.askSupervisor` to `!=` in the scan → positions
    /// read `[0, 2]`, not `[1]`.
    func testExtending_fromAnEmptyIndex_scansTheWholeAppendedArray() {
        let empty = AskCallIndex(toolCalls: [])
        XCTAssertEqual(empty.describedCount, 0)
        XCTAssertNil(empty.describedLastID)
        XCTAssertNil(empty.lastPosition)

        let calls = [work(), ask(), work()]
        AskCallIndexProbe.reset()
        let extended = AskCallIndex(toolCalls: calls, extending: empty)
        XCTAssertEqual(AskCallIndexProbe.examined(), 3)
        XCTAssertEqual(extended.positions, [1])
    }

    /// RED: drop the `describedCount <= toolCalls.count` clause → (a) indexes past
    /// the end (trap) or keeps the stale position 40; drop the
    /// `toolCalls[describedCount - 1].id == describedLastID` clause → (b) examines 0
    /// and keeps the stale position.
    func testExtending_afterTruncationOrTailReplacement_fallsBackToFullScan() {
        var calls = (0..<64).map { _ in work() }
        calls[40] = ask()
        let full = AskCallIndex(toolCalls: calls)
        XCTAssertEqual(full.positions, [40], "anti-vacuum")

        // (a) truncation — the log-desync path (`TaskStreamStore` `prefix(keep)`).
        let truncated = Array(calls.prefix(10))
        AskCallIndexProbe.reset()
        let afterTruncation = AskCallIndex(toolCalls: truncated, extending: full)
        XCTAssertEqual(afterTruncation.positions, [], "the stale position 40 must not survive")
        XCTAssertEqual(AskCallIndexProbe.examined(), 10, "a full rescan of the shorter array")

        // (b) same count, last element replaced by a fresh call.
        var replaced = calls
        replaced[63] = ask()
        AskCallIndexProbe.reset()
        let afterReplacement = AskCallIndex(toolCalls: replaced, extending: full)
        XCTAssertEqual(AskCallIndexProbe.examined(), 64, "a changed tail id invalidates the whole index")
        XCTAssertEqual(afterReplacement.positions, [40, 63])
    }

    // MARK: - The writer set the boundary validation rests on

    /// `isPrefix(of:)` trusts `(count, last id)`. That is sound only while every
    /// writer of `StepExecution.toolCalls` appends, changes the count, or replays
    /// identical content — a writer that rewrote a prefix element's `name` or
    /// reordered in place would be invisible to it. The set is therefore CLOSED
    /// here, tree-wide (CLAUDE.md #51), in three scans over the app target:
    ///
    /// 1. Whole-array / whole-element writers spelled on the identifier
    ///    (`toolCalls = …`, `.append(`, `.remove…`, `toolCalls[i] = …`) AND every
    ///    `&…toolCalls` handed to an `inout` parameter — a generic helper such as
    ///    `TaskStreamStore.replayByID(_:into:index:)` mutates the array through a
    ///    parameter named `array`, which no identifier-based pattern can see; the
    ///    `&` at the call site is the only spelling that names it. Every match
    ///    must be a recorded site and every recorded site must still exist (a
    ///    moved writer is a changed set too).
    /// 2. Element-FIELD writers (`toolCalls[i].<field> = …`): the FIELD set must be
    ///    exactly `resultJSON` / `isError` / `argumentsJSON` — never `name` or `id`,
    ///    the two fields `isPrefix` reads — and the FILE set must be the recorded
    ///    four. A fifth `resultJSON` writer is harmless to the index but changes the
    ///    enumeration at `StepExecution.toolCalls`, so it is asked to record itself.
    /// 3. Positive controls on literal probe strings, so the anti-vacuum lives in
    ///    the test and never depends on a fixture line inside `NanoTeams/`.
    ///
    /// RED: add `task.runs[0].steps[0].toolCalls.removeFirst()` anywhere in the
    /// app target → scan 1 reports the new line; delete
    /// `TaskMutationService.appendToolCall`'s append → the recorded site is missing;
    /// add `toolCalls[0].name = "x"` anywhere in the app target → scan 2 reports
    /// `name` as a written field.
    func testToolCallsWriterSet_isClosed() throws {
        let root = RatchetSourceScan.repoRoot.appendingPathComponent("NanoTeams")
        let mutation = try NSRegularExpression(pattern:
            #"(?<![A-Za-z0-9_])toolCalls\s*(=(?!=)|\.append\(|\.insert\(|\.remove|\.popLast|\.sort|\.swapAt|\.replaceSubrange|\[[^\]]*\]\s*=(?!=))"#)
        // A lone `&` (not the `&&` operator) directly before the array's name.
        let inoutPass = try NSRegularExpression(pattern:
            #"(?<!&)&(?!&)\s*(?:[A-Za-z_][A-Za-z0-9_]*\.)*toolCalls\b"#)
        let fieldWrite = try NSRegularExpression(pattern:
            #"(?<![A-Za-z0-9_])toolCalls\[[^\]]*\]\.([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)"#)
        let declaration = try NSRegularExpression(pattern: #"\b(let|var)\s+toolCalls\b"#)

        // Positive controls — the patterns see the shapes they are for.
        func matches(_ regex: NSRegularExpression, _ probe: String) -> NSTextCheckingResult? {
            regex.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe))
        }
        XCTAssertNotNil(matches(inoutPass, "replayByID(t, into: &streams.toolCalls, index: &i)"),
                        "control: an inout pass of the array is a writer")
        XCTAssertNil(matches(inoutPass, "let n = streams.toolCalls.count"),
                     "control: a read is not")
        XCTAssertNil(matches(inoutPass, "wire.isEmpty && toolCalls.isEmpty && messages.isEmpty"),
                     "control: the `&&` operator is not an inout pass")
        let nameProbe = "x.toolCalls[i].name = y"
        let nameMatch = try XCTUnwrap(matches(fieldWrite, nameProbe), "control: a `name` rewrite is seen")
        XCTAssertEqual(
            (nameProbe as NSString).substring(with: nameMatch.range(at: 1)), "name",
            "control: the field is captured")
        XCTAssertNil(matches(fieldWrite, "if toolCalls[i].name == ToolNames.askSupervisor {"),
                     "control: a comparison is not a write")

        var found: Set<String> = []
        var fieldWrites: [(file: String, field: String)] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: RatchetSourceScan.repoRoot.path + "/", with: "")
            for line in RatchetSourceScan.strippingLineComments(source).components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                guard declaration.firstMatch(in: line, range: range) == nil else { continue }
                if mutation.firstMatch(in: line, range: range) != nil
                    || inoutPass.firstMatch(in: line, range: range) != nil
                {
                    found.insert("\(relative): \(line.trimmingCharacters(in: .whitespaces))")
                }
                for match in fieldWrite.matches(in: line, range: range) {
                    fieldWrites.append((relative, (line as NSString).substring(with: match.range(at: 1))))
                }
            }
        }

        // Scan 1 — the closed set. Each line says WHY it is compatible with boundary validation.
        let recorded: Set<String> = [
            // The ONLY appender.
            "NanoTeams/Services/Task/TaskMutationService.swift: task.runs[location.runIndex].steps[location.stepIndex].toolCalls.append(toolCall)",
            // Count changes.
            "NanoTeams/Domain/StepExecution.swift: toolCalls = []",
            "NanoTeams/Storage/TaskStreamStore.swift: streams.toolCalls = Array(streams.toolCalls.prefix(keep))",
            "NanoTeams/Storage/NTMSRepository+StreamSplit.swift: stripped.runs[r].steps[s].toolCalls = []",
            // Content-identical replay / construction. `replayByID` appends an unseen id and
            // overwrites a seen id IN PLACE with the later record for the SAME id — the id at
            // every position is unchanged, and no record can carry a different `name` for an
            // id because no writer below rewrites `name`.
            "NanoTeams/Storage/TaskStreamStore.swift: replayByID(t, into: &streams.toolCalls, index: &callIndex)",
            "NanoTeams/Storage/NTMSRepository+StreamSplit.swift: task.runs[r].steps[s].toolCalls = result.streams.toolCalls",
            "NanoTeams/Domain/StepExecution.swift: self.toolCalls = toolCalls",
            "NanoTeams/Domain/StepExecution.swift: self.toolCalls = try c.decodeIfPresent([StepToolCall].self, forKey: .toolCalls) ?? []",
            // Preview fixture, never a runtime writer.
            "NanoTeams/Views/TeamBoard/TeamBoardView+Previews.swift: s.toolCalls = toolCalls",
            // Same property NAME on other types (`ChatMessage.toolCalls`, a local tuple).
            "NanoTeams/Domain/ChatMessage.swift: self.toolCalls = toolCalls",
            "NanoTeams/Domain/ChatMessage.swift: case toolCalls = \"tool_calls\"",
            "NanoTeams/Domain/ChatMessage.swift: toolCalls = try container.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls)",
            "NanoTeams/Services/LLM/DelegatedSupervisorAnswerService.swift: captured.toolCalls = accumulator.finalize()",
            "NanoTeams/Services/LLM/DelegatedSupervisorAnswerService.swift: captured.toolCalls = HarmonyToolCallParser()",
        ]

        XCTAssertFalse(found.isEmpty, "anti-vacuum: the scan must see the recorded writers")
        let unrecorded = found.subtracting(recorded).sorted()
        XCTAssertTrue(unrecorded.isEmpty, """
        New writer(s) of `toolCalls` — `AskCallIndex.isPrefix` validates by (count, last id) \
        and is sound only for appends, count changes and identical replay. Adding a writer — \
        revisit `AskCallIndex.isPrefix`, then record the line here:
        \(unrecorded.joined(separator: "\n"))
        """)
        let missing = recorded.subtracting(found).sorted()
        XCTAssertTrue(missing.isEmpty, """
        Recorded writer(s) no longer found — the set moved; re-verify the invariant and update:
        \(missing.joined(separator: "\n"))
        """)

        // Scan 2 — element-field writers: which FIELDS, from which FILES.
        let writtenFields = Set(fieldWrites.map(\.field))
        let fieldWriterFiles = Set(fieldWrites.map(\.file))
        XCTAssertFalse(fieldWrites.isEmpty, "anti-vacuum: the scan must see the result-field writers")
        XCTAssertEqual(writtenFields, ["resultJSON", "isError", "argumentsJSON"], """
        A `toolCalls` element field outside `resultJSON` / `isError` / `argumentsJSON` is written \
        somewhere in the app target. `name` and `id` are what `AskCallIndex.isPrefix` reads — a \
        rewrite of either breaks (count, last id) validation. Written fields: \
        \(writtenFields.sorted()); sites: \(fieldWrites.map { "\($0.file): .\($0.field)" }.sorted())
        """)
        XCTAssertEqual(fieldWriterFiles, [
            "NanoTeams/Services/Task/TaskMutationService.swift",
            "NanoTeams/Services/LLM/LLMExecutionService+DelegateToTeam.swift",
            "NanoTeams/Services/Core/NTMSOrchestrator+TeamGeneration.swift",
            "NanoTeams/Services/Task/StatusRecoveryService.swift",
        ], """
        The files that write result fields of a `toolCalls` element changed — harmless to \
        `AskCallIndex`, but the enumeration at `StepExecution.toolCalls` names them; update both.
        """)
    }
}
