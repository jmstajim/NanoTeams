import XCTest

@testable import NanoTeams

// MARK: - Failing repository decorator

/// Forwards every `NTMSRepositoryProtocol` call to a real `NTMSRepository` except
/// the ones a test switches off — the same shape as
/// `SelectivelyFailingRepository` (declared in `WorkFolderPartialWriteRecoveryTests`),
/// but with the refusals THIS cluster needs: the active-task pointer writers, the
/// task delete, the staged-draft cleanup, and a `updateTaskOnly` that can throw a
/// `CancellationError` specifically (the arm `mutateTask` treats as "not a
/// failure", which no other refusal can reach).
///
/// A separate type rather than new flags on the existing one: that decorator lives
/// in another suite's file and is not this cluster's to extend.
final class AOrchFailingRepository: NTMSRepositoryProtocol, @unchecked Sendable {

    struct Refused: LocalizedError {
        let what: String
        var errorDescription: String? { "Refused: \(what)" }
    }

    private let inner: NTMSRepository

    /// `updateTaskOnly` throws `CancellationError()` — the shape a pause /
    /// work-folder switch produces, which must NOT banner.
    var cancelUpdateTaskOnly = false
    /// `updateTaskOnly` throws a plain disk error — the shape that MUST banner.
    var failUpdateTaskOnly = false
    var failSetActiveTaskID = false
    var failSetActiveTask = false
    var failDeleteTask = false
    var failCleanupStagedDraft = false
    var failRemoveStagedItem = false
    var failCreateTask = false
    /// `updateSettings` throws — the settings.json half of a write-refusing volume.
    /// Used by `WorkFolderOpenFailureCoverageTests` to reach `mutateWorkFolder`'s
    /// revert-from-disk arm, which is what makes a persisted override silently absent.
    var failUpdateSettings = false

    private(set) var updateTeamsCalls = 0

    init(wrapping inner: NTMSRepository) { self.inner = inner }

    func resetCounters() { updateTeamsCalls = 0 }

    // MARK: WorkFolderRepository

    func openOrCreateWorkFolder(at workFolderRoot: URL) throws -> WorkFolderContext {
        try inner.openOrCreateWorkFolder(at: workFolderRoot)
    }

    func updateWorkFolderContext(at workFolderRoot: URL, context: String) throws -> WorkFolderContext {
        try inner.updateWorkFolderContext(at: workFolderRoot, context: context)
    }

    func updateSelectedScheme(at workFolderRoot: URL, scheme: String?) throws -> WorkFolderContext {
        try inner.updateSelectedScheme(at: workFolderRoot, scheme: scheme)
    }

    func updateWorkFolderState(
        at workFolderRoot: URL, mutate: (inout WorkFolderState) -> Void
    ) throws -> WorkFolderContext {
        try inner.updateWorkFolderState(at: workFolderRoot, mutate: mutate)
    }

    func updateSettings(
        at workFolderRoot: URL, mutate: (inout ProjectSettings) -> Void
    ) throws -> WorkFolderContext {
        if failUpdateSettings { throw Refused(what: "updateSettings") }
        return try inner.updateSettings(at: workFolderRoot, mutate: mutate)
    }

    func updateTeams(
        at workFolderRoot: URL, mutate: (inout [Team]) -> Void
    ) throws -> WorkFolderContext {
        updateTeamsCalls += 1
        return try inner.updateTeams(at: workFolderRoot, mutate: mutate)
    }

    func resetWorkFolderSettings(at workFolderRoot: URL) throws -> WorkFolderContext {
        try inner.resetWorkFolderSettings(at: workFolderRoot)
    }

    // MARK: TaskRepository

    func createTask(
        at workFolderRoot: URL, title: String, supervisorTask: String,
        preferredTeamID: NTMSID?, parentTaskID: Int?, parentRoleID: String?,
        delegationDepth: Int, makeActive: Bool
    ) throws -> (snapshot: WorkFolderContext, taskID: Int) {
        if failCreateTask { throw Refused(what: "createTask") }
        return try inner.createTask(
            at: workFolderRoot, title: title, supervisorTask: supervisorTask,
            preferredTeamID: preferredTeamID, parentTaskID: parentTaskID,
            parentRoleID: parentRoleID, delegationDepth: delegationDepth, makeActive: makeActive)
    }

    func setActiveTask(at workFolderRoot: URL, taskID: Int?) throws -> WorkFolderContext {
        if failSetActiveTask { throw Refused(what: "setActiveTask") }
        return try inner.setActiveTask(at: workFolderRoot, taskID: taskID)
    }

    func setActiveTaskID(at workFolderRoot: URL, taskID: Int?) throws {
        if failSetActiveTaskID { throw Refused(what: "setActiveTaskID") }
        try inner.setActiveTaskID(at: workFolderRoot, taskID: taskID)
    }

    func deleteTask(at workFolderRoot: URL, taskID: Int) throws -> WorkFolderContext {
        if failDeleteTask { throw Refused(what: "deleteTask") }
        return try inner.deleteTask(at: workFolderRoot, taskID: taskID)
    }

    func loadTask(at workFolderRoot: URL, taskID: Int) throws -> NTMSTask {
        try inner.loadTask(at: workFolderRoot, taskID: taskID)
    }

    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws {
        if cancelUpdateTaskOnly { throw CancellationError() }
        if failUpdateTaskOnly { throw Refused(what: "updateTaskOnly") }
        try inner.updateTaskOnly(at: workFolderRoot, task: task)
    }

    // MARK: ToolRepository

    func updateTools(at workFolderRoot: URL, tools: [ToolDefinitionRecord]) throws -> WorkFolderContext {
        try inner.updateTools(at: workFolderRoot, tools: tools)
    }

    // MARK: ArtifactRepository

    func persistStepArtifactFile(
        at workFolderRoot: URL, taskID: Int, runID: Int, roleID: String,
        artifactName: String, content: String
    ) throws -> String {
        try inner.persistStepArtifactFile(
            at: workFolderRoot, taskID: taskID, runID: runID, roleID: roleID,
            artifactName: artifactName, content: content)
    }

