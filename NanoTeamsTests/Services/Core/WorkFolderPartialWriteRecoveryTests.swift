import XCTest

@testable import NanoTeams

/// `mutateWorkFolder` writes up to three files sequentially — `workfolder.json`,
/// `settings.json`, `teams.json` — and `AtomicJSONStore` gives per-file atomicity
/// only. There is no cross-file transaction, so a throw on write #2 leaves write
/// #1 on disk. The recovery arm is what keeps memory honest about that: it names
/// the affected files in `lastErrorMessage` and re-reads the folder from disk so
/// the in-memory snapshot matches what actually landed.
///
/// That whole arm was unreachable in the suite, and it is the arm that decides
/// whether a partial write is *visible* or silently reverses itself in the UI
/// while persisting on disk.
///
/// Reaching it needs a repository that refuses one specific narrow writer while
/// the rest behave normally — hence `SelectivelyFailingRepository`, a forwarding
/// decorator over a real `NTMSRepository`. A `FileManager` subclass (the trick
/// `AtomicJSONStoreInjectedFailureTests` uses) cannot express "fail teams.json
/// but not workfolder.json" without matching on path substrings, which is the
/// fragile half of that approach.
@MainActor
final class WorkFolderPartialWriteRecoveryTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var repo: SelectivelyFailingRepository!
    private var sut: NTMSOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-partial-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(repository: repo)
    }

    override func tearDown() async throws {
        sut = nil
        repo = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - The file hint

    /// The hint exists so a user can locate a partial write. It must name every
    /// file the closure *targeted*, not just the one that threw — the earlier
    /// writes are exactly the ones that already landed.
    func testTeamsWriteFails_errorNamesEveryTargetedFile() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateTeams = true

        await sut.mutateWorkFolder { proj in
            proj.settings.context = "changed"
            proj.teams.append(TeamTemplateFactory.empty(name: "Extra"))
        }

        let message = sut.lastErrorMessage ?? ""
        XCTAssertTrue(
            message.contains("Failed to persist work folder changes"),
            "expected the partial-write banner; got \(message)")
        XCTAssertTrue(message.contains("settings.json"), message)
        XCTAssertTrue(message.contains("teams.json"), message)
        XCTAssertFalse(
            message.contains("workfolder.json"),
            "the closure did not touch state; naming it would send the user to the wrong file")
    }

    /// The state-only permutation of the hint. Together with the test above,
    /// this pins that the hint is built from what the closure changed rather
    /// than from a fixed string.
    func testStateWriteFails_errorNamesOnlyWorkfolderJSON() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateWorkFolderState = true

        await sut.mutateWorkFolder { proj in
            proj.state.activeTaskID = 99
        }

        let message = sut.lastErrorMessage ?? ""
        XCTAssertTrue(message.contains("workfolder.json"), message)
        XCTAssertFalse(message.contains("settings.json"), message)
        XCTAssertFalse(message.contains("teams.json"), message)
    }

    /// The full permutation, and the one the hint's `joined(separator:)` exists
    /// for.
    func testAllThreeChanged_hintListsAllThreeInWriteOrder() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateWorkFolderState = true

        await sut.mutateWorkFolder { proj in
            proj.state.activeTaskID = 99
            proj.settings.context = "changed"
            proj.teams.append(TeamTemplateFactory.empty(name: "Extra"))
        }

        let message = sut.lastErrorMessage ?? ""
        XCTAssertTrue(
            message.contains("(workfolder.json, settings.json, teams.json)"),
            "the hint lists targeted files in write order; got \(message)")
    }

    // MARK: - Memory re-sync

    /// The recovery re-read is the point of the arm: after a refused write the
    /// in-memory projection must show DISK, not the closure's optimistic
    /// mutation. Otherwise the UI reports a saved setting that isn't saved, and
    /// the next mutation writes it back believing it was already persisted.
    func testRefusedWrite_inMemorySnapshotIsResyncedFromDisk() async {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder { $0.settings.context = "original" }
        XCTAssertEqual(sut.workFolder?.settings.context, "original")

        repo.failUpdateSettings = true
        await sut.mutateWorkFolder { $0.settings.context = "never persisted" }

        XCTAssertEqual(
            sut.workFolder?.settings.context, "original",
            "the closure's mutation must not survive a refused write")
        XCTAssertNotNil(sut.lastErrorMessage)
    }

    /// The half-landed case: `workfolder.json` succeeds, `teams.json` refuses.
    /// The re-read must surface the state change that DID land — reverting it
    /// would make memory disagree with disk in the other direction, and the next
    /// mutation would write the reverted value back over a good one.
    ///
    /// `activeTeamID` rather than `activeTaskID`: the open path validates the
    /// active-task pointer against the tasks index and nils a dangling one, so a
    /// made-up task id would be erased by the re-read for a reason that has
    /// nothing to do with the partial write.
    func testPartialWrite_theWriteThatLandedSurvivesTheResync() async {
        await sut.openWorkFolder(tempDir)
        let before = sut.workFolder?.state.activeTeamID
        guard let target = sut.workFolder?.teams.first(where: { $0.id != before })?.id else {
            return XCTFail("need a second bundled team to switch to")
        }
        repo.failUpdateTeams = true

        await sut.mutateWorkFolder { proj in
            proj.state.activeTeamID = target
            proj.teams.append(TeamTemplateFactory.empty(name: "Extra"))
        }

        XCTAssertEqual(
            sut.workFolder?.state.activeTeamID, target,
            "workfolder.json was written before teams.json threw; the re-read must show it")
        XCTAssertFalse(
            sut.workFolder?.teams.contains(where: { $0.name == "Extra" }) == true,
            "teams.json never landed")
    }

    /// When even the recovery re-read fails, the arm keeps the pre-closure
    /// snapshot rather than crashing or leaving the optimistic mutation in
    /// place. This is the `try?` on `openOrCreateWorkFolder`.
    func testRecoveryReadAlsoFails_keepsThePreClosureSnapshot() async {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder { $0.settings.context = "original" }

        repo.failUpdateSettings = true
        repo.failOpenOrCreate = true
        await sut.mutateWorkFolder { $0.settings.context = "never persisted" }

        XCTAssertEqual(sut.workFolder?.settings.context, "original")
        XCTAssertNotNil(sut.lastErrorMessage)
    }

    // MARK: - The no-op fast path

    /// A closure that changes nothing must not write, must not re-read, and must
    /// not banner. `mutateWorkFolder` is called from hot paths that compute
    /// "is a change needed?" inside the closure.
    func testNoOpClosure_writesNothing() async {
        await sut.openWorkFolder(tempDir)
        repo.resetCounters()

        await sut.mutateWorkFolder { _ in }

        XCTAssertEqual(repo.updateStateCalls, 0)
        XCTAssertEqual(repo.updateSettingsCalls, 0)
        XCTAssertEqual(repo.updateTeamsCalls, 0)
        XCTAssertNil(sut.lastErrorMessage)
    }

    /// A team mutated in place with no `updatedAt` bump: `Team.==` compares only
    /// `id + updatedAt` (CLAUDE.md #42), so a plain `!=` reports "unchanged" and
    /// the user's edit is silently dropped. The JSON-encoded diff is what stops
    /// that, and nothing else pinned it from this side of the call.
    func testStructuralTeamEditWithoutTimestampBump_stillWritesTeamsJSON() async {
        await sut.openWorkFolder(tempDir)
        repo.resetCounters()

        await sut.mutateWorkFolder { proj in
            guard !proj.teams.isEmpty else { return }
            let stamp = proj.teams[0].updatedAt
            proj.teams[0].description = "structurally different, same timestamp"
            proj.teams[0].updatedAt = stamp
        }

        XCTAssertEqual(
            repo.updateTeamsCalls, 1,
            "a structural team edit with an unchanged timestamp must still reach teams.json")
    }

    // MARK: - Downstream catch arms sharing the same repository

    /// `updateWorkFolderContext`, `updateSelectedScheme`, `saveToolDefinitions`
    /// and `resetWorkFolderSettings` each own a one-line catch that turns a disk
    /// refusal into a banner. Each was uncovered; a swallowed `catch {}` there is
    /// indistinguishable from success.
    func testUpdateWorkFolderContext_diskRefusal_surfacesTheError() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateSettings = true

        await sut.updateWorkFolderContext("nope")

        XCTAssertNotNil(sut.lastErrorMessage)
    }

    /// The refusal is the writer's answer too, not only a banner: until 2026-11-13 it answered
    /// `.written`, and the Settings page records its own save on that answer — it would have
    /// taken unsaved edits for stored ones.
    func testUpdateWorkFolderContext_diskRefusal_answersFailed_andMemoryKeepsTheStoredText() async {
        await sut.openWorkFolder(tempDir)
        await sut.updateWorkFolderContext("kept")
        repo.failUpdateSettings = true

        let write = await sut.updateWorkFolderContext("nope")

        guard case .failed(let reason) = write else {
            return XCTFail("a refused settings.json write answers .failed, got \(write)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(sut.workFolder?.settings.context, "kept", "memory holds what is on disk")
    }

    /// An external agent whose write cannot reach `settings.json` is told it failed, with the
    /// reason the person's banner shows — never `ok` — and the stored text stays.
    func testSetWorkFolderContext_diskRefusal_isAFailedCall_andTheStoredTextStays() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        await sut.updateWorkFolderContext("kept")
        let agent = try sut.hostedMCPAgentStore.createAgent(label: "Claude Code").record.identity
        try sut.setHostedMCPAgentMayReplaceWorkFolderContext(true, agentID: agent.id)
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
        let revision = try XCTUnwrap(sut.workFolder?.settings.contextRevision)
        repo.failUpdateSettings = true

        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.setWorkFolderContext,
            args: ["folder_id": folderID, "content": "lost", NTMSOrchestrator.expectedRevisionKey: revision],
            agent: agent)

        XCTAssertTrue(result.isError, result.outputJSON)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, ToolErrorCode.commandFailed.rawValue)
        XCTAssertTrue((error["message"] as? String ?? "").contains("settings.json"), "\(error)")
        XCTAssertEqual(sut.workFolder?.settings.context, "kept")
    }

    func testUpdateSelectedScheme_diskRefusal_surfacesTheError() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateSettings = true

        await sut.updateSelectedScheme("MyScheme")

        XCTAssertNotNil(sut.lastErrorMessage)
    }

    func testSaveToolDefinitions_diskRefusal_surfacesTheError() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateTools = true

        await sut.saveToolDefinitions([])

        XCTAssertNotNil(sut.lastErrorMessage)
    }

    /// Tip dismissals live in UserDefaults and are cleared unconditionally —
    /// the user pressed reset, so tips reappear whether or not the disk half
    /// succeeds. Pinned here because it is the one side effect that deliberately
    /// escapes the `do` block.
    func testResetWorkFolderSettings_diskRefusal_stillClearsTipDismissals() async {
        await sut.openWorkFolder(tempDir)
        sut.configuration.dismissedFeatureTipIDs = ["llm"]
        repo.failResetWorkFolderSettings = true

        await sut.resetWorkFolderSettings()

        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertTrue(sut.configuration.dismissedFeatureTipIDs.isEmpty)
    }

    // MARK: - Guard arms

    /// Nothing is written with no folder open — and the caller hears why. Until 2026-11-08 this
    /// arm returned in silence, so a Team Editor Save in that state looked exactly like a save
    /// that landed (`mutateTask`'s own guard has always said so).
    ///
    /// RED: restore the bare `return` → `outcome` is not `.failed` and nothing surfaces.
    func testMutateWorkFolder_withNoFolderOpen_writesNothingAndSaysWhy() async {
        let errorsBefore = sut.errorSurfaceCount

        let outcome = await sut.mutateWorkFolder { $0.settings.context = "x" }

        let reason = outcome.failureReason
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("no work folder is open") == true, reason ?? "nil")
        XCTAssertEqual(sut.errorSurfaced(since: errorsBefore), reason)
        XCTAssertNil(sut.workFolder)
        XCTAssertEqual(repo.updateSettingsCalls, 0)
    }

    /// The second guard: a folder whose open failed has a URL but no contents to diff against
    /// (`discardWorkFolderState`). Writing nothing is right; saying nothing was not.
    func testMutateWorkFolder_afterAFailedOpen_writesNothingAndSaysWhy() async {
        repo.failOpenOrCreate = true
        await sut.openWorkFolder(tempDir)
        XCTAssertNotNil(sut.workFolderURL, "precondition: the failed open commits its URL")
        XCTAssertNil(sut.snapshot, "precondition: and holds no contents")
        let errorsBefore = sut.errorSurfaceCount

        let outcome = await sut.mutateWorkFolder { $0.settings.context = "x" }

        let reason = outcome.failureReason
        XCTAssertTrue(reason?.contains("not loaded") == true, reason ?? "nil")
        XCTAssertEqual(sut.errorSurfaced(since: errorsBefore), reason)
        XCTAssertEqual(repo.updateSettingsCalls, 0)
    }

    /// A refused write answers with the very message the person was shown — the caller that
    /// waited needs no counter to find it.
    func testMutateWorkFolder_refusedWrite_returnsTheSurfacedReason() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateTeams = true
        let errorsBefore = sut.errorSurfaceCount

        let outcome = await sut.mutateWorkFolder { $0.teams.append(TeamTemplateFactory.empty(name: "Extra")) }

        XCTAssertNotNil(outcome.failureReason)
        XCTAssertEqual(outcome.failureReason, sut.errorSurfaced(since: errorsBefore))
    }
}

