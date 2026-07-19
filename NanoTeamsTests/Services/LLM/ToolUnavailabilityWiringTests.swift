import XCTest
@testable import NanoTeams

/// Pins the runtime wiring that feeds `delegate` state into
/// `LLMExecutionService.classifyUnavailability`. The classifier itself is
/// covered by `ToolUnavailabilityClassifierTests` (pure-function coverage of
/// each branch). This suite drives the live `executeToolCalls` path so a
/// regression like "delegate keypath typo / polarity flip on visionLLMConfig
/// != nil / URL-equality drift on isDefaultStorage" is caught — the call site
/// reads ~5 fields off `delegate` and a typo in any one of them silently
/// misroutes every rejection.
@MainActor
final class ToolUnavailabilityWiringTests: XCTestCase {

    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var runtime: ToolRuntime!

    override func setUpWithError() throws {
        try super.setUpWithError()
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
        service.attach(delegate: mockDelegate)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        runtime = nil
        service = nil
        mockDelegate = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeStep() -> NTMSTask {
        let step = StepExecution(
            id: "role",
            role: .softwareEngineer,
            title: "Role",
            expectedArtifacts: [],
            status: .running
        )
        let r = Run(id: 0, steps: [step])
        return NTMSTask(id: 1, title: "T", supervisorTask: "x", runs: [r])
    }

    private func runRejection(toolName: String, argumentsJSON: String = "{}") async -> ToolExecutionResult {
        let task = makeStep()
        let batch = await service.executeToolCalls(
            resolvedToolCalls: [StepToolCall(name: toolName, argumentsJSON: argumentsJSON)],
            // Empty allowedToolNames forces every call into the rejection path.
            allowedToolNames: [],
            runtime: runtime,
            tracker: ToolCallTracker(),
            task: task,
            runIndex: 0,
            roleID: "role"
        )
        XCTAssertEqual(batch.count, 1)
        return batch[0]
    }

    // MARK: - workFolderClosed wiring (default storage)

    /// `workFolderURL == nil` MUST classify as default-storage. Without the
    /// I1 fix, the bare URL-equality check would compare `URL(fileURLWithPath:
    /// "/")` (the fallback) against `defaultStorageURL` and silently misroute
    /// to `gitRepoMissing`.
    func testWiring_nilWorkFolderURL_writeFile_returnsWorkFolderClosed() async {
        mockDelegate.workFolderURL = nil
        let result = await runRejection(toolName: ToolNames.writeFile)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(
            result.outputJSON.contains("\"error\":\"precondition_failed\""),
            "Expected precondition_failed for nil workFolderURL + write_file, got: \(result.outputJSON)"
        )
        XCTAssertTrue(
            result.outputJSON.contains("default storage"),
            "Expected workFolderClosed message naming default storage, got: \(result.outputJSON)"
        )
    }

    func testWiring_defaultStorageURL_writeFile_returnsWorkFolderClosed() async {
        mockDelegate.workFolderURL = NTMSOrchestrator.defaultStorageURL
        let result = await runRejection(toolName: ToolNames.writeFile)
        XCTAssertTrue(
            result.outputJSON.contains("default storage"),
            "Expected workFolderClosed at the canonical default-storage URL, got: \(result.outputJSON)"
        )
    }

    // MARK: - gitRepoMissing wiring

    /// Real (non-default-storage) folder without `.git/` → git_add must
    /// surface gitRepoMissing, not the misleading role-config message.
    func testWiring_realWorkFolderNoGit_gitAdd_returnsGitRepoMissing() async {
        mockDelegate.workFolderURL = tempDir  // tempDir has no .git/
        let result = await runRejection(toolName: ToolNames.gitAdd)
        XCTAssertTrue(
            result.outputJSON.contains("\"error\":\"precondition_failed\""),
            "Expected precondition_failed, got: \(result.outputJSON)"
        )
        XCTAssertTrue(
            result.outputJSON.contains("requires a git repository"),
            "Expected git-specific message, got: \(result.outputJSON)"
        )
    }

    func testWiring_realWorkFolderWithGit_gitAdd_returnsNotInRoleConfig() async throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        mockDelegate.workFolderURL = tempDir
        let result = await runRejection(toolName: ToolNames.gitAdd)
        // .git present → falls through to legacy tool_not_authorized.
        XCTAssertTrue(
            result.outputJSON.contains("\"error\":\"tool_not_authorized\""),
            "Expected legacy code (genuine config mismatch — git is available), got: \(result.outputJSON)"
        )
    }