    func persistStepArtifactBinary(
        at workFolderRoot: URL, taskID: Int, runID: Int, roleID: String,
        artifactName: String, data: Data, fileExtension: String
    ) throws -> String {
        try inner.persistStepArtifactBinary(
            at: workFolderRoot, taskID: taskID, runID: runID, roleID: roleID,
            artifactName: artifactName, data: data, fileExtension: fileExtension)
    }

    // MARK: AttachmentRepository

    func stageAttachment(at workFolderRoot: URL, draftID: UUID, sourceURL: URL) throws -> String {
        try inner.stageAttachment(at: workFolderRoot, draftID: draftID, sourceURL: sourceURL)
    }

    func finalizeAttachments(
        at workFolderRoot: URL, taskID: Int,
        stagedEntries: [(path: String, isProjectReference: Bool)]
    ) throws -> [String] {
        try inner.finalizeAttachments(
            at: workFolderRoot, taskID: taskID, stagedEntries: stagedEntries)
    }

    func finalizeAutovisorGoalAttachment(
        at workFolderRoot: URL, stagedRelativePath: String
    ) throws -> String {
        try inner.finalizeAutovisorGoalAttachment(
            at: workFolderRoot, stagedRelativePath: stagedRelativePath)
    }

    func removeStagedItem(at workFolderRoot: URL, relativePath: String) throws {
        if failRemoveStagedItem { throw Refused(what: "removeStagedItem") }
        try inner.removeStagedItem(at: workFolderRoot, relativePath: relativePath)
    }

    func cleanupStagedDraft(at workFolderRoot: URL, draftID: UUID) throws {
        if failCleanupStagedDraft { throw Refused(what: "cleanupStagedDraft") }
        try inner.cleanupStagedDraft(at: workFolderRoot, draftID: draftID)
    }

    func cleanupAllStagedDrafts(at workFolderRoot: URL) throws {
        try inner.cleanupAllStagedDrafts(at: workFolderRoot)
    }
}

// MARK: - In-memory / streaming / forwarding tail