// MARK: - Selectively failing repository

/// Forwards every `NTMSRepositoryProtocol` call to a real `NTMSRepository` except
/// the ones a test switches off. Refusals are the only deviation, so the folder
/// on disk is genuinely written and every assertion is about real files.
///
/// A struct, matching `NTMSRepository` — but the flags have to be mutable across
/// the `Sendable` boundary the protocol requires, so state lives in a reference
/// box the orchestrator's copy shares with the test's.
final class SelectivelyFailingRepository: NTMSRepositoryProtocol, @unchecked Sendable {

    struct Refused: LocalizedError {
        let what: String
        var errorDescription: String? { "Refused: \(what)" }
    }

    private let inner: NTMSRepository

    var failOpenOrCreate = false
    var failUpdateWorkFolderState = false
    var failUpdateSettings = false
    var failUpdateTeams = false
    var failResetWorkFolderSettings = false
    var failUpdateTools = false
    var failCreateTask = false
    var failRemoveStagedItem = false

    private(set) var updateStateCalls = 0
    private(set) var updateSettingsCalls = 0
    private(set) var updateTeamsCalls = 0

    init(wrapping inner: NTMSRepository) { self.inner = inner }

    func resetCounters() {
        updateStateCalls = 0
        updateSettingsCalls = 0
        updateTeamsCalls = 0
    }

