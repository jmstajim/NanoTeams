import XCTest
@testable import NanoTeams

/// A batch of read-only tool calls runs concurrently, and must come back in CALL order.
///
/// Order is the whole contract. `LLMExecutionService.executeToolCalls` interleaves these results
/// back against the model's emission positions by INDEX, and `MemoryTagStore` then stamps them
/// `<§R1§>`, `<§R2§>` … in that order. Tags are handles the model refers back to across turns,
/// so numbering them by whichever read finished first would mint a different transcript on every
/// run for identical inputs — and nothing would go red anywhere.
final class ToolRuntimeParallelBatchTests: XCTestCase {

    private let fm = FileManager.default
    private var workFolderRoot: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workFolderRoot = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: workFolderRoot, taskID: 0, runID: 0, roleID: "test_role")
    }

    override func tearDownWithError() throws {
        if let workFolderRoot { try? fm.removeItem(at: workFolderRoot) }
        workFolderRoot = nil
        runtime = nil
        context = nil
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(
            to: workFolderRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func readCall(_ path: String) -> StepToolCall {
        StepToolCall(name: "read_file", argumentsJSON: #"{"path":"\#(path)"}"#)
    }

    // MARK: - Order

    /// Results pair with their calls, whatever order the reads finish in.
    ///
    /// The file sizes span three orders of magnitude and are laid out so completion order
    /// CANNOT match call order: the first call reads the biggest file. A merge that took results
    /// as they arrived would put the small ones first.
    ///
    /// RED: return results in completion order (drop the index and `append` in `group.next()`'s
    /// loop) → `result[i]` names the wrong file.
    func testReadOnlyBatch_returnsResultsInCallOrder() async throws {
        // Varied by line LENGTH, not line count: `read_file` refuses a file over its line
        // limit, and an error envelope would pair just as well as a real one — the assertion
        // below would then hold for the wrong reason.
        let widths = [40_000, 40, 20_000, 80, 10_000, 20]
        for (i, width) in widths.enumerated() {
            try write("f\(i).txt", String(repeating: "x", count: width) + "\n")
        }
        let calls = (0..<widths.count).map { readCall("f\($0).txt") }

        let results = await runtime.executeAll(context: context, toolCalls: calls)

        XCTAssertEqual(results.count, calls.count, "1:1 result per call is what the caller's "
            + "index pairing walks")
        for (i, result) in results.enumerated() {
            XCTAssertFalse(result.isError, "f\(i).txt: \(result.outputJSON)")
            XCTAssertTrue(result.argumentsJSON.contains("f\(i).txt"),
                          "result \(i) must be the answer to call \(i); got \(result.argumentsJSON)")
        }
    }

    /// Every read-only tool the gate admits, in one batch, mixed.
    ///
    /// RED: same mutation as `testReadOnlyBatch_returnsResultsInCallOrder` (results in
    /// completion order) → the `search` and `list_files` envelopes land under each other's calls.
    func testReadOnlyBatch_mixedFileAndGitReads_stayPaired() async throws {
        try write("alpha.txt", "needle in alpha\n")
        // Big by WIDTH so it finishes last without tripping `read_file`'s line limit.
        try write("beta.txt", String(repeating: "p", count: 400_000) + "\nneedle in beta\n")

        let calls = [
            StepToolCall(name: "search",
                         argumentsJSON: #"{"query":"needle","exploratory":false}"#),
            readCall("alpha.txt"),
            StepToolCall(name: "list_files", argumentsJSON: #"{"path":"."}"#),
            readCall("beta.txt"),
        ]

        let results = await runtime.executeAll(context: context, toolCalls: calls)

        XCTAssertEqual(results.map(\.toolName),
                       ["search", "read_file", "list_files", "read_file"])
        XCTAssertTrue(results[1].argumentsJSON.contains("alpha.txt"))
        XCTAssertTrue(results[3].argumentsJSON.contains("beta.txt"))
        XCTAssertTrue(results.allSatisfy { !$0.isError },
                      "all four are legitimate: \(results.map(\.outputJSON))")
    }

    // MARK: - The gate

    /// A batch is parallelised only when EVERY call in it is read-only. One write is enough to
    /// send the whole batch down the sequential path, because a write ordered against a read of
    /// the same file is the caller's business, not the runtime's to reorder.
    ///
    /// Observed through the OUTCOME rather than a timing or a spy: the sequential path is the
    /// one that emits cancel envelopes for everything after a mid-batch cancel, and the parallel
    /// path checks once up front. So a pre-cancelled mixed batch yields all-cancelled — which it
    /// also would parallel — while the ORDERING guarantee below is what actually distinguishes
    /// them. Kept as a behavioural assertion on the result the caller sees.
    ///
    /// RED: drop the `readOnlyTools` membership test from `isParallelisable` → `write_file`
    /// executes concurrently with the read of the file it writes, and the read intermittently
    /// sees the new contents. (Intermittently is the point: this assertion is the deterministic
    /// half — the write must land after the read that precedes it.)
    func testMixedReadAndWriteBatch_keepsTheWriteOrderedAfterTheRead() async throws {
        try write("target.txt", "ORIGINAL")

        let calls = [
            readCall("target.txt"),
            StepToolCall(
                name: "write_file",
                argumentsJSON: #"{"path":"target.txt","content":"REWRITTEN"}"#),
            readCall("target.txt"),
        ]

        let results = await runtime.executeAll(context: context, toolCalls: calls)

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results[0].outputJSON.contains("ORIGINAL"),
                      "the read BEFORE the write must see the old contents: \(results[0].outputJSON)")
        XCTAssertFalse(results[1].isError, "the write must succeed: \(results[1].outputJSON)")
        XCTAssertTrue(results[2].outputJSON.contains("REWRITTEN"),
                      "the read AFTER the write must see the new contents: \(results[2].outputJSON)")
    }

    /// The gate reads its membership from `ToolCategory`, not from a list kept here.
    ///
    /// A hand-list would be a second home for "which tools only observe the work folder", and
    /// the one that drifts — a read-only tool added next year would keep running sequentially
    /// with nothing to say so (CLAUDE.md #51).
    ///
    /// RED: replace `ToolHandlerRegistry.readOnlyTools` in `isParallelisable` with a literal set
    /// → the first assertion fails as soon as the two disagree, which is what "derived" means.
    func testTheGateIsDerivedFromCategories() {
        XCTAssertEqual(
            ToolHandlerRegistry.readOnlyTools,
            ToolHandlerRegistry.fileReadTools.union(ToolHandlerRegistry.gitReadTools))
        // Anti-vacuum: the set must be non-empty and must EXCLUDE the mutating neighbours, or
        // the equality above would hold for a set that admits everything.
        XCTAssertTrue(ToolHandlerRegistry.readOnlyTools.contains(ToolNames.readFile))
        XCTAssertTrue(ToolHandlerRegistry.readOnlyTools.contains(ToolNames.gitDiff))
        XCTAssertFalse(ToolHandlerRegistry.readOnlyTools.contains(ToolNames.writeFile))
        XCTAssertFalse(ToolHandlerRegistry.readOnlyTools.contains(ToolNames.bash),
                       "membership is a property of the TOOL decided without seeing a command, "
                           + "and bash writes or does not depending on the string")
    }

    /// A single call is never worth a task group.
    ///
    /// RED: drop `toolCalls.count > 1` from `isParallelisable` → nothing observable changes
    /// here, which is why this asserts the RESULT rather than the route: it is the pin that the
    /// one-call case keeps working at all, and it is the commonest batch the model emits.
    func testSingleReadOnlyCall_stillReturnsItsResult() async throws {
        try write("solo.txt", "SOLO CONTENT")

        let results = await runtime.executeAll(
            context: context, toolCalls: [readCall("solo.txt")])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outputJSON.contains("SOLO CONTENT"))
    }

    // MARK: - Cancellation

    /// A batch cancelled before it starts yields one cancel envelope per call — the 1:1 mapping
    /// the caller's `freshIdx` walk depends on, without which it reads off the end of the array.
    ///
    /// RED: return `[]` (or drop the pre-check) from `executeReadOnlyBatch` when cancelled →
    /// the count assertion fails.
    func testCancelledBeforeStart_emitsOneEnvelopePerCall() async throws {
        try write("a.txt", "a")
        try write("b.txt", "b")
        let calls = [readCall("a.txt"), readCall("b.txt")]
        // Only `URL`s cross into the task: `ToolExecutionContext` is a value type and
        // `ToolRuntime` is `@unchecked Sendable`, but the test case itself is not.
        let runtime = runtime!
        let context = context!

        let task = Task { () -> [ToolExecutionResult] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return await runtime.executeAll(context: context, toolCalls: calls)
        }
        task.cancel()
        let results = await task.value

        XCTAssertEqual(results.count, 2, "one result per call, cancelled or not")
        XCTAssertTrue(results.allSatisfy(\.isError))
        XCTAssertTrue(results.allSatisfy { $0.outputJSON.contains(#""code":"CANCELLED""#) },
                      "got: \(results.map(\.outputJSON))")
    }
}