/// The orchestrator's in-memory mutation, streaming-delegate and lifecycle-wiring
/// arms that no scenario suite reached.
///
/// Each of these is a place where the orchestrator either RECOVERS from a
/// desynchronised snapshot or FORWARDS a delegate call to a collaborator. A
/// forwarding witness that silently does nothing is invisible in every unit test
/// of the collaborator itself — which is exactly the shape of the gap here: the
/// `DelegationLoopWatcher` is thoroughly tested, its orchestrator-side witness
/// was not.
@MainActor
final class AOrchStreamingTailTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: mutateTaskInMemory — index recovery (`+Streaming` L25)

    /// The `else` arm of the index update: the active task is missing from the
    /// in-memory tasks index. The sidebar renders exclusively from that index, so
    /// the row must be RE-ADDED, not dropped — a drop is a task that vanishes from
    /// the UI while still existing on disk and still running.
    ///
    /// RED: replace the `else { tasksIndex.tasks.append(summary) }` arm with a
    /// no-op -> the "must be re-added" assertion fails (index count stays 0).
    func testMutateTaskInMemory_activeTaskMissingFromIndex_reAddsTheSummary() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Original", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        // Desynchronise the snapshot the way the branch defends against.
        sut.snapshot?.tasksIndex.tasks.removeAll(where: { $0.id == taskID })
        XCTAssertTrue(
            sut.snapshot?.tasksIndex.tasks.contains(where: { $0.id == taskID }) == false,
            "precondition: the index must be missing the active task, or the `if` arm runs instead")

        sut.mutateTaskInMemory(taskID: taskID, { $0.title = "Recovered" }, updateIndex: true)

        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.title,
            "Recovered",
            "an active task missing from the index must be re-added, not dropped — "
                + "the sidebar reads the index and nothing else re-seeds it")
    }

    /// `applyTaskUpdate`'s twin of the same recovery (`NTMSOrchestrator` L751),
    /// reached through the persisted `mutateTask` path rather than the in-memory one.
    ///
    /// RED: drop the `else { append }` arm in `applyTaskUpdate` -> the summary is
    /// never restored and the assertion fails.
    func testMutateTask_activeTaskMissingFromIndex_reAddsTheSummary() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Original", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        sut.snapshot?.tasksIndex.tasks.removeAll(where: { $0.id == taskID })
        XCTAssertTrue(
            sut.snapshot?.tasksIndex.tasks.contains(where: { $0.id == taskID }) == false,
            "precondition: the `else` arm only runs when the summary is absent")

        let persisted = await sut.mutateTask(taskID: taskID) { $0.title = "Recovered" }

        XCTAssertTrue(persisted)
        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.title,
            "Recovered",
            "applyTaskUpdate must restore the missing index entry")
    }

    // MARK: noteStreamLoop witness (`+Streaming` L82-84)

    /// A TOP-LEVEL task has no parent role awaiting it, so an in-stream loop signal
    /// must fire nothing and tell the scanner to advance its throttle baseline.
    ///
    /// RED: make the witness fire unconditionally (drop the child gate in the
    /// watcher, or route to a different watcher) -> `_testLastTrigger` becomes
    /// non-nil and the assertion fails.
    func testNoteStreamLoop_topLevelTask_advancesBaselineWithoutFiring() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Top level", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }

        let advance = sut.noteStreamLoop(
            taskID: taskID, stepID: "any", signal: .withinMessage(diagnostic: "loop loop loop"))

        XCTAssertTrue(advance, "nothing to re-scan for on a task with no parent awaiter")
        XCTAssertNil(
            sut.delegationLoopWatcher._testLastTrigger(forTaskID: taskID),
            "a top-level task must never record a delegation-interrupt cooldown")
    }

    /// The discriminating half: a CHILD task with no registered awaiter is the I4
    /// race, and the witness must report `false` so the in-stream scanner HOLDS its
    /// baseline and re-scans once the parent awaiter appears.
    ///
    /// `false` is only producible by the real watcher, so this is what proves the
    /// orchestrator's witness forwards rather than answering on its own.
    ///
    /// RED: stub the witness to `return true` (or `return false` unconditionally,
    /// which then fails the top-level test above) -> this assertion fails.
    func testNoteStreamLoop_childTaskWithNoWaiter_holdsBaseline() async {
        await sut.openWorkFolder(tempDir)
        guard let parentID = await sut.createTask(title: "Parent", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        guard let childID = await sut.createDelegatedTask(
            parentTaskID: parentID,
            parentRoleID: "coding_agent",
            title: "Child",
            supervisorTask: "delegated",
            preferredTeamID: nil,
            depth: 1
        ) else {
            return XCTFail("delegated task creation failed")
        }
        XCTAssertNotNil(
            sut.loadedTask(childID)?.parentTaskID,
            "precondition: the child gate reads `parentTaskID` off the loaded task")
        XCTAssertFalse(
            sut.completionAwaiter.hasWaiters(for: childID),
            "precondition: no waiter, so the fire must fail and the baseline must hold")

        let advance = sut.noteStreamLoop(
            taskID: childID, stepID: "engineer", signal: .withinMessage(diagnostic: "loop"))

        XCTAssertFalse(
            advance,
            "the no-waiter race must hold the throttle so the next legitimate signal isn't swallowed")
        XCTAssertNil(
            sut.delegationLoopWatcher._testLastTrigger(forTaskID: childID),
            "a failed fire must NOT arm the 30s cooldown")
    }

    // MARK: Processing-progress witnesses (`+Streaming` L166-168)

    /// The prompt-processing percentage the message bubble renders. The witness
    /// must reach the preview manager under the composite `(taskID, stepID)` key —
    /// two concurrent tasks on the same team share a stepID (it IS the role id), so
    /// a stepID-only key would cross-wire their progress rows.
    ///
    /// RED: drop the forwarding body -> `processingStatus` stays empty and the
    /// first assertion fails. Key by stepID alone -> the second task's lookup
    /// returns task A's value and the isolation assertion fails.
    func testUpdateStreamingProcessingProgress_forwardsUnderTheCompositeKey() async {
        sut.updateStreamingProcessingStatus(stepID: "engineer", taskID: 7, status: .fraction(0.42))

        XCTAssertEqual(
            sut.streamingPreviewManager.processingStatus[
                TaskStepKey(taskID: 7, stepID: "engineer")],
            .fraction(0.42))
        XCTAssertNil(
            sut.streamingPreviewManager.processingStatus[
                TaskStepKey(taskID: 8, stepID: "engineer")],
            "the same role id in another task must not inherit this progress")
    }

    /// The indeterminate status takes the same hop and the same composite key.
    /// Pinned separately because it is the ONLY status Ollama ever produces — a
    /// forwarding regression that happened to keep `.fraction` working would
    /// leave that provider with no indicator at all.
    ///
    /// RED: drop the forwarding body -> `processingStatus` stays empty and the
    /// first assertion fails. Key by stepID alone -> the isolation assertion fails.
    func testUpdateStreamingProcessingStatus_indeterminate_forwardsUnderTheCompositeKey() async {
        sut.updateStreamingProcessingStatus(stepID: "engineer", taskID: 7, status: .indeterminate)

        XCTAssertEqual(
            sut.streamingPreviewManager.processingStatus[
                TaskStepKey(taskID: 7, stepID: "engineer")],
            .indeterminate)
        XCTAssertNil(
            sut.streamingPreviewManager.processingStatus[
                TaskStepKey(taskID: 8, stepID: "engineer")],
            "the same role id in another task must not inherit this status")
    }

    /// Its clearing twin, so a regression that forwards the update but not the
    /// clear (leaving "Processing 99%" frozen for the whole generation) is caught.
    ///
    /// RED: drop the forwarding body of `clearStreamingProcessingStatus` -> the
    /// value survives and the assertion fails.
    func testClearStreamingProcessingProgress_removesTheEntry() async {
        sut.updateStreamingProcessingStatus(stepID: "engineer", taskID: 7, status: .fraction(0.99))

        sut.clearStreamingProcessingStatus(stepID: "engineer", taskID: 7)

        XCTAssertNil(
            sut.streamingPreviewManager.processingStatus[
                TaskStepKey(taskID: 7, stepID: "engineer")],
            "a stale progress value renders as a frozen 'Processing 99%' indicator")
    }

    // MARK: Embedding-lifecycle warning wiring (`NTMSOrchestrator` L547)

    /// A VRAM-reclaim warning is INFORMATION, not a failure: keyword search keeps
    /// working and the Exploratory Search card surfaces the detail. Routing it to
    /// the red banner would claim an app-wide error for a server-side leak.
    ///
    /// RED: change the closure body to `self?.lastErrorMessage = message` ->
    /// `errorSurfaceCount` increments and the "must not banner as an error"
    /// assertion fails.
    func testEmbeddingLifecycleWarning_routesToTheInfoBannerNotTheErrorBanner() async {
        let errorsBefore = sut.errorSurfaceCount

        sut.embeddingLifecycle.onWarning?("Couldn't query loaded models on http://x")

        XCTAssertEqual(
            sut.lastInfoMessage, "Couldn't query loaded models on http://x",
            "the lifecycle service's warning must reach the user verbatim")
        XCTAssertEqual(
            sut.errorSurfaceCount, errorsBefore,
            "a reclaim warning must not surface as an app-wide error")
    }

    // MARK: Search-index coordinator install race (`+WorkFolderManagement` L323-325)

    /// `setUpSearchIndexCoordinatorIfEnabled` awaits `coordinator.start()`, so a
    /// concurrent caller can install one in the meantime. The loser must yield —
    /// tear its own coordinator down and leave the installed one alone — or the
    /// winner's `FileSystemWatcher` is orphaned with no reference to stop it.
    ///
    /// The decoy is installed WHILE the setup is suspended inside `start()`, which
    /// is what makes the loser branch deterministic rather than scheduler-dependent.
    ///
    /// RED: delete the `if searchIndexCoordinator != nil { … return }` guard -> the
    /// setup overwrites the decoy with its own coordinator and the identity
    /// assertion fails.
    func testSetUpSearchIndexCoordinator_lostRace_yieldsToTheInstalledCoordinator() async {
        sut.configuration.exploratorySearchEnabled = true
        await sut.openWorkFolder(tempDir)
        // The open already installed one; clear the slot so the racing setup below
        // starts from the same state a first-time enable does.
        await sut.tearDownSearchIndexCoordinator()
        XCTAssertNil(sut.searchIndexCoordinator, "precondition: the slot must start empty")

        let orchestrator = sut!
        let setup = Task { @MainActor in
            await orchestrator.setUpSearchIndexCoordinatorIfEnabled()
        }
        // Exactly one yield: it hands the main actor to the setup task, which runs
        // until its FIRST suspension — `await vectorIndex.load()` inside `start()`,
        // an actor hop. Resuming this test consumes the next main-actor slot, so the
        // setup cannot have progressed past that suspension to the install.
        await Task.yield()
        XCTAssertNil(
            sut.searchIndexCoordinator,
            "precondition: the racing setup must still be suspended inside start(); "
                + "if this fires, start() stopped suspending and the race is no longer reproducible")

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let decoy = SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: paths.internalDir,
            embeddingClient: StubSearchEmbeddingClient(),
            fileManager: FileManager.default,
            makeWatcher: FakeWatcherFactory.inert,
            watcherDebounce: 0.05
        )
        sut.searchIndexCoordinator = decoy

        await setup.value

        XCTAssertTrue(
            sut.searchIndexCoordinator === decoy,
            "the racing setup must yield to the coordinator that won the install; "
                + "overwriting it orphans the winner's FSEventStream")
        await sut.tearDownSearchIndexCoordinator()
    }
}