    /// The hold an `openOrCreateWorkFolder` of that folder path waits on before reading, until the
    /// test releases it (`OpenReadHold`). The open runs off the main actor
    /// (`WorkFolderManagementService`), so this makes one read finish after a later open's — the
    /// overlap the folder-lifecycle suites need — at the moment the test chooses rather
    /// than after a delay it guessed. Set before the open starts; read from the detached task.
    var openReadHolds: [String: OpenReadHold] {
        get { openReadHoldsLock.withLock { _openReadHolds } }
        set { openReadHoldsLock.withLock { _openReadHolds = newValue } }
    }
    private let openReadHoldsLock = NSLock()
    private var _openReadHolds: [String: OpenReadHold] = [:]

    /// Releases every read hold, and hands them back by folder path — what a `tearDown` calls
    /// first, since a held reader never returns on its own before its cap.
    func releaseAllOpenReads() -> [String: OpenReadHold] {
        let holds = openReadHolds
        for hold in holds.values { hold.release() }
        return holds
    }

    /// Folder paths whose open is refused, where `failOpenOrCreate` refuses every folder.
    var openFailurePaths: Set<String> = []
    /// Folder paths whose read hands back this bundled-update report, as a folder whose prompt
    /// update was blocked or deferred does — what a test needs to see an open's banner.
    var openedBundledUpdates: [String: BundledUpdateReport] = [:]
    /// Folder paths whose `openOrCreateWorkFolder` has STARTED, in call order — how a test knows
    /// an open is inside its read. Appended on the detached task, read on the main actor.
    var openStarts: [String] { openStartsLock.withLock { _openStarts } }
    private let openStartsLock = NSLock()
    private var _openStarts: [String] = []

