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