// MARK: - Generated-team role skills

/// `attachedSkillIDsAcrossTeams` collects skill ids from `workFolder.teams` AND
/// from every task-owned GENERATED team. The second loop is the one that is easy
/// to lose: a generated team lives on the task, never in `teams.json`, and the
/// ACTIVE task is deliberately absent from `loadedTasks` — so it needs its own
/// check on top of the loaded-tasks sweep.
///
/// Dropping that loop is silent: the role's system prompt simply ships without
/// the skill body it was configured with, and nothing reports it.
@MainActor
final class AOrchGeneratedTeamSkillsTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Writes a project skill and returns the id the scanner assigns to it — the
    /// id shape is the scanner's business, so it is derived rather than spelled out.
    private func writeProjectSkill(_ name: String, body: String) throws -> String {
        let dir = tempDir.appendingPathComponent(".claude/skills/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let isolatedHome = tempDir.appendingPathComponent("__probe_home__")
        try? FileManager.default.createDirectory(
            at: isolatedHome, withIntermediateDirectories: true)
        let probe = AgentSkillsScanner.scan(projectRoot: tempDir, homeDirectory: isolatedHome)
        guard let id = probe.items.first(where: { $0.name == name && $0.origin == .project })?.id
        else {
            XCTFail("scanner did not discover the project skill just written")
            return ""
        }
        return id
    }

    /// A skill attached ONLY to a generated team's role — no bundled team carries
    /// it — must still have its body read, because that role's next step ships it
    /// in the system prompt.
    ///
    /// The generated team is put on the ACTIVE task on purpose: `loadedTasks` never
    /// contains the active task, so a sweep that only walked `loadedTasks` would
    /// miss precisely the task the user is looking at.
    ///
    /// RED: delete the `for task in …` loop over `generatedTeam?.roles` -> the id
    /// never enters `attachedIDs`, its body is never read, and the assertion fails.
    func testAttachedSkillOnTheActiveTasksGeneratedTeam_hasItsBodyRead() async throws {
        let id = try writeProjectSkill("generated-only", body: "# Generated\nBody text.")
        await sut.openWorkFolder(tempDir)
        XCTAssertNil(
            sut.roleSkills?.bodies[id],
            "precondition: no bundled team attaches this id, so nothing has read it yet")

        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        var generated = TeamTemplateFactory.empty(name: "Generated Roster")
        guard let roleIndex = generated.roles.firstIndex(where: { !$0.isSupervisor }) else {
            return XCTFail("the empty template must ship a non-Supervisor role")
        }
        generated.roles[roleIndex].attachedSkillIDs = [id]
        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(generated) }
        XCTAssertEqual(
            sut.activeTaskID, taskID,
            "precondition: the generated team must sit on the ACTIVE task")
        XCTAssertNil(
            sut.snapshot?.loadedTasks[taskID],
            "precondition: the active task is deliberately absent from loadedTasks")

        sut.roleSkillsLastScanAt = .distantPast
        await sut.refreshAgentSkills()

        XCTAssertEqual(
            sut.roleSkills?.bodies[id], "# Generated\nBody text.",
            "a skill attached to a generated team's role must be resolved — its body "
                + "rides that role's system prompt on the next step")
        XCTAssertFalse(
            sut.roleSkills?.unresolvedIDs.contains(id) ?? true,
            "the id resolved, so it must not also be reported as unresolved")
    }
}

// MARK: - Persist-refusal arms