    // MARK: WorkFolderRepository

    func openOrCreateWorkFolder(at workFolderRoot: URL) throws -> WorkFolderContext {
        openStartsLock.withLock { _openStarts.append(workFolderRoot.path) }
        openReadHolds[workFolderRoot.path]?.holdRead()
        if failOpenOrCreate || openFailurePaths.contains(workFolderRoot.path) {
            throw Refused(what: "openOrCreateWorkFolder")
        }
        var context = try inner.openOrCreateWorkFolder(at: workFolderRoot)
        if let report = openedBundledUpdates[workFolderRoot.path] { context.bundledUpdate = report }
        return context
    }

    func updateWorkFolderState(
        at workFolderRoot: URL, activeTask: NTMSTask?, mutate: (inout WorkFolderState) -> Void
    ) throws -> WorkFolderContext {
        updateStateCalls += 1
        if failUpdateWorkFolderState { throw Refused(what: "updateWorkFolderState") }
        return try inner.updateWorkFolderState(at: workFolderRoot, activeTask: activeTask, mutate: mutate)
    }

    func updateSettings(
        at workFolderRoot: URL, activeTask: NTMSTask?, mutate: (inout ProjectSettings) -> Void
    ) throws -> WorkFolderContext {
        updateSettingsCalls += 1
        if failUpdateSettings { throw Refused(what: "updateSettings") }
        return try inner.updateSettings(at: workFolderRoot, activeTask: activeTask, mutate: mutate)
    }

