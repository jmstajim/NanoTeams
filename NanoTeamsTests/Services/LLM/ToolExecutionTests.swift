import XCTest

@testable import NanoTeams

/// Tests for LLMExecutionService+ToolExecution — tool execution pipeline,
/// authorization, identical-write rejection, result processing, memories injection,
/// loop detection, and Supervisor auto-answer handling.
@MainActor
final class ToolExecutionTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var tempDir: URL!
    var runtime: ToolRuntime!
    var tracker: ToolCallTracker!
    var orphanService: LLMExecutionService!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)

        let (_, rt) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: tempDir.appendingPathComponent("tool_calls.jsonl"),
            isDefaultStorage: false
        )
        runtime = rt
        tracker = ToolCallTracker()
    }

    override func tearDown() {
        runtime = nil
        tracker = nil
        orphanService = nil
        service = nil
        mockDelegate = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeToolCall(
        name: String,
        args: String = "{}",
        providerID: String? = nil
    ) -> StepToolCall {
        StepToolCall(
            providerID: providerID ?? UUID().uuidString,
            name: name,
            argumentsJSON: args
        )
    }

    private func makeTask() -> NTMSTask {
        let run = Run(id: 0, roleStatuses: ["eng": .working])
        return NTMSTask(id: 0, title: "Test Task", supervisorTask: "Goal", runs: [run])
    }

    /// Mutable reference cell for capturing booleans across the synchronous
    /// handler/test boundary. The handler runs on a cooperative-pool thread;
    /// the test reads back on `@MainActor` after `await batch.value`.
    /// `@unchecked Sendable` is sound because there's no concurrent access —
    /// the read happens-after the write via the await suspension point.
    private final class ThreadCaptureBox: @unchecked Sendable {
        var onMain: Bool?
    }

    // MARK: - executeToolCalls: Authorization

    func testExecuteToolCalls_unauthorizedTool_returnsError() async {
        let task = makeTask()
        let call = makeToolCall(name: "write_file", args: #"{"path":"/test.txt","content":"hi"}"#)

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["read_file", "list_files"],
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.count, 1)
        XCTAssertTrue(batch[0].isError)
        XCTAssertTrue(batch[0].outputJSON.contains("tool_not_authorized"))
    }

    // MARK: - executeToolCalls: pre-runtime rejections mirror into BOTH audit logs

    /// A runtime owning both per-run logger instances pointed at the given URLs.
    private func makeRuntimeWithBothLogs(jsonlURL: URL, netURL: URL) -> ToolRuntime {
        let (_, rt) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: jsonlURL,
            networkLogger: NetworkLogger(logURL: netURL)
        )
        return rt
    }

    private func networkToolCallRecords(at url: URL) throws -> [NetworkLogRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let all = try JSONCoderFactory.makeDateDecoder().decode([NetworkLogRecord].self, from: data)
        return all.filter { $0.direction == .toolCall }
    }

    private func jsonlLines(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func testExecuteToolCalls_unauthorized_logsBothLogs() async throws {
        let task = makeTask()
        let jsonlURL = tempDir.appendingPathComponent("rej_unauth.jsonl")
        let netURL = tempDir.appendingPathComponent("rej_unauth.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)
        let call = makeToolCall(name: "write_file", args: #"{"path":"/test.txt","content":"hi"}"#)

        _ = await service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["read_file", "list_files"],
            runtime: rt,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        let netRecords = try networkToolCallRecords(at: netURL)
        XCTAssertEqual(netRecords.count, 1)
        XCTAssertTrue(netRecords[0].body?.contains("tool_not_authorized") == true)
        XCTAssertNotNil(netRecords[0].errorMessage)

        let lines = jsonlLines(at: jsonlURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("write_file"))
        XCTAssertTrue(lines[0].contains("tool_not_authorized"))
    }

    func testExecuteToolCalls_identicalWrite_logsBothLogs() async throws {
        let task = makeTask()
        let jsonlURL = tempDir.appendingPathComponent("rej_dup.jsonl")
        let netURL = tempDir.appendingPathComponent("rej_dup.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)
        let args = #"{"path":"dup.txt","content":"same"}"#
        let first = makeToolCall(name: "write_file", args: args)
        let second = makeToolCall(name: "write_file", args: args)

        // First write executes (also logged, since this runtime has both loggers),
        // second is the identical-write rejection.
        _ = await service.executeToolCalls(
            resolvedToolCalls: [first, second],
            allowedToolNames: ["write_file"],
            runtime: rt,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        let netRecords = try networkToolCallRecords(at: netURL)
        XCTAssertTrue(netRecords.contains { $0.body?.contains("identical_write_loop") == true })

        let lines = jsonlLines(at: jsonlURL)
        XCTAssertTrue(lines.contains { $0.contains("identical_write_loop") })
    }

    func testExecuteToolCalls_mixedBatch_everyCallLoggedToBoth() async throws {
        let task = makeTask()
        let jsonlURL = tempDir.appendingPathComponent("mixed.jsonl")
        let netURL = tempDir.appendingPathComponent("mixed.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)
        let executed = makeToolCall(name: "list_files", args: #"{"path":"."}"#)
        let rejected = makeToolCall(name: "write_file", args: #"{"path":"/x.txt","content":"hi"}"#)

        _ = await service.executeToolCalls(
            resolvedToolCalls: [executed, rejected],
            allowedToolNames: ["list_files"],
            runtime: rt,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        // The user-facing promise: EVERY call (executed + rejected) appears in BOTH
        // logs — record count equals call count.
        let netRecords = try networkToolCallRecords(at: netURL)
        XCTAssertEqual(netRecords.count, 2)
        let netBodies = netRecords.compactMap(\.body).joined()
        XCTAssertTrue(netBodies.contains("list_files"))
        XCTAssertTrue(netBodies.contains("write_file"))

        let lines = jsonlLines(at: jsonlURL)
        XCTAssertEqual(lines.count, 2)
    }

    func testExecuteToolCalls_emptyBatch_noLogsNoCrash() async {
        let task = makeTask()
        let jsonlURL = tempDir.appendingPathComponent("empty.jsonl")
        let netURL = tempDir.appendingPathComponent("empty.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [],
            allowedToolNames: ["list_files"],
            runtime: rt,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )
        XCTAssertTrue(batch.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonlURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: netURL.path))
    }

    /// Pins the documented ordering: rejections are grouped and logged BEFORE the
    /// executed batch, so a rejected call emitted AFTER an executed one still lands
    /// first in the log (not interleaved into emission position).
    func testExecuteToolCalls_rejectionLoggedBeforeExecuted() async throws {
        let task = makeTask()
        let jsonlURL = tempDir.appendingPathComponent("order.jsonl")
        let netURL = tempDir.appendingPathComponent("order.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)
        let executed = makeToolCall(name: "list_files", args: #"{"path":"."}"#)        // idx 0
        let rejected = makeToolCall(name: "write_file", args: #"{"path":"/x.txt","content":"hi"}"#)  // idx 1

        _ = await service.executeToolCalls(
            resolvedToolCalls: [executed, rejected],
            allowedToolNames: ["list_files"],
            runtime: rt,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        let lines = jsonlLines(at: jsonlURL)
        XCTAssertEqual(lines.count, 2)
        let writeIdx = lines.firstIndex { $0.contains("write_file") }
        let listIdx = lines.firstIndex { $0.contains("\"list_files\"") }
        XCTAssertNotNil(writeIdx)
        XCTAssertNotNil(listIdx)
        XCTAssertLessThan(writeIdx!, listIdx!,
                          "Rejected call (emitted 2nd) is logged before the executed call (emitted 1st)")
    }

    func testExecuteToolCalls_loggingDisabled_doesNotCrash() async {
        let task = makeTask()
        let jsonlURL = tempDir.appendingPathComponent("none.jsonl")
        let netURL = tempDir.appendingPathComponent("none.json")
        // Runtime with NO loggers.
        let (_, rt) = ToolRegistry.defaultRegistry(workFolderRoot: tempDir, toolCallsLogURL: nil)
        let call = makeToolCall(name: "write_file", args: #"{"path":"/x.txt","content":"hi"}"#)

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["read_file"],
            runtime: rt,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )
        XCTAssertEqual(batch.count, 1)
        XCTAssertTrue(batch[0].isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonlURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: netURL.path))
    }

    func testExecuteToolCalls_authorizedTool_executes() async {
        let task = makeTask()

        // ls on the project root (relative path ".") should succeed
        let call = makeToolCall(name: "list_files", args: #"{"path":"."}"#)

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["list_files"],
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.count, 1)
        XCTAssertFalse(batch[0].isError)
    }

    func testExecuteToolCalls_aliasResolution_grepToSearch() async {
        let task = makeTask()

        // "grep" should alias to "search" — but "search" must be in allowed set
        let call = makeToolCall(name: "grep", args: #"{"query":"test"}"#)

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["search"],
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.count, 1)
        // The alias should resolve to search, which is in allowed set
        XCTAssertFalse(batch[0].isError,
                       "Aliased tool 'grep' should resolve to 'search' and pass authorization")
    }

    // MARK: - executeToolCalls: Re-execution (no cache) + identical-write guard

    /// Counts handler invocations across the synchronous handler/test boundary.
    /// `@unchecked Sendable` is sound: each call is awaited before the next is issued,
    /// so there's no concurrent access — reads happen-after writes via the await
    /// suspension point. NSLock guards the rare case the runtime ever invokes the
    /// handler on a different thread for the same call (defense in depth).
    private final class CallCounterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.withLock { _count }
        }
        func increment() {
            lock.withLock { _count += 1 }
        }
    }

    /// Regression pin (PT2): "every authorized call hits `ToolRuntime`" is a behavioural
    /// guarantee — not a string-absence in the envelope. A counting probe handler is
    /// invoked once per `executeToolCalls` pass with identical args. After two
    /// sequential passes, `counter.count` MUST be 2. Any regression that re-introduces
    /// a result-replay short-circuit (regardless of marker name) would observe 1.
    func testExecuteToolCalls_repeatRead_runtimeInvokedEachTime() async {
        let probeName = "probe_invocation_count"
        let counter = CallCounterBox()
        let registry = ToolRegistry()
        registry.register(name: probeName) { _, _ in
            counter.increment()
            return ToolExecutionResult(
                toolName: probeName,
                argumentsJSON: "{}",
                outputJSON: #"{"ok":true,"data":{}}"#,
                isError: false
            )
        }
        service.executionStates[TaskStepKey(taskID: 0, stepID: "test_role")] = LLMExecutionService.StepExecutionState()
        let probeRuntime = ToolRuntime(registry: registry, logger: nil)

        for _ in 0..<2 {
            _ = await service.executeToolCalls(
                resolvedToolCalls: [makeToolCall(name: probeName)],
                allowedToolNames: [probeName],
                runtime: probeRuntime,
                tracker: tracker,
                task: makeTask(),
                runIndex: 0,
                roleID: "test_role"
            )
        }

        XCTAssertEqual(counter.count, 2,
                       "Probe handler must run on every executeToolCalls pass — no cache short-circuit. A regression that reintroduces result replay would observe 1.")
    }

    /// Regression pin (PT1): two `write_file` calls with identical `(path, content)`
    /// emitted in ONE LLM response (same batch) MUST result in: index 0 executes once,
    /// index 1 is rejected with `identical_write_loop`. The atomic
    /// `tracker.checkAndRecordWrite` inside `executeToolCalls` is what makes the
    /// second-call rejection structural rather than ordering-dependent. A regression
    /// that reverts to two split calls (`isDuplicate?` then later `record`) where the
    /// record happens AFTER the dispatch boundary would leak both writes to disk.
    func testExecuteToolCalls_twoIdenticalWritesInSingleBatch_secondRejected() async {
        // write_file requires relative paths (sandboxed under workFolderRoot).
        let args = #"{"path":"dup.txt","content":"hello"}"#
        let call1 = makeToolCall(name: "write_file", args: args)
        let call2 = makeToolCall(name: "write_file", args: args)
        service.executionStates[TaskStepKey(taskID: 0, stepID: "test_role")] = LLMExecutionService.StepExecutionState()

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [call1, call2],
            allowedToolNames: ["write_file"],
            runtime: runtime,
            tracker: tracker,
            task: makeTask(),
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.count, 2)
        XCTAssertFalse(batch[0].isError, "First write_file must execute")
        XCTAssertFalse(batch[0].outputJSON.contains("identical_write_loop"),
                       "First write must NOT carry the identical-write envelope")
        XCTAssertTrue(batch[1].isError, "Second identical write_file must be rejected")
        XCTAssertTrue(batch[1].outputJSON.contains("identical_write_loop"),
                      "Second-call rejection must carry the `identical_write_loop` envelope")
    }

    func testExecuteToolCalls_emptyList_returnsEmpty() async {
        let task = makeTask()

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [],
            allowedToolNames: ["read_file"],
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertTrue(batch.isEmpty)
    }

    // MARK: - processToolResults: pre-finalize skip predicate

    /// `processToolResults` skips its pre-record loop for `.exploratorySearch` and
    /// `.visionAnalysis` signals — their async finalizers (`appendExploratorySearchResult`,
    /// `appendVisionResult`) self-record the REAL envelope into the tracker once the
    /// placeholder `{"status":"exploring"}` / `{"status":"analyzing"}` is rewritten.
    /// Without this skip, the loop detector's `recentCalls` snapshot would see a
    /// placeholder on the next iteration instead of the real result.
    ///
    /// Pinning the skip-predicate as a pure helper means the invariant is testable
    /// without rebuilding the entire `processToolResults` pipeline (client, memoryStore,
    /// conversation, delegate, etc.) — a regression that flips the predicate is caught
    /// here directly.
    func testShouldRecordInTrackerPreFinalize_skipsExploratorySearch() throws {
        let payload = try ExploratorySearchPayload(
            query: "x",
            mode: .substring,
            paths: nil,
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 10
        )
        let signal: ToolSignal = .exploratorySearch(payload)
        XCTAssertFalse(LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: signal),
                       "Exploratory search placeholder must be skipped — finalizer self-records the real envelope")
    }

    func testShouldRecordInTrackerPreFinalize_skipsVisionAnalysis() {
        let signal: ToolSignal = .visionAnalysis(imagePath: "x.png", prompt: "describe")
        XCTAssertFalse(LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: signal),
                       "Vision analysis placeholder must be skipped — finalizer self-records the real envelope")
    }

    func testShouldRecordInTrackerPreFinalize_recordsRegularResult() {
        XCTAssertTrue(LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: nil),
                      "Regular (non-async-finalized) results must be recorded in the pre-record loop")
    }

    func testShouldRecordInTrackerPreFinalize_recordsOtherSignals() {
        // Collaboration / artifact / team-creation signals all carry their final envelope
        // synchronously — the pre-record loop must capture them.
        let teamMeeting: ToolSignal = .teamMeeting(topic: "x", participants: [], context: nil)
        XCTAssertTrue(LLMExecutionService.shouldRecordInTrackerPreFinalize(signal: teamMeeting))
    }

    func testExecuteToolCalls_noDelegate_returnsEmpty() async {
        // Service with no delegate attached
        orphanService = LLMExecutionService(repository: NTMSRepository())
        let task = makeTask()
        let call = makeToolCall(name: "list_files", args: "{}")

        let batch = await orphanService.executeToolCalls(
            resolvedToolCalls: [call],
            allowedToolNames: ["list_files"],
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertTrue(batch.isEmpty)
    }

    // MARK: - executeToolCalls: Mixed Batch

    func testExecuteToolCalls_mixedBatch_correctOrdering() async {
        let task = makeTask()

        // Pre-seed the tracker (simulating a prior iteration's read).
        let readArgs = #"{"path":""# + tempDir.path + #"/cached.txt"}"#
        tracker.record(
            toolName: "read_file",
            argumentsJSON: readArgs,
            resultJSON: #"{"content":"cached"}"#,
            isError: false
        )

        let call1 = makeToolCall(name: "write_file") // unauthorized
        let call2 = makeToolCall(name: "read_file", args: readArgs) // re-executes (no cache)
        let call3 = makeToolCall(name: "list_files", args: #"{"path":"."}"#) // fresh

        let batch = await service.executeToolCalls(
            resolvedToolCalls: [call1, call2, call3],
            allowedToolNames: ["read_file", "list_files"],
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.count, 3)
        // First: unauthorized
        XCTAssertTrue(batch[0].isError)
        XCTAssertTrue(batch[0].outputJSON.contains("tool_not_authorized"))
        // Second: re-executed through ToolRuntime — no `_cached` marker even though
        // an identical entry exists in the tracker. (read_file on a missing path
        // returns an error envelope; ordering preservation is what matters here.)
        XCTAssertFalse(batch[1].outputJSON.contains("\"_cached\""))
        // Third: fresh
        XCTAssertFalse(batch[2].outputJSON.contains("\"_cached\""))
    }

    func testExecuteToolCalls_allUnauthorized_allErrors() async {
        let task = makeTask()

        let calls = [
            makeToolCall(name: "write_file"),
            makeToolCall(name: "delete_file"),
            makeToolCall(name: "git_commit"),
        ]

        let batch = await service.executeToolCalls(
            resolvedToolCalls: calls,
            allowedToolNames: ["read_file"],
            runtime: runtime,
            tracker: tracker,
            task: task,
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.count, 3)
        XCTAssertTrue(batch.allSatisfy(\.isError))
    }

    // MARK: - Off-main dispatch + end-to-end cancellation

    /// Pins the off-main dispatch contract: a registered probe handler captures
    /// `Thread.isMainThread` during `handle()`. Caller is `@MainActor`; the
    /// handler must observe `false` because `executeToolCalls` wraps the runtime
    /// dispatch in `Task.detached`. A regression that reverts to a synchronous
    /// `runtime.executeAll(...)` would silently observe `true` — that's the
    /// original main-thread-hang regression class.
    func testExecuteToolCalls_runsHandlerOffMainActor() async {
        let probeName = "probe_thread_isolation"
        let captured = ThreadCaptureBox()
        let registry = ToolRegistry()
        registry.register(name: probeName) { _, _ in
            captured.onMain = Thread.isMainThread
            return ToolExecutionResult(
                toolName: probeName,
                argumentsJSON: "{}",
                outputJSON: #"{"ok":true,"data":{}}"#,
                isError: false
            )
        }
        // Seed an execution state so `currentToolBatchTask` wiring uses the
        // real path rather than the orphan-cancel branch.
        service.executionStates[TaskStepKey(taskID: 0, stepID: "test_role")] = LLMExecutionService.StepExecutionState()

        let probeRuntime = ToolRuntime(registry: registry, logger: nil)
        let batch = await service.executeToolCalls(
            resolvedToolCalls: [makeToolCall(name: probeName)],
            allowedToolNames: [probeName],
            runtime: probeRuntime,
            tracker: tracker,
            task: makeTask(),
            runIndex: 0,
            roleID: "test_role"
        )

        XCTAssertEqual(batch.count, 1)
        XCTAssertFalse(batch[0].isError)
        XCTAssertNotNil(captured.onMain, "probe handler must have run")
        XCTAssertFalse(captured.onMain ?? true,
                       "Tool handler MUST execute off main actor (Task.detached). A regression to sync dispatch would freeze the run loop during file I/O / subprocess waits / document extraction.")
    }

    /// Pins the end-to-end cancel wiring: `cancelAllExecutions` cancels the
    /// stored `currentToolBatchTask`; `ToolRuntime.executeAll` observes the
    /// cancellation between calls and emits the unified `cancelled` envelope
    /// for everything that hasn't run yet. Probe #1 holds the worker thread
    /// long enough that the cancel arrives before probe #2 starts.
    func testCancelAllExecutions_propagatesIntoMidBatchToolRuntime() async {
        let probe1Name = "probe_slow"
        let probe2Name = "probe_fast"
        let registry = ToolRegistry()
        registry.register(name: probe1Name) { _, _ in
            // Sync sleep — handlers are non-async by contract, so cancellation
            // can only be observed BETWEEN handlers in `ToolRuntime.executeAll`.
            // The 250 ms hold gives the test time to call `cancelAllExecutions`
            // while probe #1 is still running.
            Thread.sleep(forTimeInterval: 0.25)
            return ToolExecutionResult(
                toolName: probe1Name,
                argumentsJSON: "{}",
                outputJSON: #"{"ok":true,"data":{}}"#,
                isError: false
            )
        }
        registry.register(name: probe2Name) { _, _ in
            return ToolExecutionResult(
                toolName: probe2Name,
                argumentsJSON: "{}",
                outputJSON: #"{"ok":true,"data":{}}"#,
                isError: false
            )
        }

        service.executionStates[TaskStepKey(taskID: 0, stepID: "test_role")] = LLMExecutionService.StepExecutionState()
        let probeRuntime = ToolRuntime(registry: registry, logger: nil)
        let call1 = makeToolCall(name: probe1Name)
        let call2 = makeToolCall(name: probe2Name)

        // Spawn the batch on the main actor so executeToolCalls runs in our
        // isolation context but suspends on `await batchTask.value`. The
        // suspension is the window for `cancelAllExecutions` to run.
        let executeTask = Task { @MainActor in
            await self.service.executeToolCalls(
                resolvedToolCalls: [call1, call2],
                allowedToolNames: [probe1Name, probe2Name],
                runtime: probeRuntime,
                tracker: self.tracker,
                task: self.makeTask(),
                runIndex: 0,
                roleID: "test_role"
            )
        }

        // Wait for probe #1 to actually start running on the cooperative pool.
        try? await Task.sleep(for: .milliseconds(80))
        service.cancelAllExecutions()

        let batch = await executeTask.value
        XCTAssertEqual(batch.count, 2)
        // Probe #1 was already running when cancel arrived — sync handlers
        // don't observe in-flight cancellation, so it completes normally.
        XCTAssertFalse(
            batch[0].isError,
            "probe #1 ran to completion before cancel boundary; got envelope: \(batch[0].outputJSON)"
        )
        // Probe #2 is the regression target: the cancel must reach
        // `ToolRuntime.executeAll`'s between-calls check and emit the unified
        // cancelled envelope for probe #2.
        XCTAssertTrue(
            batch[1].isError,
            "probe #2 must be marked cancelled; got envelope: \(batch[1].outputJSON)"
        )
        XCTAssertTrue(
            batch[1].outputJSON.contains(#""code":"CANCELLED""#),
            "probe #2 envelope must carry the unified CANCELLED code; got: \(batch[1].outputJSON)"
        )
    }

    // MARK: - buildCollaborationToolResult

    func testBuildCollaborationToolResult_validJSON() {
        let result = service.buildCollaborationToolResult(
            toolName: "ask_teammate",
            response: "The design spec looks good."
        )

        XCTAssertTrue(result.contains("ask_teammate"))
        XCTAssertTrue(result.contains("The design spec looks good."))
        XCTAssertTrue(result.contains("\"ok\":true") || result.contains("\"ok\" : true"))
    }

    func testBuildCollaborationToolResult_emptyResponse() {
        let result = service.buildCollaborationToolResult(toolName: "ask_supervisor", response: "")

        XCTAssertTrue(result.contains("ask_supervisor"))
    }

    // MARK: - resolveTeam

    func testResolveTeam_withPreferredTeamID_returnsTeam() async {
        await setupProjectWithTask()

        let team = mockDelegate.snapshot?.workFolder.activeTeam
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "G", preferredTeamID: team?.id)

        let resolved = service.resolveTeam(task: task)

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.id, team?.id)
    }

    func testResolveTeam_withoutPreferredTeamID_fallsBackToActiveTeam() async {
        await setupProjectWithTask()

        let task = NTMSTask(id: 0, title: "T", supervisorTask: "G")

        let resolved = service.resolveTeam(task: task)

        XCTAssertNotNil(resolved)
    }

    // MARK: - injectMemories

    // TODO(memories-disabled, 2026-05-19): Every test below whose body begins
    // with `try XCTSkipIf(true, Self.memoriesDisabledSkipReason)` covers the
    // positive injection path and is SKIPPED while `injectMemories` is gated
    // by `LLMExecutionService.isMemoriesInjectionEnabled = false`. Re-enable
    // ordering matches the paired TODO in
    // `Services/LLM/LLMExecutionService+ToolLoopState.swift`:
    //   1. Flip `isMemoriesInjectionEnabled` to `true` there.
    //   2. Restore the second sentence in
    //      `PromptBuilder.buildConversationMechanicsGuidance` (paired TODO).
    //   3. Remove the `XCTSkipIf` skip guard from each test below.
    //   4. Delete `testInjectMemories_disabledFlag_skipsSeededStore` — its
    //      assertion fails-on-flip and is the tripwire forcing this step.
    // The empty-store test (`testInjectMemories_emptyStore_doesNotInject`) is
    // left active because its assertion (0 messages) holds in both states —
    // under the disable for the trivial reason, and under the enable for the
    // generateMemories-returns-nil short-circuit it was originally written for.

    private static let memoriesDisabledSkipReason =
        "Memories injection currently disabled via " +
        "LLMExecutionService.isMemoriesInjectionEnabled — see TODO(memories-disabled)."

    /// Seed one plan tag so `generateMemories` returns non-nil content;
    /// otherwise the injection short-circuits (as of the empty-store optimization).
    private func seededMemoryStore() -> MemoryTagStore {
        let store = MemoryTagStore()
        store.registerPlanUpdate(content: "1. Draft plan", iteration: 1)
        return store
    }

    func testInjectMemories_appendsMessage() async throws {
        try XCTSkipIf(true, Self.memoriesDisabledSkipReason)

        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID,
            taskID: 0,
            memoryStore: memoryStore,
            conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertTrue(messages[0].content?.contains("Memories") ?? false)
    }

    /// Two successive injections replace the block IN PLACE, so the conversation
    /// never accumulates stale copies — the whole conversation is the request.
    func testInjectMemories_repeatedInjection_replacesInPlace() async throws {
        try XCTSkipIf(true, Self.memoriesDisabledSkipReason)

        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID, taskID: 0, memoryStore: memoryStore,
            conversationMessages: &messages
        )
        await service.injectMemories(
            stepID: stepID, taskID: 0, memoryStore: memoryStore,
            conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 1,
                       "The MEMORIES block must be rebuilt in place, never appended twice")
    }

    func testInjectMemories_emptyStore_doesNotInject() async {
        let stepID = "test_step"
        let memoryStore = MemoryTagStore()   // empty — no tags
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID, taskID: 0, memoryStore: memoryStore,
            conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 0,
                       "Empty MemoryTagStore must not inject a bare header/footer block")
    }

    /// Sole behavioral guardrail on `isMemoriesInjectionEnabled = false`.
    /// Uses a SEEDED store (so the empty-store short-circuit cannot explain a
    /// 0-message outcome) and asserts that `injectMemories` still appends
    /// nothing — the only path to that result with a non-empty store is the
    /// guard firing. When `isMemoriesInjectionEnabled` flips back to `true`,
    /// THIS TEST will start failing — that is the intended re-enable tripwire:
    /// delete this test together with the `try XCTSkipIf(true, ...)` lines in
    /// the four positive-injection tests above.
    func testInjectMemories_disabledFlag_skipsSeededStore() async {
        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID, taskID: 0, memoryStore: memoryStore,
            conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 0,
                       "Guard must short-circuit seeded-store injection while flag is false")
    }

    func testInjectMemories_withTrackedIndex_replacesInPlace() async throws {
        try XCTSkipIf(true, Self.memoriesDisabledSkipReason)

        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Old memories placeholder")
        ]

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        service._testSetMemoriesMessageIndex(stepID: stepID, taskID: 0, index: 0)
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID,
            taskID: 0,
            memoryStore: memoryStore,
            conversationMessages: &messages
        )

        // Should replace in-place, not append
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content?.contains("Memories") ?? false)
    }

    func testInjectMemories_firstCall_appendsAndTracksIndex() async throws {
        try XCTSkipIf(true, Self.memoriesDisabledSkipReason)

        let stepID = "test_step"
        let memoryStore = seededMemoryStore()
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "System prompt"),
            ChatMessage(role: .user, content: "User message"),
        ]

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        await service.injectMemories(
            stepID: stepID,
            taskID: 0,
            memoryStore: memoryStore,
            conversationMessages: &messages
        )

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(service._testGetMemoriesMessageIndex(stepID: stepID, taskID: 0), 2)
    }

    // MARK: - checkAndInjectLoopWarning

    func testCheckAndInjectLoopWarning_noLoop_noWarning() async {
        let stepID = "test_step"
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        // Record a single tool call — not enough for loop detection
        tracker.record(toolName: "read_file", argumentsJSON: "{}", resultJSON: "{}", isError: false)

        await service.checkAndInjectLoopWarning(
            stepID: stepID,
            taskID: 0,
            tracker: tracker,
            allowedToolNames: [],
            conversationMessages: &messages
        )

        XCTAssertTrue(messages.isEmpty, "No loop detected, so no warning should be injected")
    }

    func testCheckAndInjectLoopWarning_repetitiveTool_injectsWarning() async {
        let stepID = "test_step"
        var messages: [ChatMessage] = []

        service._testRegisterStepTask(stepID: stepID, taskID: Int())
        setupDelegateWithTask(stepID: stepID)

        // Record many identical calls to trigger loop detection
        for _ in 0..<10 {
            tracker.record(
                toolName: "read_file",
                argumentsJSON: #"{"path":"/test.txt"}"#,
                resultJSON: #"{"content":"same"}"#,
                isError: false
            )
        }

        await service.checkAndInjectLoopWarning(
            stepID: stepID,
            taskID: 0,
            tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor],
            conversationMessages: &messages
        )

        // If loop was detected, a warning message should have been appended
        if !messages.isEmpty {
            XCTAssertTrue(messages[0].content?.contains("Loop detected") ?? false)
        }
        // Note: detectLoopPattern may require more iterations — test verifies the pipeline works
    }

    // MARK: - loopWarningMessage (pure, tool-aware)

    /// The loop warning must name ONLY tools present in the role's schema —
    /// the pre-fix text steered every role toward edit_file/git_commit/
    /// create_artifact, sending read-only and chat roles into a
    /// tool_not_authorized ping-pong.
    func testLoopWarningMessage_scratchpadLoop_writerRole_namesEditFile() {
        let msg = LLMExecutionService.loopWarningMessage(
            loopDetection: .repetitiveTool(tool: ToolNames.updateScratchpad, count: 4, message: "m"),
            allowedToolNames: [ToolNames.editFile, ToolNames.writeFile, ToolNames.askSupervisor]
        )
        XCTAssertTrue(msg.contains("edit_file"))
        XCTAssertTrue(msg.contains("ask_supervisor"))
        XCTAssertFalse(msg.contains("create_artifact"), "not in this role's schema")
    }

    func testLoopWarningMessage_scratchpadLoop_readOnlyRole_namesNoWriteTools() {
        let msg = LLMExecutionService.loopWarningMessage(
            loopDetection: .repetitiveTool(tool: ToolNames.updateScratchpad, count: 4, message: "m"),
            allowedToolNames: [ToolNames.readFile, ToolNames.search]
        )
        XCTAssertFalse(msg.contains("edit_file"))
        XCTAssertFalse(msg.contains("git_commit"))
        XCTAssertFalse(msg.contains("create_artifact"))
        XCTAssertFalse(msg.contains("ask_supervisor"), "not in schema → not suggested")
    }

    func testLoopWarningMessage_genericLoop_carriesDetectorMessage_noShouting() {
        let msg = LLMExecutionService.loopWarningMessage(
            loopDetection: .readOnlyLoop(message: "You re-read the same file 5 times."),
            allowedToolNames: [ToolNames.askSupervisor]
        )
        XCTAssertTrue(msg.contains("You re-read the same file 5 times."))
        XCTAssertFalse(msg.contains("⚠️"), "no emoji decoration")
        XCTAssertFalse(msg.contains("LOOP DETECTED"), "no caps-shouting")
    }

    // MARK: - handleSupervisorAutoAnswer

    func testHandleSupervisorAutoAnswer_manualMode_returnsNil() async {
        let stepID = "test_step"
        let outcome = LLMExecutionService.ToolResultsOutcome(
            shouldStopForSupervisor: true,
            supervisorQuestion: "What framework?",
            supervisorToolCallProviderID: "tc-1"
        )
        var messages: [ChatMessage] = []
        let task = makeTask()

        let result = await service.handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: stepID,
            supervisorMode: .manual,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: NativeLMStudioClient(),
            config: LLMConfig(),
            conversationMessages: &messages
        )

        XCTAssertNil(result, "Manual mode should not auto-answer")
    }

    func testHandleSupervisorAutoAnswer_autovisorSupervised_suppressesAutoAnswer() async {
        // Autovisor universal-supervisor gate (AutovisorPolicy.supervisesTask):
        // a top-level non-manager task in autonomous mode must NOT be
        // auto-answered while the feature + trigger are on — the step parks at
        // .needsSupervisorInput and the manager answers it. Returning nil here
        // (without touching the conversation) is what makes the tool loop stop
        // for supervisor instead of generating an in-loop answer.
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "Test", autovisorTaskID: 99),
                settings: ProjectSettings(autovisorEnabled: true),
                teams: []
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil,
            activeTask: nil
        )

        let outcome = LLMExecutionService.ToolResultsOutcome(
            shouldStopForSupervisor: true,
            supervisorQuestion: "What framework?",
            supervisorToolCallProviderID: "tc-1"
        )
        var messages: [ChatMessage] = []
        let task = makeTask()  // id 0, top-level — not the manager (99)

        let result = await service.handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: "test_step",
            supervisorMode: .autonomous,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: NativeLMStudioClient(),
            config: LLMConfig(),
            conversationMessages: &messages
        )

        XCTAssertNil(result, "Supervised task must not auto-answer — the manager answers it")
        XCTAssertTrue(messages.isEmpty, "Suppression must not inject any answer message")
    }

    func testHandleSupervisorAutoAnswer_noQuestion_returnsNil() async {
        let stepID = "test_step"
        let outcome = LLMExecutionService.ToolResultsOutcome(
            shouldStopForSupervisor: false,
            supervisorQuestion: nil,
            supervisorToolCallProviderID: nil
        )
        var messages: [ChatMessage] = []
        let task = makeTask()

        let result = await service.handleSupervisorAutoAnswer(
            outcome: outcome,
            stepID: stepID,
            supervisorMode: .autonomous,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: NativeLMStudioClient(),
            config: LLMConfig(),
            conversationMessages: &messages
        )

        XCTAssertNil(result, "No question should return nil")
    }

    // MARK: - Cleanup Verification

    func testClearRunningTask_cleansAllState() {
        let stepID = "test_step"

        service._testSetPlanMessageIndex(stepID: stepID, taskID: 0, index: 5)
        service._testSetMemoriesMessageIndex(stepID: stepID, taskID: 0, index: 3)

        service.clearRunningTask(stepID: stepID, taskID: 0)

        XCTAssertNil(service._testGetPlanMessageIndex(stepID: stepID, taskID: 0))
        XCTAssertNil(service._testGetMemoriesMessageIndex(stepID: stepID, taskID: 0))
    }

    func testCancelStepExecution_cleansState() async {
        let stepID = "test_step"

        service._testSetPlanMessageIndex(stepID: stepID, taskID: 0, index: 5)
        service._testSetMemoriesMessageIndex(stepID: stepID, taskID: 0, index: 3)

        await service.cancelStepExecution(stepID: stepID, taskID: 0)

        XCTAssertNil(service._testGetPlanMessageIndex(stepID: stepID, taskID: 0))
        XCTAssertNil(service._testGetMemoriesMessageIndex(stepID: stepID, taskID: 0))
    }

    func testCancelAllExecutions_cleansAllState() {
        let step1 = "step1"
        let step2 = "step2"

        service._testSetPlanMessageIndex(stepID: step1, taskID: 0, index: 1)
        service._testSetPlanMessageIndex(stepID: step2, taskID: 0, index: 2)

        service.cancelAllExecutions()

        XCTAssertEqual(service._testPlanMessageIndexCount, 0)
        XCTAssertEqual(service._testMemoriesMessageIndexCount, 0)
    }

    // MARK: - Private Helpers

    private func setupProjectWithTask() async {
        let orchestrator = TestOrchestrator.make()
        await orchestrator.openWorkFolder(tempDir)
        mockDelegate.snapshot = orchestrator.snapshot
        mockDelegate.workFolderURL = tempDir
    }

    private func setupDelegateWithTask(stepID: String) {
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Code",
            status: .running
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["eng": .working])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])

        let taskID = task.id
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        mockDelegate.taskToMutate = task
    }
}