/// The catch arms that decide whether a refused disk write is VISIBLE, and — for
/// the one refusal that is not a failure at all — whether it stays silent.
@MainActor
final class AOrchPersistRefusalTailTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var repo: AOrchFailingRepository!
    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorch-refusal-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = AOrchFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(repository: repo)
    }

    override func tearDown() async throws {
        sut?.stopAllEngines()
        sut = nil
        repo = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: mutateTask — cancellation is not a failure (`+StateMutation` L45 / L69)

    /// Pause, a work-folder switch and `cancelAllExecutions` all cancel in-flight
    /// task writes. That is the user's own action, not a disk problem — surfacing
    /// "Failed to save task" for it trains the user to ignore a banner that also
    /// carries real disk errors.
    ///
    /// The discriminator is the banner, not the return value (both arms return
    /// `false`), and it is read through the non-consumable `errorSurfaceCount`
    /// because `lastErrorMessage` is a single-shot slot.
    ///
    /// RED: delete `catch is CancellationError { return false }` from the ACTIVE
    /// branch -> the generic catch banners and `errorSurfaceCount` increments.
    func testMutateTask_activeTask_cancelledWrite_returnsFalseAndDoesNotBanner() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Original", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        XCTAssertEqual(sut.activeTaskID, taskID, "precondition: this must take the ACTIVE branch")
        let errorsBefore = sut.errorSurfaceCount
        repo.cancelUpdateTaskOnly = true

        let persisted = await sut.mutateTask(taskID: taskID) { $0.title = "cancelled edit" }

        XCTAssertFalse(persisted, "a cancelled write did not persist")
        XCTAssertEqual(
            sut.errorSurfaceCount, errorsBefore,
            "a cancelled write is the user pausing, not a disk failure — it must not banner")
        XCTAssertEqual(
            sut.activeTask?.title, "cancelled edit",
            "the documented trade-off: the in-memory mutation is kept even when the write didn't land")
    }

    /// The BACKGROUND branch's twin. It is a separate `do/catch` in the source, so
    /// a fix applied to only one of the two leaves the other bannering.
    ///
    /// RED: delete `catch is CancellationError` from the background branch ->
    /// `errorSurfaceCount` increments.
    func testMutateTask_backgroundTask_cancelledWrite_returnsFalseAndDoesNotBanner() async {
        await sut.openWorkFolder(tempDir)
        guard let first = await sut.createTask(title: "First", supervisorTask: "brief"),
              let second = await sut.createTask(title: "Second", supervisorTask: "brief")
        else { return XCTFail("task creation failed") }
        XCTAssertEqual(
            sut.activeTaskID, second,
            "precondition: `first` must be in the background so the else branch runs")
        let errorsBefore = sut.errorSurfaceCount
        repo.cancelUpdateTaskOnly = true

        let persisted = await sut.mutateTask(taskID: first) { $0.title = "cancelled edit" }

        XCTAssertFalse(persisted)
        XCTAssertEqual(
            sut.errorSurfaceCount, errorsBefore,
            "the background branch must treat cancellation the same way as the active branch")
        XCTAssertEqual(sut.loadedTask(first)?.title, "cancelled edit")
    }

    /// The control that keeps the two tests above honest: a genuine disk refusal on
    /// the SAME call site must still banner. Without this, "never banner from
    /// `updateTaskOnly`" would satisfy them both.
    ///
    /// RED: widen the cancellation arm to `catch { return false }` -> the real disk
    /// error is swallowed, `errorSurfaceCount` stops moving and this test fails
    /// while the two above stay green.
    func testMutateTask_diskRefusal_stillBanners() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Original", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        let errorsBefore = sut.errorSurfaceCount
        repo.failUpdateTaskOnly = true

        let persisted = await sut.mutateTask(taskID: taskID) { $0.title = "doomed" }

        XCTAssertFalse(persisted)
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore + 1)
        XCTAssertTrue(
            sut.lastSurfacedError?.hasPrefix("Failed to save task:") == true,
            "got: \(sut.lastSurfacedError ?? "nil")")
    }

    // MARK: switchTask — the two catch arms say different things (`+TaskLifecycle` L80 / L100)

    /// FAST path: the switch already happened in memory; only the pointer write for
    /// app-restart restoration failed. The message must therefore come from
    /// `activeTaskPointerErrorMessage`, whose whole job is to classify the recoverable
    /// Cocoa categories and to say the switch won't survive a restart.
    ///
    /// `SwitchTaskErrorClassificationTests` pins that classifier as a pure function
    /// but never as the value this catch arm actually uses — a regression to
    /// `lastErrorMessage = error.localizedDescription` here leaves all seven of those
    /// tests green.
    ///
    /// RED: replace the body with `error.localizedDescription` -> the message becomes
    /// "Refused: setActiveTaskID", which contains neither asserted phrase.
    func testSwitchTask_fastPath_pointerWriteRefused_usesTheClassifiedMessage() async {
        await sut.openWorkFolder(tempDir)
        guard let first = await sut.createTask(title: "First", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        guard await sut.createTask(title: "Second", supervisorTask: "brief") != nil else {
            return XCTFail("second task creation failed")
        }
        XCTAssertNotNil(
            sut.snapshot?.loadedTasks[first],
            "precondition: the target must be cached, or `switchTask` takes the slow path")
        repo.failSetActiveTaskID = true

        await sut.switchTask(to: first)

        XCTAssertEqual(
            sut.activeTaskID, first,
            "the in-memory switch itself succeeded — only the pointer write failed")
        let message = sut.lastSurfacedError ?? ""
        XCTAssertTrue(
            message.contains("Could not save active-task pointer"),
            "the fast path must route through the classifier; got: \(message)")
        XCTAssertTrue(
            message.contains("will not persist across app restarts"),
            "the user must be told the switch is memory-only; got: \(message)")
    }

    /// SLOW path: `taskService.switchTask` refused, so NOTHING happened — there is no
    /// partially-applied switch to warn about. The arm deliberately surfaces the raw
    /// cause instead of the pointer-write copy, which would claim a switch that
    /// never took place.
    ///
    /// RED: route this arm through `activeTaskPointerErrorMessage` -> the
    /// "must NOT claim a restart-persistence problem" assertion fails.
    func testSwitchTask_slowPath_refused_surfacesTheRawCauseNotThePointerCopy() async {
        await sut.openWorkFolder(tempDir)
        guard let first = await sut.createTask(title: "First", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        guard await sut.createTask(title: "Second", supervisorTask: "brief") != nil else {
            return XCTFail("second task creation failed")
        }
        // Evict the target from memory — the production state after an app restart,
        // or after the scheduler's `evictIfReclaimable`. That is precisely what makes
        // `switchTask` take the slow path.
        sut.snapshot?.loadedTasks.removeValue(forKey: first)
        XCTAssertNil(
            sut.snapshot?.loadedTasks[first],
            "precondition: a cached target would take the fast path and this test would be vacuous")
        repo.failSetActiveTask = true

        await sut.switchTask(to: first)

        let message = sut.lastSurfacedError ?? ""
        XCTAssertEqual(
            message, "Refused: setActiveTask",
            "a refused switch surfaces its own cause; got: \(message)")
        XCTAssertFalse(
            message.contains("will not persist across app restarts"),
            "nothing was switched, so promising a memory-only switch would be false")
    }

    // MARK: removeTask (`+TaskLifecycle` L157)

    /// A refused delete must be loud. The sidebar row disappears from nothing — the
    /// index write is what removes it — so a swallowed error would leave the task
    /// exactly where it was with no explanation for why "Delete" did nothing.
    ///
    /// RED: swallow the catch -> no banner and the assertion fails.
    func testRemoveTask_deleteRefused_surfacesTheErrorAndKeepsTheTask() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Keep me", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        let errorsBefore = sut.errorSurfaceCount
        repo.failDeleteTask = true

        await sut.removeTask(taskID)

        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore + 1, "a refused delete must be visible")
        XCTAssertEqual(sut.lastSurfacedError, "Refused: deleteTask")
        XCTAssertTrue(
            sut.snapshot?.tasksIndex.tasks.contains(where: { $0.id == taskID }) == true,
            "the task survived the refusal — the UI must not imply otherwise")
    }

    // MARK: Staged-draft cleanup (`+Attachments` L125 / L137)

    /// The staging directory is invisible disk growth under `.nanoteams/staged/`
    /// and nothing else ever collects a specific draft. A refused cleanup that says
    /// nothing leaks silently and forever.
    ///
    /// RED: swallow the catch -> `errorSurfaceCount` doesn't move.
    func testDiscardStagedDraft_cleanupRefused_surfacesTheError() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorch-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let source = outsideDir.appendingPathComponent("note.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        _ = try XCTUnwrap(sut.stageAttachment(url: source, draftID: draftID))
        let errorsBefore = sut.errorSurfaceCount
        repo.failCleanupStagedDraft = true

        sut.discardStagedDraft(draftID: draftID)

        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore + 1)
        XCTAssertEqual(sut.lastSurfacedError, "Refused: cleanupStagedDraft")
    }

    /// Same requirement for the per-attachment removal the "×" badge triggers.
    ///
    /// The source must be OUTSIDE the work folder: an in-folder file is staged as a
    /// project REFERENCE, which `removeStagedAttachment` refuses by design and which
    /// therefore never reaches the repository at all.
    ///
    /// RED: swallow the catch -> no banner.
    func testRemoveStagedAttachment_removalRefused_surfacesTheError() async throws {
        await sut.openWorkFolder(tempDir)
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorch-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let source = outsideDir.appendingPathComponent("note.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let staged = try XCTUnwrap(sut.stageAttachment(url: source, draftID: UUID()))
        XCTAssertFalse(
            staged.isProjectReference,
            "precondition: a project reference short-circuits before the repository call")
        let errorsBefore = sut.errorSurfaceCount
        repo.failRemoveStagedItem = true

        sut.removeStagedAttachment(staged)

        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore + 1)
        XCTAssertEqual(sut.lastSurfacedError, "Refused: removeStagedItem")
    }

    // MARK: createPreparedTaskAndStart (`+Attachments` L48)

    /// When the task record itself cannot be created there is nothing to attach to
    /// and nothing to start. The caller (QuickCapture) keys "keep the user's draft"
    /// off the `nil`, so returning an id here would discard their typing.
    ///
    /// RED: change the `else { return nil }` to fall through -> the subsequent
    /// `finalizeAttachments` / `switchTask` run against a non-existent id and the
    /// "returns nil" assertion fails.
    func testCreatePreparedTaskAndStart_taskCreationRefused_returnsNilAndCreatesNothing() async {
        await sut.openWorkFolder(tempDir)
        repo.failCreateTask = true

        let taskID = await sut.createPreparedTaskAndStart(
            request: TaskCreationRequest(
                title: "New",
                rawSupervisorTask: "do the thing",
                preferredTeamID: nil,
                clippedTexts: [],
                stagedAttachments: []
            ))

        XCTAssertNil(taskID, "a refused creation must report failure so the draft is kept")
        XCTAssertTrue(
            sut.snapshot?.tasksIndex.tasks.isEmpty == true,
            "no half-created task may be left behind")
        XCTAssertEqual(sut.lastSurfacedError, "Refused: createTask")
    }
}