    func updateTeams(
        at workFolderRoot: URL, activeTask: NTMSTask?, mutate: (inout [Team]) -> Void
    ) throws -> WorkFolderContext {
        updateTeamsCalls += 1
        if failUpdateTeams { throw Refused(what: "updateTeams") }
        return try inner.updateTeams(at: workFolderRoot, activeTask: activeTask, mutate: mutate)
    }

    func resetWorkFolderSettings(at workFolderRoot: URL) throws -> WorkFolderContext {
        if failResetWorkFolderSettings { throw Refused(what: "resetWorkFolderSettings") }
        return try inner.resetWorkFolderSettings(at: workFolderRoot)
    }

    func removeWorkFolderData(at workFolderRoot: URL) throws {
        try inner.removeWorkFolderData(at: workFolderRoot)
    }

    // MARK: TaskRepository

    func createTask(
        at workFolderRoot: URL, title: String, supervisorTask: String,
        preferredTeamID: NTMSID?, parentTaskID: Int?, parentRoleID: String?,
        delegationDepth: Int, makeActive: Bool, origin: TaskOrigin? = nil, requestKey: String? = nil
    ) throws -> (snapshot: WorkFolderContext, taskID: Int) {
        if failCreateTask { throw Refused(what: "createTask") }
        return try inner.createTask(
            at: workFolderRoot, title: title, supervisorTask: supervisorTask,
            preferredTeamID: preferredTeamID, parentTaskID: parentTaskID,
            parentRoleID: parentRoleID, delegationDepth: delegationDepth,
            makeActive: makeActive, origin: origin, requestKey: requestKey)
    }

    func setActiveTask(at workFolderRoot: URL, taskID: Int?) throws -> WorkFolderContext {
        try inner.setActiveTask(at: workFolderRoot, taskID: taskID)
    }

    func setActiveTaskID(at workFolderRoot: URL, taskID: Int?) throws {
        try inner.setActiveTaskID(at: workFolderRoot, taskID: taskID)
    }

