import XCTest
@testable import NanoTeams

/// Pins the end-to-end plumbing of `step.expectedArtifacts → ToolExecutionContext →
/// CreateArtifactTool` so a regression that drops the field-passing in
/// `LLMExecutionService+ToolExecution.executeToolCalls` would surface.
///
/// Pre-fix coverage (`CreateArtifactFormatValidationTests`) constructs
/// `ToolExecutionContext` directly, skipping the sourcing path. A regression in
/// `executeToolCalls` (e.g. dropping `expectedArtifacts: expectedArtifacts` from
/// the initializer) compiles fine and the handler-level tests still pass — the
/// integration silently breaks and the error message goes empty-bracket `[]`.
@MainActor
final class ExpectedArtifactsPlumbingTests: XCTestCase {

    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var runtime: ToolRuntime!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        runtime = nil
        service = nil
        mockDelegate = nil
        tempDir = nil
        try await super.tearDown()
    }

    /// Regression: a refactor that drops `expectedArtifacts` from the
    /// `ToolExecutionContext` initializer in `executeToolCalls` would leave
    /// `CreateArtifactTool` rendering `[]` in its error message — the model
    /// has no name to recover with and loops until 30-min delegation timeout.
    /// This test pins the end-to-end field passing.
    func testExecuteToolCalls_passesExpectedArtifactsFromStepIntoHandlerErrorMessage() async {
        let stepID = "engineer_step"
        // Step declares its expected artifact; this is the value that must thread
        // through to the handler's error envelope.
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Engineer",
            expectedArtifacts: ["Implementation Notes"],
            status: .running
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(
            id: 7, title: "T",
            supervisorTask: "do work", runs: [run]
        )

        // Build a file-shaped `create_artifact` call → triggers the file-shape
        // guard whose error message includes `context.expectedArtifacts`.
        let toolCalls = [
            StepToolCall(
                name: "create_artifact",
                argumentsJSON: "{\"name\":\"index.html\",\"content\":\"<html></html>\"}"
            )
        ]

        let batch = await service.executeToolCalls(
            resolvedToolCalls: toolCalls,
            gateRefusals: [],
            allowedToolNames: ["create_artifact"],
            runtime: runtime,
            tracker: ToolCallTracker(),
            task: task,
            runIndex: 0,
            roleID: stepID
        )

        XCTAssertEqual(batch.count, 1)
        let out = batch[0].outputJSON
        XCTAssertTrue(batch[0].isError, "file-shaped name must be rejected: \(out)")
        XCTAssertTrue(
            out.contains("Implementation Notes"),
            "End-to-end: step.expectedArtifacts must thread into context.expectedArtifacts and surface in the error message. Got: \(out)"
        )
        XCTAssertFalse(
            out.contains(": []."),
            "Error must NOT render the empty list — that means expectedArtifacts wasn't plumbed through. Got: \(out)"
        )
    }

    /// The loopback ports a role's `bash` may not reach ride the same channel, read from the
    /// delegate per BATCH (review 2026-11-08). Dropping `guardedLoopbackPorts:` from the
    /// initializer in `executeToolCalls` compiles, and every handler-level test still passes —
    /// the default is the bare floor — so the wiring is pinned here, twice: a later batch reads
    /// the delegate again, never a value fixed at step entry. A spy registered as `bash` sees the
    /// context the real handler would.
    func testExecuteToolCalls_readsTheGuardedPortsIntoEveryBashBatchContext() async {
        let seen = SeenPorts()
        let spyRuntime = spyRuntime(recordingInto: seen)
        mockDelegate.seatbeltGuardedLoopbackPortsValue = [1234, 3845, 47321]
        await batch(calling: ToolNames.bash, on: spyRuntime)
        XCTAssertEqual(seen.last, [1234, 3845, 47321])

        mockDelegate.seatbeltGuardedLoopbackPortsValue = [8765, 47321]
        await batch(calling: ToolNames.bash, on: spyRuntime)
        XCTAssertEqual(seen.last, [8765, 47321], "the second batch read the delegate again")
        XCTAssertEqual(seen.count, 2)
    }

    /// Only a batch that runs `bash` reads the list: it costs a read of the MCP catalogue and of
    /// the interface addresses, and nothing else looks at it. Another tool gets the bare floor.
    func testExecuteToolCalls_aBatchWithoutBashDoesNotReadTheGuardedPorts() async {
        let seen = SeenPorts()
        let spyRuntime = spyRuntime(recordingInto: seen, as: "spy_tool")
        mockDelegate.seatbeltGuardedLoopbackPortsValue = [1234, 3845, 47321]
        let readsBefore = mockDelegate.seatbeltGuardedLoopbackPortsReads
        await batch(calling: "spy_tool", on: spyRuntime)
        XCTAssertEqual(mockDelegate.seatbeltGuardedLoopbackPortsReads, readsBefore)
        XCTAssertEqual(seen.last, SeatbeltSandbox.effectiveGuardedPorts([]))
    }

    /// The `bash` sandbox settings ride the same channel and are read from the delegate per
    /// BATCH too (review 2026-11-08): a switch flipped since the step began governs the next
    /// command. A handler field baked at step entry carried the old setting to the task's close
    /// in chat mode. Pinned the same way as the ports: a later batch reads the delegate again.
    func testExecuteToolCalls_readsTheLiveSandboxSettingsIntoEveryBashBatchContext() async {
        let seen = SeenPorts()
        let spyRuntime = spyRuntime(recordingInto: seen)
        mockDelegate.bashPolicyValue.sandboxEnabled = false
        await batch(calling: ToolNames.bash, on: spyRuntime)
        XCTAssertEqual(seen.lastSandbox?.enabled, false)

        mockDelegate.bashPolicyValue.sandboxEnabled = true
        mockDelegate.bashPolicyValue.allowUnsandboxedFallback = true
        await batch(calling: ToolNames.bash, on: spyRuntime)
        XCTAssertEqual(seen.lastSandbox, mockDelegate.bashPolicyValue.sandbox, "the second batch read the delegate again")
        XCTAssertEqual(seen.count, 2)
    }

    /// A batch without `bash` carries the fresh-install sandbox (confined, no fallback) whatever
    /// the live policy says — nothing in such a batch looks at it, and the live value is copied
    /// in for `bash` batches alone. The policy itself is cheap and read by the gate for every
    /// batch, so only the COPY is pinned, not the read.
    func testExecuteToolCalls_aBatchWithoutBashCarriesTheDefaultSandbox() async {
        let seen = SeenPorts()
        let spyRuntime = spyRuntime(recordingInto: seen, as: "spy_tool")
        mockDelegate.bashPolicyValue.sandboxEnabled = false
        await batch(calling: "spy_tool", on: spyRuntime)
        XCTAssertEqual(seen.lastSandbox, BashPolicy.Sandbox())
    }

    private func spyRuntime(recordingInto seen: SeenPorts, as name: String = ToolNames.bash) -> ToolRuntime {
        let registry = ToolRegistry()
        registry.register(name: name) { context, args in
            seen.record(context.guardedLoopbackPorts, sandbox: context.bashSandbox)
            return makeSuccessResult(toolName: name, args: args, data: ["ok": true])
        }
        return ToolRuntime(registry: registry, logger: nil)
    }

    private func batch(calling name: String, on runtime: ToolRuntime) async {
        let step = StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)
        let task = NTMSTask(id: 9, title: "T", supervisorTask: "x", runs: [Run(id: 0, steps: [step])])
        _ = await service.executeToolCalls(
            resolvedToolCalls: [StepToolCall(name: name, argumentsJSON: #"{"command":"true"}"#)],
            gateRefusals: [],
            allowedToolNames: [name],
            runtime: runtime,
            tracker: ToolCallTracker(),
            task: task,
            runIndex: 0,
            roleID: "eng")
    }

    /// Symmetric coverage: a step with no declared deliverables (e.g. config bug
    /// where create_artifact is manually authorized for a role with empty
    /// producesArtifacts) routes through the empty-expectedArtifacts branch
    /// and surfaces a `commandFailed` config-error envelope.
    func testExecuteToolCalls_emptyExpectedArtifacts_surfacesConfigError() async {
        let stepID = "misconfigured_step"
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Misconfigured Role",
            expectedArtifacts: [],
            status: .running
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 8, title: "T", supervisorTask: "x", runs: [run])

        let toolCalls = [
            StepToolCall(
                name: "create_artifact",
                argumentsJSON: "{\"name\":\"index.html\",\"content\":\"\"}"
            )
        ]

        let batch = await service.executeToolCalls(
            resolvedToolCalls: toolCalls,
            gateRefusals: [],
            allowedToolNames: ["create_artifact"],
            runtime: runtime,
            tracker: ToolCallTracker(),
            task: task,
            runIndex: 0,
            roleID: stepID
        )

        XCTAssertEqual(batch.count, 1)
        let out = batch[0].outputJSON
        XCTAssertTrue(batch[0].isError)
        XCTAssertTrue(
            out.contains("not authorized") || out.contains("no declared deliverables"),
            "Empty expectedArtifacts must surface the config bug, not render an empty list. Got: \(out)"
        )
    }
}

/// What the spy tool saw, across the detached batch task the runtime runs it on.
private final class SeenPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[UInt16]] = []
    private var sandboxes: [BashPolicy.Sandbox] = []
    func record(_ ports: [UInt16], sandbox: BashPolicy.Sandbox) {
        lock.withLock { all.append(ports); sandboxes.append(sandbox) }
    }
    var last: [UInt16]? { lock.withLock { all.last } }
    var lastSandbox: BashPolicy.Sandbox? { lock.withLock { sandboxes.last } }
    var count: Int { lock.withLock { all.count } }
}