// MARK: - Teams-diff encode failure

/// `mutateWorkFolder` decides whether `teams.json` needs writing by ENCODING both
/// sides and comparing bytes (`Team.==` only compares id + updatedAt, CLAUDE.md
/// #42). That encode can itself throw, and the arm that handles it chooses between
/// two opposite failure modes: assume-changed (attempt the write, surface any real
/// failure) or assume-unchanged (silently drop the user's edit).
@MainActor
final class AOrchTeamsDiffEncodeFailureTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var repo: AOrchFailingRepository!
    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorch-teamsdiff-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = AOrchFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(repository: repo)
    }

    override func tearDown() async throws {
        sut = nil
        repo = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    /// A non-finite graph coordinate makes `JSONEncoder` throw (its default
    /// `nonConformingFloatEncodingStrategy` is `.throw`), which is the documented
    /// trigger for the diff's catch arm.
    ///
    /// The requirement is fail-SAFE: an encode hiccup must be treated as "changed"
    /// so the write is still attempted and any real problem is reported. Treating
    /// it as "unchanged" would drop a team edit with no error at all — the single
    /// worst outcome available at this call site.
    ///
    /// RED: change the catch body to `teamsChanged = false` -> `updateTeamsCalls`
    /// stays 0 and no error surfaces, failing both assertions.
    func testMutateWorkFolder_teamsDiffEncodeThrows_assumesChangedAndStillAttemptsTheWrite() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(sut.workFolder?.teams.isEmpty == true, "precondition: bootstrapped teams")
        repo.resetCounters()
        let errorsBefore = sut.errorSurfaceCount

        await sut.mutateWorkFolder { proj in
            guard !proj.teams.isEmpty else { return }
            proj.teams[0].graphLayout.nodePositions.append(
                TeamNodePosition(roleID: "aorch-nonfinite", x: .infinity, y: 0))
        }

        XCTAssertEqual(
            repo.updateTeamsCalls, 1,
            "an encode hiccup must be treated as 'changed' — assuming 'unchanged' "
                + "would silently discard the user's team edit")
        XCTAssertEqual(
            sut.errorSurfaceCount, errorsBefore + 1,
            "the attempted write fails for the same reason, and that failure must reach the user")
        XCTAssertFalse(
            sut.workFolder?.teams.first?.graphLayout.nodePositions
                .contains(where: { $0.roleID == "aorch-nonfinite" }) == true,
            "nothing landed on disk, so the recovery re-read must not show the mutation either")
    }
}