    func deleteTask(at workFolderRoot: URL, taskID: Int) throws -> WorkFolderContext {
        try inner.deleteTask(at: workFolderRoot, taskID: taskID)
    }

    func loadTask(at workFolderRoot: URL, taskID: Int) throws -> NTMSTask {
        try inner.loadTask(at: workFolderRoot, taskID: taskID)
    }

    /// Holds ONE task write — the first `updateTaskOnly` the hold matches — on its writer until the
    /// test releases it: how a test begins a later open while an earlier lifecycle is suspended
    /// INSIDE a task write, after every check before that write has answered. Set before the
    /// write can start; read on the writer's (detached) thread.
    var taskWriteHold: TaskWriteHold?

    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws {
        taskWriteHold?.holdIfMatching(folder: workFolderRoot, task: task)
        try inner.updateTaskOnly(at: workFolderRoot, task: task)
    }

    // MARK: ToolRepository

    func updateTools(at workFolderRoot: URL, tools: [ToolDefinitionRecord]) throws -> WorkFolderContext {
        if failUpdateTools { throw Refused(what: "updateTools") }
        return try inner.updateTools(at: workFolderRoot, tools: tools)
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
        try inner.cleanupStagedDraft(at: workFolderRoot, draftID: draftID)
    }

    func cleanupAllStagedDrafts(at workFolderRoot: URL) throws {
        try inner.cleanupAllStagedDrafts(at: workFolderRoot)
    }
}

/// One held task write (`SelectivelyFailingRepository.taskWriteHold`): the first `updateTaskOnly`
/// whose folder and task `matches` blocks its writer until `release()`. The writer is the
/// detached task `mutateTask` hands its disk write to — never the main actor — and it is blocked
/// on a condition, not slept: the repository's writers are synchronous, so a thread is the only
/// thing there is to hold. One write, released by the test (and by its `tearDown`, since a held
/// writer never returns).
final class TaskWriteHold: @unchecked Sendable {
    private let matches: @Sendable (URL, NTMSTask) -> Bool
    private let condition = NSCondition()
    private var used = false
    private var held = false
    private var released = false

    init(matching matches: @escaping @Sendable (_ folder: URL, _ task: NTMSTask) -> Bool) {
        self.matches = matches
    }

    /// A matching write is blocked right now.
    var isHeld: Bool { condition.withLock { held } }

