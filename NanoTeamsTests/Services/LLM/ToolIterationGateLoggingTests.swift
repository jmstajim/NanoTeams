import XCTest

@testable import NanoTeams

/// C2 (KNOWN_ISSUES, 2026-09-07): a call the approval gates refused — `bash` under a policy
/// with nobody to approve it, a computer-use action denied by rule or judge — was built
/// BEFORE `ToolRuntime`, the only writer of `tool_calls.jsonl` and of the `.toolCall`
/// records in `network_log.jsonl`. `runOneLLMToolIteration` then dropped the gated
/// indices from `callsToExecute`, so neither log ever saw the refusal: the fail-closed
/// validator's pass rate over `tool_calls.jsonl` was a CEILING (1.0 in all four runs of
/// the 2026-09-07 audit while six calls were refused).
///
/// The fix reuses the seam the pre-runtime rejections already had: the refusals seed
/// `rejectedToLog` in `executeToolCalls` and drain through `ToolRuntime.logNonExecutedCall`
/// into BOTH sinks, `durationMS == nil` by construction (no handler ran).
@MainActor
final class ToolIterationGateLoggingTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var tempDir: URL!
    var tracker: ToolCallTracker!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
        tracker = ToolCallTracker()
    }

    override func tearDown() async throws {
        tracker = nil
        service = nil
        mockDelegate = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func call(_ name: String, _ args: String = "{}") -> StepToolCall {
        StepToolCall(providerID: UUID().uuidString, name: name, argumentsJSON: args)
    }

    private func bashRefusal(for call: StepToolCall) -> ToolExecutionResult {
        ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeErrorEnvelope(code: .bashDenied, message: "Blocked by deny rule “rm”."),
            isError: true)
    }

    private func computerUseRefusal(for call: StepToolCall) -> ToolExecutionResult {
        ToolExecutionResult.synthetic(
            for: call,
            outputJSON: makeErrorEnvelope(code: .computerUseDenied, message: "The target app is not in the allowlist."),
            isError: true)
    }

    private func makeTask() -> NTMSTask {
        let run = Run(id: 0, roleStatuses: ["eng": .working])
        return NTMSTask(id: 0, title: "Test Task", supervisorTask: "Goal", runs: [run])
    }

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
        return try NetworkLogTestReading.strictRecords(at: url).filter { $0.direction == .toolCall }
    }

    private func jsonlRecords(at url: URL) throws -> [ToolCallLogRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONCoderFactory.makeDateDecoder()
        return try text.split(separator: "\n").filter { !$0.isEmpty }.map {
            try decoder.decode(ToolCallLogRecord.self, from: Data($0.utf8))
        }
    }

    // MARK: - isCancellationEnvelope — the reader-side twin of `makeCancelledResult`

    func testIsCancellationEnvelope_trueForTheGateOverload() {
        let c = call("bash", #"{"command":"ls"}"#)
        XCTAssertTrue(makeCancelledResult(for: c).isCancellationEnvelope)
    }

    func testIsCancellationEnvelope_trueForTheRuntimeOverload() {
        XCTAssertTrue(
            makeCancelledResult(toolName: "bash", argumentsJSON: "{}", providerID: "p").isCancellationEnvelope)
    }

    func testIsCancellationEnvelope_falseForARefusal_ASuccess_AndNonEnvelopeOutput() {
        let c = call("bash", #"{"command":"rm -rf x"}"#)
        XCTAssertFalse(bashRefusal(for: c).isCancellationEnvelope, "a refusal is a decision, not a cancellation")
        XCTAssertFalse(
            ToolExecutionResult(toolName: "bash", argumentsJSON: "{}", outputJSON: #"{"ok":true,"data":{}}"#, isError: false)
                .isCancellationEnvelope)
        XCTAssertFalse(
            ToolExecutionResult(toolName: "bash", argumentsJSON: "{}", outputJSON: "plain text", isError: true)
                .isCancellationEnvelope,
            "non-envelope output must read as not-cancelled, never crash or match")
        let code = ToolErrorCode.cancelled.rawValue
        XCTAssertFalse(
            ToolExecutionResult(toolName: "bash", argumentsJSON: "{}",
                                outputJSON: #"{"ok":false,"error":""# + code + #""}"#, isError: true)
                .isCancellationEnvelope,
            "the executor's top-level string shape is never a cancellation — only the nested `error.code` is")
        XCTAssertFalse(
            ToolExecutionResult(toolName: "bash", argumentsJSON: "{}",
                                outputJSON: #"{"ok":false,"error":{"code":"BASH_DENIED","message":"Blocked — earlier run "# + code + #""}}"#,
                                isError: true)
                .isCancellationEnvelope,
            "the word inside a message is not the code — a substring match would misread a refusal as a cancellation")
    }

    // MARK: - gateRefusalsToLog — what the iteration hands to the logging seam

    func testGateRefusalsToLog_keepsEmitOrder_andSkipsUngatedIndices() {
        let a = call("bash", #"{"command":"rm a"}"#)
        let b = call("list_files")
        let c = call("ui_click", #"{"x":1,"y":2}"#)
        let gate: [Int: ToolExecutionResult] = [2: computerUseRefusal(for: c), 0: bashRefusal(for: a)]

        let refusals = LLMExecutionService.gateRefusalsToLog(resolvedToolCalls: [a, b, c], gateResults: gate)

        XCTAssertEqual(refusals.map(\.call.name), ["bash", "ui_click"], "index order, not dictionary order")
        XCTAssertEqual(refusals[0].result.outputJSON, gate[0]?.outputJSON)
        XCTAssertEqual(refusals[1].result.outputJSON, gate[2]?.outputJSON)
    }

    func testGateRefusalsToLog_excludesCancellationEnvelopes() {
        // Parity with `ToolRuntime`: a held approval abandoned by Pause is a cancellation, not
        // a refusal, and cancellation envelopes are NOT logged (ToolCallLoggingCornerTests).
        let held = call("bash", #"{"command":"make"}"#)
        let denied = call("bash", #"{"command":"rm b"}"#)
        let gate: [Int: ToolExecutionResult] = [0: makeCancelledResult(for: held), 1: bashRefusal(for: denied)]

        let refusals = LLMExecutionService.gateRefusalsToLog(resolvedToolCalls: [held, denied], gateResults: gate)

        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals[0].call.argumentsJSON, denied.argumentsJSON)
    }

    func testGateRefusalsToLog_emptyGate_andEmptyCalls() {
        XCTAssertTrue(LLMExecutionService.gateRefusalsToLog(resolvedToolCalls: [call("bash")], gateResults: [:]).isEmpty)
        XCTAssertTrue(LLMExecutionService.gateRefusalsToLog(resolvedToolCalls: [], gateResults: [:]).isEmpty)
        // A stray index with no call behind it is dropped, never trapped on.
        XCTAssertTrue(
            LLMExecutionService.gateRefusalsToLog(
                resolvedToolCalls: [], gateResults: [3: bashRefusal(for: call("bash"))]).isEmpty)
    }

    // MARK: - executeToolCalls(gateRefusals:) — both sinks, no duration, one category

    func testExecuteToolCalls_gateRefusal_landsInBothLogs_withNilDuration() async throws {
        let jsonlURL = tempDir.appendingPathComponent("gate.jsonl")
        let netURL = tempDir.appendingPathComponent("gate.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)
        let refused = call("bash", #"{"command":"rm -rf build"}"#)

        let results = await service.executeToolCalls(
            resolvedToolCalls: [],
            gateRefusals: [.init(call: refused, result: bashRefusal(for: refused))],
            allowedToolNames: ["bash"],
            runtime: rt,
            tracker: tracker,
            task: makeTask(),
            runIndex: 0,
            roleID: "eng"
        )

        XCTAssertTrue(results.isEmpty, "the refusal is merged back by the iteration, not returned as executed")

        let records = try jsonlRecords(at: jsonlURL)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].toolName, "bash")
        XCTAssertEqual(records[0].argumentsJSON, refused.argumentsJSON)
        XCTAssertEqual(records[0].errorMessage, LLMExecutionService.gateRefusedLogMessage)
        XCTAssertNil(records[0].durationMS, "no handler ran — the invariant `durationMS != nil ⟺ a handler ran` holds")
        XCTAssertTrue(records[0].resultJSON?.contains(ToolErrorCode.bashDenied.rawValue) == true,
                      "the envelope rides along so an audit can tell WHICH refusal it was")

        let net = try networkToolCallRecords(at: netURL)
        XCTAssertEqual(net.count, 1)
        XCTAssertEqual(net[0].errorMessage, LLMExecutionService.gateRefusedLogMessage)
        XCTAssertTrue(net[0].body?.contains(ToolErrorCode.bashDenied.rawValue) == true)
    }

    func testExecuteToolCalls_gateRefusalsAreLoggedBeforeExecutedCalls() async throws {
        let jsonlURL = tempDir.appendingPathComponent("order.jsonl")
        let netURL = tempDir.appendingPathComponent("order.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)
        let refusedShell = call("bash", #"{"command":"rm -rf build"}"#)
        let refusedClick = call("ui_click", #"{"x":3,"y":4}"#)
        let executed = call("list_files", #"{"path":"."}"#)

        _ = await service.executeToolCalls(
            resolvedToolCalls: [executed],
            gateRefusals: [
                .init(call: refusedShell, result: bashRefusal(for: refusedShell)),
                .init(call: refusedClick, result: computerUseRefusal(for: refusedClick)),
            ],
            allowedToolNames: ["bash", "ui_click", "list_files"],
            runtime: rt,
            tracker: tracker,
            task: makeTask(),
            runIndex: 0,
            roleID: "eng"
        )

        let records = try jsonlRecords(at: jsonlURL)
        XCTAssertEqual(records.map(\.toolName), ["bash", "ui_click", "list_files"],
                       "refusals first (emit order preserved), then the executed batch")
        XCTAssertEqual(records.map { $0.durationMS == nil }, [true, true, false])
        // The network record carries the tool name inside its `tool_call` body, not as a field.
        let netTools = try networkToolCallRecords(at: netURL).map { record -> String in
            let body = JSONUtilities.parseJSONDictionary(record.body ?? "") ?? [:]
            return (body["tool"] as? String) ?? "?"
        }
        XCTAssertEqual(netTools, ["bash", "ui_click", "list_files"])
    }

    func testExecuteToolCalls_noRefusals_addsNothing() async throws {
        let jsonlURL = tempDir.appendingPathComponent("none.jsonl")
        let netURL = tempDir.appendingPathComponent("none.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)

        _ = await service.executeToolCalls(
            resolvedToolCalls: [call("list_files", #"{"path":"."}"#)],
            gateRefusals: [],
            allowedToolNames: ["list_files"],
            runtime: rt,
            tracker: tracker,
            task: makeTask(),
            runIndex: 0,
            roleID: "eng"
        )

        XCTAssertEqual(try jsonlRecords(at: jsonlURL).map(\.toolName), ["list_files"])
        XCTAssertEqual(try networkToolCallRecords(at: netURL).count, 1)
    }

    /// The seam sits below the nil-delegate early return: with no delegate, nothing is
    /// logged — refusals included — exactly as for every other call. Pinned so a later
    /// "log before the guard" move is a decision, not drift.
    func testExecuteToolCalls_noDelegate_logsNothing() async throws {
        let jsonlURL = tempDir.appendingPathComponent("orphan.jsonl")
        let netURL = tempDir.appendingPathComponent("orphan.json")
        let rt = makeRuntimeWithBothLogs(jsonlURL: jsonlURL, netURL: netURL)
        let orphan = LLMExecutionService(repository: NTMSRepository())
        let refused = call("bash", #"{"command":"rm -rf build"}"#)

        let results = await orphan.executeToolCalls(
            resolvedToolCalls: [],
            gateRefusals: [.init(call: refused, result: bashRefusal(for: refused))],
            allowedToolNames: ["bash"],
            runtime: rt,
            tracker: tracker,
            task: makeTask(),
            runIndex: 0,
            roleID: "eng"
        )

        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonlURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: netURL.path))
    }

    // MARK: - Wiring pin

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    private static let scannedPath = "NanoTeams/Services/LLM/LLMExecutionService+ToolIteration.swift"

    /// No test drives `runOneLLMToolIteration` end-to-end (it needs a full client + runtime),
    /// so the wiring is pinned at the source: the iteration must build the refusal list through
    /// the helper pinned above and hand it to `executeToolCalls`. A refactor that dropped the
    /// argument would compile only if a default were re-introduced — which is the other thing
    /// this test forbids.
    func testIterationHandsGateRefusalsToTheLoggingSeam() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(Self.scannedPath), encoding: .utf8)
        XCTAssertTrue(source.contains("gateRefusalsToLog" + "("),
                      "\(Self.scannedPath) must build the refusal list through the pinned helper")
        XCTAssertTrue(source.contains("gateRefusals" + ": gateRefusals"),
                      "\(Self.scannedPath) must pass the refusals into executeToolCalls")

        let execution = try String(
            contentsOf: repoRoot.appendingPathComponent("NanoTeams/Services/LLM/LLMExecutionService+ToolExecution.swift"),
            encoding: .utf8)
        XCTAssertFalse(execution.contains("gateRefusals" + ": [GateRefusal] = []"),
                       "the parameter has no default: a caller that forgets it must not compile")
    }

    func testRepoRootResolves() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(Self.scannedPath).path),
            "repoRoot derivation is wrong — the wiring pin above would pass vacuously")
    }
}