// MARK: - Bundled-update banner severity

/// The bundled-update report exists to give a DEFERRAL and a SCAN FAILURE opposite
/// handling: one resolves itself next open, the other blocks every team until the
/// user repairs a file. `BundledUpdateReportLatchTests` pins the error half; the
/// info half — the arm the report was introduced to add — was unreached.
@MainActor
final class AOrchBundledUpdateSeverityTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var sut: NTMSOrchestrator!
    private let fm = FileManager.default
    private var paths: NTMSPaths { NTMSPaths(workFolderRoot: tempDir) }

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("aorch-bundled-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sut = TestOrchestrator.make()
    }

    override func tearDown() async throws {
        sut?.stopAllEngines()
        sut = nil
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    /// Seeds a task whose role is `.working` beside a `.running` step — exactly the
    /// pair `NTMSRepository.pinsTeamAsBusy` matches — and rewinds the version
    /// watermark so the reconcile actually runs and defers that team.
    ///
    /// RED: swap the two banner arms (`bannerIsError == true` -> info) -> a deferral
    /// lands on the red banner, `errorSurfaceCount` increments and both assertions fail.
    func testDeferredBundledUpdate_routesToTheInfoBannerNotTheErrorBanner() async throws {
        await sut.openWorkFolder(tempDir)

        let store = AtomicJSONStore()
        let teamsFile = try store.read(TeamsFile.self, from: paths.teamsJSON)
        let candidate = teamsFile.teams.first(where: { team in
            team.roles.contains(where: { !$0.isSupervisor })
        })
        let team = try XCTUnwrap(candidate, "need a bundled team with a non-Supervisor role")
        let roleID = try XCTUnwrap(team.roles.first(where: { !$0.isSupervisor })?.id)

        try fm.createDirectory(at: paths.internalTaskDir(taskID: 0), withIntermediateDirectories: true)
        let run = Run(
            id: 0,
            steps: [StepExecution(id: roleID, role: .softwareEngineer, title: "Step", status: .running)],
            roleStatuses: [roleID: .working],
            teamID: team.id
        )
        let task = NTMSTask(
            id: 0, title: "Busy", supervisorTask: "stay running",
            status: .running, runs: [run], preferredTeamID: team.id
        )
        try store.write(task, to: paths.taskJSON(taskID: 0))
        try store.write(
            TasksIndex(
                schemaVersion: 1,
                tasks: [TaskSummary(id: 0, title: "Busy", status: .running)],
                nextTaskID: 1
            ),
            to: paths.tasksIndexJSON)
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.lastAppliedAppVersion = ""
        state.activeTaskID = nil
        try store.write(state, to: paths.workFolderJSON)

        let errorsBefore = sut.errorSurfaceCount
        sut.lastInfoMessage = nil

        await sut.openWorkFolder(tempDir)

        XCTAssertFalse(
            sut.bundledUpdateReport?.deferred.isEmpty ?? true,
            "precondition: the reconcile must actually have deferred a team, or the "
                + "banner arm under test never runs")
        XCTAssertEqual(
            sut.bundledUpdateReport?.bannerIsError, false,
            "a deferral is informational — it resolves itself on the next open")
        XCTAssertEqual(
            sut.errorSurfaceCount, errorsBefore,
            "a self-healing deferral must never reach the red banner")
        XCTAssertTrue(
            sut.lastInfoMessage?.contains("kept its old prompts") ?? false,
            "the deferral copy must reach the user; got: \(sut.lastInfoMessage ?? "nil")")
    }
}

// MARK: - Task creation with no folder open

/// `createPreparedTaskAndStart` is reachable before any folder has been opened
/// (Quick Capture's global hotkey works from a cold launch). Its first line is a
/// lazy bootstrap, and the restore-last-folder half of that bootstrap is what
/// decides whether the user's task lands in their project or in default storage.
@MainActor
final class AOrchTaskCreationBootstrapTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var configuration: StoreConfiguration!
    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorch-bootstrap-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configuration = TestOrchestrator.makeConfiguration()
        sut = TestOrchestrator.make(configuration: configuration)
    }

    override func tearDown() async throws {
        sut?.stopAllEngines()
        sut = nil
        configuration = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    /// With no folder open, the creation path must bootstrap the LAST-OPENED folder
    /// rather than refusing — and the task must land there, not in default storage.
    ///
    /// This exercises only the restore branch of `bootstrapDefaultStorageIfNeeded`.
    /// The default-storage fallback beneath it writes to
    /// `~/Library/Application Support` and is deliberately not driven from a test
    /// (see the report).
    ///
    /// RED: delete the `if workFolderURL == nil { await bootstrapDefaultStorageIfNeeded() }`
    /// preamble -> the next `guard let workFolderRoot` returns nil and every
    /// assertion fails.
    func testCreatePreparedTaskAndStart_withNoFolderOpen_bootstrapsTheLastOpenedFolder() async {
        configuration.lastOpenedWorkFolderPath = tempDir.path
        XCTAssertNil(sut.workFolderURL, "precondition: nothing is open yet")

        let taskID = await sut.createPreparedTaskAndStart(
            request: TaskCreationRequest(
                title: "",
                rawSupervisorTask: "Draft the migration plan",
                preferredTeamID: nil,
                clippedTexts: [],
                stagedAttachments: []
            ))

        XCTAssertNotNil(taskID, "a cold-launch capture must not be dropped")
        // `.path` on both sides: `URL(fileURLWithPath:)` (what the bootstrap builds
        // from the stored string) has no trailing slash, `tempDir` was built with
        // `isDirectory: true` and does — so URL equality would compare unequal for
        // two URLs naming the same directory.
        XCTAssertEqual(
            sut.workFolderURL?.resolvingSymlinksInPath().path, tempDir.path,
            "the task must land in the user's last project, not in default storage")
        XCTAssertEqual(
            sut.loadedTask(taskID ?? -1)?.title, "Draft the migration plan",
            "an empty title is derived from the brief's first line")
    }
}