    func holdIfMatching(folder: URL, task: NTMSTask) {
        condition.lock()
        defer { condition.unlock() }
        guard !used, !released, matches(folder, task) else { return }
        used = true
        held = true
        while !released { condition.wait() }
        held = false
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// One held folder read (`SelectivelyFailingRepository.openReadHolds`): every
/// `openOrCreateWorkFolder` of the held path blocks its reader until `release()`, and a released
/// hold lets every read through. Modelled on `TaskWriteHold`: the reader is the detached task
/// `WorkFolderManagementService` hands the read to — never the main actor — and it is blocked on
/// a condition, because the repository's reads are synchronous and a thread is the only thing
/// there is to hold.
///
/// Until 2026-10-28 the repository SLEPT the read (`openDelays`, 0.3–2 s by the test's guess of
/// how long the rest would take), and the suites waited out ~36 s of it. A hold ends exactly where
/// the test releases it, so the read finishes after everything before the release, every time.
///
/// The wait is capped (`cap`): a test that awaits an open it never released does not hang the
/// run — the read goes on at the cap, `timedOut` says so, and the fixture's `tearDown` records
/// the failure.
final class OpenReadHold: @unchecked Sendable {
    /// Far above any honest hold (the longest test holds a read for well under a second).
    static let defaultCap: TimeInterval = 30

    private let cap: TimeInterval
    private let condition = NSCondition()
    private var holding = 0
    private var released = false
    private var expired = false

    init(cap: TimeInterval = OpenReadHold.defaultCap) {
        self.cap = cap
    }

    /// A read of the held path is blocked right now.
    var isHeld: Bool { condition.withLock { holding > 0 } }

    /// A read waited out the cap: the test never released it.
    var timedOut: Bool { condition.withLock { expired } }

    func holdRead() {
        condition.lock()
        defer { condition.unlock() }
        guard !released else { return }
        holding += 1
        let deadline = Date().addingTimeInterval(cap)
        while !released {
            guard condition.wait(until: deadline) else {
                // Released by the cap: every later read passes too, so one forgotten release
                // costs one cap, not one per read.
                expired = true
                released = true
                break
            }
        }
        holding -= 1
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// The read hold the lifecycle suites stage their overlaps with: it holds exactly until the test
/// releases it, lets every read through once released, and lets a read it was never told to
/// release go at its cap — saying so — instead of hanging the run.
final class OpenReadHoldTests: XCTestCase {

    /// A reader on its own thread, the way the repository's detached read runs.
    private func read(_ hold: OpenReadHold, returned: XCTestExpectation) {
        Thread.detachNewThread {
            hold.holdRead()
            returned.fulfill()
        }
    }

    private func waitHeld(_ hold: OpenReadHold) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !hold.isHeld, Date() < deadline { usleep(1000) }
        return hold.isHeld
    }

    func testAHeldReadWaitsForItsReleaseAndThenGoes() {
        let hold = OpenReadHold()
        let returned = expectation(description: "the held read returned")
        read(hold, returned: returned)
        // Held means blocked inside `holdRead`: the reader is waiting on the condition and has
        // not returned — a state, not a window.
        XCTAssertTrue(waitHeld(hold), "the read never reached its hold")
        hold.release()
        wait(for: [returned], timeout: 5)
        XCTAssertFalse(hold.isHeld)
        XCTAssertFalse(hold.timedOut)
    }

    func testAReleasedHoldLetsEveryReadThrough() {
        let hold = OpenReadHold()
        hold.release()
        let returned = expectation(description: "the read returned")
        returned.expectedFulfillmentCount = 2
        read(hold, returned: returned)
        read(hold, returned: returned)
        wait(for: [returned], timeout: 5)
        XCTAssertFalse(hold.timedOut)
    }

    /// RED: wait on the condition with no deadline → this test never returns (the run's own
    /// timeout ends it); drop the `expired` mark → the fixture's `tearDown` has nothing to report.
    func testAReadNobodyReleasesGoesAtTheCapAndSaysSo() {
        let hold = OpenReadHold(cap: 0.05)
        let returned = expectation(description: "the read went at its cap")
        read(hold, returned: returned)
        wait(for: [returned], timeout: 5)
        XCTAssertTrue(hold.timedOut, "a read let go by the cap must say so")
        let again = expectation(description: "a later read passes")
        read(hold, returned: again)
        wait(for: [again], timeout: 5)
    }

    /// Through the repository: a held path's open blocks before the read, every other path's
    /// open does not, and `releaseAllOpenReads` lets it go and hands the hold back.
    func testTheRepositoryHoldsTheHeldPathsReadOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-read-hold-\(UUID().uuidString)", isDirectory: true)
        let held = root.appendingPathComponent("held", isDirectory: true)
        let free = root.appendingPathComponent("free", isDirectory: true)
        for folder in [held, free] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SelectivelyFailingRepository(wrapping: NTMSRepository())
        let hold = OpenReadHold()
        repository.openReadHolds[held.path] = hold

        XCTAssertNoThrow(try repository.openOrCreateWorkFolder(at: free), "an unheld path's read was held")
        let returned = expectation(description: "the held open returned")
        Thread.detachNewThread {
            _ = try? repository.openOrCreateWorkFolder(at: held)
            returned.fulfill()
        }
        XCTAssertTrue(waitHeld(hold), "the held path's read never reached its hold")
        XCTAssertEqual(repository.openStarts.last, held.path, "the open is counted as started while held")
        let released = repository.releaseAllOpenReads()
        wait(for: [returned], timeout: 5)
        XCTAssertTrue(released[held.path] === hold)
        XCTAssertFalse(hold.timedOut)
    }
}