    // MARK: - visionNotConfigured wiring

    /// `delegate.visionLLMConfig == nil` is the gate. A polarity flip
    /// (`!= nil`) would turn the rejection into a false vision-blame on
    /// every other rejection — caught here.
    func testWiring_visionNil_analyzeImage_returnsVisionNotConfigured() async throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        mockDelegate.workFolderURL = tempDir
        mockDelegate.visionLLMConfig = nil
        let result = await runRejection(toolName: ToolNames.analyzeImage)
        XCTAssertTrue(
            result.outputJSON.contains("\"error\":\"precondition_failed\""),
            "Got: \(result.outputJSON)"
        )
        XCTAssertTrue(
            result.outputJSON.contains("vision model"),
            "Got: \(result.outputJSON)"
        )
    }

    func testWiring_visionConfigured_analyzeImage_returnsNotInRoleConfig() async throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        mockDelegate.workFolderURL = tempDir
        mockDelegate.visionLLMConfig = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://127.0.0.1:1234",
            modelName: "vlm",
            temperature: 0.0
        )
        let result = await runRejection(toolName: ToolNames.analyzeImage)
        XCTAssertTrue(
            result.outputJSON.contains("\"error\":\"tool_not_authorized\""),
            "Vision configured → falls through to legacy code (the role just doesn't have analyze_image). Got: \(result.outputJSON)"
        )
    }

    // MARK: - xcodeSchemeNotSelected wiring

    /// `delegate.snapshot?.workFolder.settings.selectedScheme` keypath risk —
    /// any rename in the long path silently misroutes the rejection.
    func testWiring_snapshotWithEmptyScheme_runXcodebuild_returnsXcodeSchemeNotSelected() async throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        mockDelegate.workFolderURL = tempDir
        mockDelegate.visionLLMConfig = nil
        mockDelegate.snapshot = makeContextWithScheme("")  // empty scheme
        let result = await runRejection(toolName: ToolNames.runXcodebuild)
        XCTAssertTrue(
            result.outputJSON.contains("\"error\":\"precondition_failed\""),
            "Got: \(result.outputJSON)"
        )
        XCTAssertTrue(
            result.outputJSON.contains("Xcode scheme"),
            "Got: \(result.outputJSON)"
        )
    }

    /// I2: when snapshot is nil (teardown / task-switch race) the classifier
    /// must NOT blame a setting it can't see. Falls through to the legacy
    /// tool_not_authorized envelope.
    func testWiring_nilSnapshot_runXcodebuild_doesNotFalselyBlameScheme() async throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        mockDelegate.workFolderURL = tempDir
        mockDelegate.snapshot = nil
        let result = await runRejection(toolName: ToolNames.runXcodebuild)
        XCTAssertFalse(
            result.outputJSON.contains("Xcode scheme"),
            "Snapshot is unloaded — classifier must not claim the scheme is missing. Got: \(result.outputJSON)"
        )
        XCTAssertTrue(
            result.outputJSON.contains("\"error\":\"tool_not_authorized\""),
            "Expected fall-through to legacy code, got: \(result.outputJSON)"
        )
    }

    // MARK: - Snapshot helper

    /// Builds a minimal `WorkFolderContext` carrying just the scheme — the
    /// only field this wiring suite reads via the snapshot path. Other
    /// projection fields use defaults.
    private func makeContextWithScheme(_ scheme: String) -> WorkFolderContext {
        let settings = ProjectSettings(selectedScheme: scheme)
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "test"),
            settings: settings,
            teams: []
        )
        return WorkFolderContext(
            projection: projection,
            tasksIndex: TasksIndex(),
            toolDefinitions: []
        )
    }
}