// MARK: - Project-reference staging TOCTOU

/// `stageAttachment`'s in-project branch is a check-then-use: it asks the file
/// manager whether the file exists, then reads its attributes. Between those two
/// the file can be gone (a build cleaning its output, a git checkout, the user
/// deleting it), and the catch arm is what decides whether that surfaces or turns
/// into a silent nil.
@MainActor
final class AOrchStagingRaceTailTests: XCTestCase, @unchecked Sendable {

    /// Reports a single named path as existing without creating it — the state the
    /// in-project branch sees when the file is deleted between the check and the
    /// attribute read. Scoped to one path so every other `fileExists` question the
    /// orchestrator asks is answered truthfully.
    private final class PhantomFileManager: FileManager, @unchecked Sendable {
        var phantomPath: String?
        override func fileExists(atPath path: String) -> Bool {
            if let phantomPath, path == phantomPath { return true }
            return super.fileExists(atPath: path)
        }
    }

    private var tempDir: URL!
    private var phantomFM: PhantomFileManager!
    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorch-staging-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        phantomFM = PhantomFileManager()
        sut = TestOrchestrator.make(fileManager: phantomFM)
    }

    override func tearDown() async throws {
        sut = nil
        phantomFM = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    /// The file passes the existence check and is gone by the time its size is read.
    /// The branch must report the cause and return nil — NOT fall through to the
    /// copy path (which would fail again with a less specific message) and NOT
    /// return a `StagedAttachment` claiming a zero-byte file.
    ///
    /// RED: swallow the catch (`catch { return nil }` with no message) -> the
    /// "must name the file" assertion fails and the user sees an attachment that
    /// silently never appears.
    func testStageAttachment_inProjectFileVanishesAfterTheExistsCheck_reportsAndReturnsNil() async {
        await sut.openWorkFolder(tempDir)
        let ghost = tempDir.appendingPathComponent("ghost.txt").standardizedFileURL
        phantomFM.phantomPath = ghost.path
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ghost.path),
            "precondition: the file must really be absent, or the branch never throws")
        sut.lastErrorMessage = nil
        let draftID = UUID()

        let staged = sut.stageAttachment(url: ghost, draftID: draftID)

        XCTAssertNil(staged, "a file that cannot be read must not become an attachment")
        XCTAssertTrue(
            sut.lastSurfacedError?.contains("Cannot read file ghost.txt") ?? false,
            "the failure must name the file so the user can act; got: \(sut.lastSurfacedError ?? "nil")")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: NTMSPaths(workFolderRoot: tempDir)
                    .stagedAttachmentDir(draftID: draftID).path),
            "the in-project branch must not fall through to the copy path")
    }
}

// MARK: - Queued-message backstop witness

/// `notifyQueuedMessageBackstop` is the LLM pipeline's only route into the
/// queued-message backstop. It reaches the process-wide `QuickCaptureController`
/// singleton, so the controller is reset on both sides of the test — a leaked
/// `store` binding here fabricates failures in every other suite that touches it.
@MainActor
final class AOrchQueuedMessageBackstopTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var sut: NTMSOrchestrator!
    private var controller: QuickCaptureController { QuickCaptureController.shared }

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        QuickCaptureController.shared._testReset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aorch-backstop-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sut = TestOrchestrator.make()
    }

    override func tearDown() async throws {
        QuickCaptureController.shared._testReset()
        sut?.stopAllEngines()
        sut = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    /// The witness must actually forward. Driven through the one flush outcome that
    /// is fully synchronous and observable: a completed NON-chat task, whose queue
    /// is discarded with a counted info message (a completed pipeline is reopened
    /// via `restartRole`, not by a stray message).
    ///
    /// RED: make the witness an empty body -> the queue is still non-empty and no
    /// info message appears, failing both assertions.
    func testNotifyQueuedMessageBackstop_forwardsToTheFlush() async {
        await sut.openWorkFolder(tempDir)
        guard let nonChatTeamID = sut.workFolder?.teams.first(where: { !$0.isChatMode })?.id else {
            return XCTFail("need a bundled non-chat team")
        }
        guard let taskID = await sut.createTask(
            title: "Done", supervisorTask: "brief", preferredTeamID: nonChatTeamID)
        else { return XCTFail("task creation failed") }
        XCTAssertFalse(
            sut.loadedTask(taskID)?.isChatMode ?? true,
            "precondition: a chat task takes the restart arm, which is asynchronous")

        controller.store = sut
        guard let queued = QuickCaptureFormState.QueuedChatMessage(
            text: "please also update the changelog", attachments: [], clippedTexts: [])
        else { return XCTFail("queued message construction failed") }
        controller.formState.prependQueuedMessages([queued], for: taskID)
        sut.engineState[taskID] = .done
        sut.lastInfoMessage = nil
        XCTAssertTrue(
            controller.formState.hasQueuedMessage(for: taskID),
            "precondition: something must be queued for the flush to act on")

        sut.notifyQueuedMessageBackstop(taskID: taskID)

        XCTAssertFalse(
            controller.formState.hasQueuedMessage(for: taskID),
            "the witness must reach `tryFlushQueuedMessages` — otherwise the queue "
                + "sits until an unrelated engine-state change happens to fire")
        XCTAssertTrue(
            sut.lastInfoMessage?.contains("discarded — task completed") ?? false,
            "a discarded queue must be reported, not dropped silently; got: "
                + "\(sut.lastInfoMessage ?? "nil")")
    }
}
