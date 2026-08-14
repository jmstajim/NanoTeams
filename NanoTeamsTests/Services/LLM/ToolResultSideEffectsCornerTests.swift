import XCTest

@testable import NanoTeams

/// Corner arms of `LLMExecutionService+ToolResultSideEffects` that the happy-path
/// suites never reach: the Autovisor memory write-through (including its failure
/// warning), the artifact-name fallback when the step is not in the latest run,
/// the binary side-car export, and the replace-in-place branch of artifact
/// persistence.
///
/// All four are error/edge paths where a silent failure is the expensive outcome:
/// the manager's scratchpad IS its only cross-run state, and an artifact written
/// under the wrong name is indistinguishable from a missing deliverable to the
/// engine's readiness check.
@MainActor
final class ToolResultSideEffectsCornerTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let stepID = "worker_step"
    private let taskID = 77

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-effects-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Autovisor memory write-through

    /// The manager's `update_scratchpad` is its standing memory: it must be
    /// written THROUGH to folder settings, not left step-scoped, or the manager
    /// silently forgets everything on the next recurrence fire (which creates a
    /// fresh run).
    func testScratchpad_onAutovisorStep_writesMemoryThrough_andAppendsNoWarning() async {
        seedAutovisorStep()
        var conversation: [ChatMessage] = []

        await service.processScratchpadResult(
            result: scratchpadResult(content: "Watching task #3; next check at 14:00."),
            stepID: stepID, taskID: taskID,
            conversationMessages: &conversation)

        XCTAssertEqual(mockDelegate.persistedAutovisorMemory,
                       ["Watching task #3; next check at 14:00."],
                       "the manager's scratchpad must be persisted as standing memory")
        XCTAssertFalse(conversation.contains { ($0.content ?? "").contains("Memory write to disk failed") },
                       "a SUCCESSFUL write must not warn; got: \(conversation.map { $0.content ?? "" })")
    }

    /// A failed settings write must reach the manager. Memory is its only
    /// cross-run state — a silent failure means it forgets and re-derives next
    /// pass, with nothing anywhere saying why.
    func testScratchpad_onAutovisorStep_persistFailure_warnsOnBothSurfaces() async {
        seedAutovisorStep()
        mockDelegate.persistAutovisorMemoryResult = false
        var conversation: [ChatMessage] = []

        await service.processScratchpadResult(
            result: scratchpadResult(content: "remember this"),
            stepID: stepID, taskID: taskID,
            conversationMessages: &conversation)

        let warningOnWire = conversation.first { ($0.content ?? "").contains("Memory write to disk failed") }
        XCTAssertNotNil(warningOnWire, "the model must be told its memory did not persist")
        XCTAssertEqual(warningOnWire?.role, .user,
                       "the warning ships on the wire role .user — a .system copy corrupts stateless rebuilds")

        let persisted = step()?.llmConversation.first { $0.content.contains("Memory write to disk failed") }
        XCTAssertNotNil(persisted, "the warning must survive into llmConversation, not only this iteration")
        XCTAssertEqual(persisted?.role, .user)
    }

    /// A whitespace-only scratchpad on the manager is not memory — the guard is
    /// on the CONTENT, so an empty update must not blank the standing memory.
    func testScratchpad_onAutovisorStep_whitespaceOnlyContent_doesNotWriteMemory() async {
        seedAutovisorStep()
        var conversation: [ChatMessage] = []

        await service.processScratchpadResult(
            result: scratchpadResult(content: "   \n  "),
            stepID: stepID, taskID: taskID,
            conversationMessages: &conversation)

        XCTAssertTrue(mockDelegate.persistedAutovisorMemory.isEmpty,
                      "a blank update must not overwrite standing memory")
    }

    /// The write-through is scoped to the manager. An ordinary role's scratchpad
    /// is step-state; leaking it into folder settings would let any role clobber
    /// the manager's memory.
    func testScratchpad_onOrdinaryStep_neverWritesAutovisorMemory() async {
        seedOrdinaryStep()
        var conversation: [ChatMessage] = []

        await service.processScratchpadResult(
            result: scratchpadResult(content: "my private plan"),
            stepID: stepID, taskID: taskID,
            conversationMessages: &conversation)

        XCTAssertTrue(mockDelegate.persistedAutovisorMemory.isEmpty,
                      "only the manager's scratchpad is standing memory")
        XCTAssertEqual(step()?.scratchpad, "my private plan",
                       "the ordinary role's scratchpad still lands on its own step")
    }

    // MARK: - Artifact name resolution when the step is not in the latest run

    /// `processCreateArtifactResult` resolves the artifact name against
    /// `expectedArtifacts` of the step it finds in `runs.last`. A step whose
    /// execution outlived its run (a recurrence fire or restart appends a NEW run
    /// while the old step's tool loop is still unwinding) is not there — the
    /// fallback keeps the LLM's raw name rather than silently resolving it
    /// against a DIFFERENT step's expectations.
    func testCreateArtifact_stepAbsentFromLatestRun_keepsTheRawName() async {
        // Run 0 holds our step; run 1 (the latest) holds someone else's.
        let oldStep = StepExecution(
            id: stepID, role: .softwareEngineer, title: "old",
            expectedArtifacts: ["Design Spec"], status: .running)
        let otherStep = StepExecution(
            id: "someone_else", role: .productManager, title: "new", status: .running)
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b",
            runs: [Run(id: 0, steps: [oldStep]), Run(id: 1, steps: [otherStep])])
        task.preferredTeamID = nil
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)

        await service.processCreateArtifactResult(
            result: artifactResult(name: "Design Spec – Calculator", content: "# body", format: nil),
            stepID: stepID, taskID: taskID)

        // The file lands on disk under the RAW name's slug. Comparing against the
        // production slugifier (rather than a hand-typed string) keeps the subject
        // "raw vs resolved", not "how does slugify spell an en dash".
        let roleDir = NTMSPaths(workFolderRoot: tempDir)
            .roleDir(taskID: taskID, runID: 1, roleID: stepID)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: roleDir.path)) ?? []
        let rawSlug = Artifact.slugify("Design Spec – Calculator")
        let resolvedSlug = Artifact.slugify("Design Spec")
        XCTAssertNotEqual(rawSlug, resolvedSlug, "premise: the two names slugify differently")
        XCTAssertTrue(written.contains("artifact_\(rawSlug).md"),
                      "the unresolved raw name must be what reaches disk; got \(written)")
        XCTAssertFalse(written.contains("artifact_\(resolvedSlug).md"),
                       "the name must NOT be resolved against a different step's expectations; got \(written)")

        // And nothing is appended to the (absent) step — the mutation is a no-op, not a crash.
        XCTAssertTrue(mockDelegate.taskToMutate?.runs[1].steps[0].artifacts.isEmpty ?? false,
                      "the artifact must not be grafted onto an unrelated step in the latest run")
    }

    // MARK: - Binary side-car export

    /// `format` requests a downloadable side-car beside the always-written
    /// markdown. The markdown stays primary (`relativePath` points at it) — a
    /// regression that pointed the artifact at the binary would break every
    /// downstream role, which reads artifacts as text.
    func testCreateArtifact_withRTFFormat_writesSideCarAndKeepsMarkdownPrimary() async {
        seedOrdinaryStep(expectedArtifacts: ["Design Spec"])

        await service.processCreateArtifactResult(
            result: artifactResult(name: "Design Spec", content: "# Heading\n\nbody", format: "rtf"),
            stepID: stepID, taskID: taskID)

        let artifact = step()?.artifacts.first
        XCTAssertEqual(artifact?.name, "Design Spec")
        XCTAssertEqual(artifact?.mimeType, "text/markdown",
                       "the markdown remains the primary artifact")
        XCTAssertTrue((artifact?.relativePath ?? "").hasSuffix(".md"),
                      "relativePath must point at the markdown, not the side-car; got \(artifact?.relativePath ?? "nil")")

        let roleDir = NTMSPaths(workFolderRoot: tempDir)
            .roleDir(taskID: taskID, runID: 0, roleID: stepID)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: roleDir.path)) ?? []
        XCTAssertTrue(written.contains { $0.hasSuffix(".rtf") },
                      "the requested side-car must be written alongside; got \(written)")
        XCTAssertTrue(written.contains { $0.hasSuffix(".md") },
                      "the markdown must be written regardless of format; got \(written)")
    }

    /// An unknown format string is best-effort: no side-car, but the markdown and
    /// the in-memory artifact are unaffected. Failing the whole submission over a
    /// cosmetic export would lose the deliverable.
    func testCreateArtifact_withUnknownFormat_stillPersistsMarkdown() async {
        seedOrdinaryStep(expectedArtifacts: ["Design Spec"])

        await service.processCreateArtifactResult(
            result: artifactResult(name: "Design Spec", content: "body", format: "xyz"),
            stepID: stepID, taskID: taskID)

        XCTAssertEqual(step()?.artifacts.count, 1,
                       "an unusable format must not cost the artifact")
        let roleDir = NTMSPaths(workFolderRoot: tempDir)
            .roleDir(taskID: taskID, runID: 0, roleID: stepID)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: roleDir.path)) ?? []
        XCTAssertFalse(written.contains { $0.hasSuffix(".xyz") }, "got \(written)")
    }

    // MARK: - Replace-in-place

    /// Re-submitting the same artifact must REPLACE, not append. An append would
    /// leave two rows with the same name, and `isArtifactComplete` (a set
    /// membership test) would still pass — so the duplicate is invisible to the
    /// engine and visible only as a doubled card in the feed.
    func testCreateArtifact_resubmittedName_replacesInPlace() async {
        seedOrdinaryStep(expectedArtifacts: ["Design Spec"])

        await service.processCreateArtifactResult(
            result: artifactResult(name: "Design Spec", content: "first draft", format: nil),
            stepID: stepID, taskID: taskID)
        let firstUpdatedAt = step()?.artifacts.first?.updatedAt

        await service.processCreateArtifactResult(
            result: artifactResult(name: "Design Spec", content: "second draft", format: nil),
            stepID: stepID, taskID: taskID)

        XCTAssertEqual(step()?.artifacts.count, 1,
                       "resubmission replaces; got \(step()?.artifacts.map(\.name) ?? [])")
        let second = step()?.artifacts.first
        XCTAssertEqual(second?.name, "Design Spec")
        if let firstUpdatedAt, let secondUpdatedAt = second?.updatedAt {
            XCTAssertGreaterThan(secondUpdatedAt, firstUpdatedAt,
                                 "the row must be the NEWER artifact, not the stale one kept in place")
        }
        // Read it back the way every downstream consumer does — `relativePath` is
        // relative to `.nanoteams`, not to the work-folder root.
        let onDisk = second.flatMap { ArtifactService.readContent(artifact: $0, workFolderRoot: tempDir) }
        XCTAssertEqual(onDisk, "second draft",
                       "the file must carry the resubmitted content, not the first draft")
    }

    /// The revision gate is cleared by a successful submission — otherwise
    /// `checkArtifactCompleteness` stays suppressed and the step never
    /// auto-completes after a change request.
    func testCreateArtifact_clearsRevisionComment() async {
        seedOrdinaryStep(expectedArtifacts: ["Design Spec"], revisionComment: "redo it")

        await service.processCreateArtifactResult(
            result: artifactResult(name: "Design Spec", content: "redone", format: nil),
            stepID: stepID, taskID: taskID)

        XCTAssertNil(step()?.revisionComment,
                     "a fresh artifact must re-enable auto-completion")
    }

    // MARK: - Fixtures

    private func step() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private func scratchpadResult(content: String) -> ToolExecutionResult {
        let args = String(
            data: try! JSONSerialization.data(withJSONObject: ["content": content]),
            encoding: .utf8)!
        return ToolExecutionResult(
            providerID: "tc_sp", toolName: ToolNames.updateScratchpad,
            argumentsJSON: args, outputJSON: #"{"ok":true}"#, isError: false)
    }

    private func artifactResult(name: String, content: String, format: String?) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: "tc_art", toolName: ToolNames.createArtifact,
            argumentsJSON: #"{"name":"\#(name)"}"#,
            outputJSON: #"{"ok":true}"#, isError: false,
            signal: .artifact(name: name, content: content, format: format))
    }

    private func seedAutovisorStep() {
        let team = TeamTemplateFactory.autovisor()
        seed(team: team, role: .autovisor)
    }

    private func seedOrdinaryStep(
        expectedArtifacts: [String] = [], revisionComment: String? = nil
    ) {
        let role = TeamRoleDefinition(
            id: stepID, name: "Worker", prompt: "p", toolIDs: [ToolNames.updateScratchpad],
            usePlanningPhase: false, dependencies: RoleDependencies(),
            systemRoleID: "softwareEngineer")
        let team = Team(
            name: "Ordinary", roles: [role], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout())
        seed(team: team, role: .softwareEngineer,
             expectedArtifacts: expectedArtifacts, revisionComment: revisionComment)
    }

    private func seed(
        team: Team, role: Role,
        expectedArtifacts: [String] = [], revisionComment: String? = nil
    ) {
        let step = StepExecution(
            id: stepID, role: role, title: "step",
            expectedArtifacts: expectedArtifacts, status: .running,
            revisionComment: revisionComment)
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "brief", runs: [Run(id: 0, steps: [step])])
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id),
                settings: .defaults, teams: [team]),
            tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: taskID, activeTask: task)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }
}
