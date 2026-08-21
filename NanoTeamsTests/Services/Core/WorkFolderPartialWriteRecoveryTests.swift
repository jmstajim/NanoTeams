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
        repo.failUpdateWorkFolderContext = true

        await sut.updateWorkFolderContext("nope")

        XCTAssertNotNil(sut.lastErrorMessage)
    }

    func testUpdateSelectedScheme_diskRefusal_surfacesTheError() async {
        await sut.openWorkFolder(tempDir)
        repo.failUpdateSelectedScheme = true

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

    func testMutateWorkFolder_withNoFolderOpen_isASilentNoOp() async {
        await sut.mutateWorkFolder { $0.settings.context = "x" }

        XCTAssertNil(sut.lastErrorMessage)
        XCTAssertNil(sut.workFolder)
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
    var failUpdateWorkFolderContext = false
    var failUpdateSelectedScheme = false
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

    // MARK: WorkFolderRepository

    func openOrCreateWorkFolder(at workFolderRoot: URL) throws -> WorkFolderContext {
        if failOpenOrCreate { throw Refused(what: "openOrCreateWorkFolder") }
        return try inner.openOrCreateWorkFolder(at: workFolderRoot)
    }

    func updateWorkFolderContext(at workFolderRoot: URL, context: String) throws -> WorkFolderContext {
        if failUpdateWorkFolderContext { throw Refused(what: "updateWorkFolderContext") }
        return try inner.updateWorkFolderContext(at: workFolderRoot, context: context)
    }

    func updateSelectedScheme(at workFolderRoot: URL, scheme: String?) throws -> WorkFolderContext {
        if failUpdateSelectedScheme { throw Refused(what: "updateSelectedScheme") }
        return try inner.updateSelectedScheme(at: workFolderRoot, scheme: scheme)
    }

    func updateWorkFolderState(
        at workFolderRoot: URL, mutate: (inout WorkFolderState) -> Void
    ) throws -> WorkFolderContext {
        updateStateCalls += 1
        if failUpdateWorkFolderState { throw Refused(what: "updateWorkFolderState") }
        return try inner.updateWorkFolderState(at: workFolderRoot, mutate: mutate)
    }

    func updateSettings(
        at workFolderRoot: URL, mutate: (inout ProjectSettings) -> Void
    ) throws -> WorkFolderContext {
        updateSettingsCalls += 1
        if failUpdateSettings { throw Refused(what: "updateSettings") }
        return try inner.updateSettings(at: workFolderRoot, mutate: mutate)
    }

    func updateTeams(
        at workFolderRoot: URL, mutate: (inout [Team]) -> Void
    ) throws -> WorkFolderContext {
        updateTeamsCalls += 1
        if failUpdateTeams { throw Refused(what: "updateTeams") }
        return try inner.updateTeams(at: workFolderRoot, mutate: mutate)
    }

    func resetWorkFolderSettings(at workFolderRoot: URL) throws -> WorkFolderContext {
        if failResetWorkFolderSettings { throw Refused(what: "resetWorkFolderSettings") }
        return try inner.resetWorkFolderSettings(at: workFolderRoot)
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

    func updateTaskOnly(at workFolderRoot: URL, task: NTMSTask) throws {
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
