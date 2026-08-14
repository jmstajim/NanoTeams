import XCTest

@testable import NanoTeams

/// The self-healing migration for the Generated Team placeholder's vacuous chat mode
/// (`migrateIfNeeded` step 2c → `normalizeGeneratedPlaceholderChatMode`).
///
/// `Team.seedChatModeForNewTask` stops NEW tasks inheriting the lie, but folders written
/// by earlier builds still carry `isChatMode: true` in `task.json` AND in the
/// `tasks_index.json` row. Nothing on the generation-failure path ever rewrites
/// `storedIsChatMode`, and the stale-status sweep cannot help: it only visits `.running` /
/// `.needsSupervisorInput` entries, while a failed generation derives `.failed` and a
/// cancelled one `.paused`.
///
/// Each test writes the PRE-FIX bytes by hand (open a real folder, then flip the stored
/// flag on both surfaces) and reopens, which is exactly the shape a user upgrading into
/// this build has on disk.
final class NTMSRepositoryGeneratedChatModeMigrationTests: XCTestCase {

    var repository: NTMSRepository!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        repository = NTMSRepository()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        repository = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - The candidate filter (pure)

    func testMayCarryPlaceholderChatMode_matrix() {
        let placeholder: NTMSID = "generated_placeholder"
        let ids: Set<NTMSID> = [placeholder]

        XCTAssertFalse(
            summary(isChatMode: false, pinnedTeamID: placeholder)
                .mayCarryPlaceholderChatMode(placeholderTeamIDs: ids),
            "false can never be the bug — the old seed only erred toward true")
        XCTAssertTrue(
            summary(isChatMode: true, pinnedTeamID: placeholder)
                .mayCarryPlaceholderChatMode(placeholderTeamIDs: ids))
        XCTAssertTrue(
            summary(isChatMode: true, pinnedTeamID: nil)
                .mayCarryPlaceholderChatMode(placeholderTeamIDs: ids),
            "a never-started task has no pin to test — undecidable, so worth one read")
        XCTAssertFalse(
            summary(isChatMode: true, pinnedTeamID: "coding_assistant")
                .mayCarryPlaceholderChatMode(placeholderTeamIDs: ids),
            "a real team's pin rules the placeholder out with no I/O")
        XCTAssertFalse(
            summary(isChatMode: true, pinnedTeamID: "gen_abc123")
                .mayCarryPlaceholderChatMode(placeholderTeamIDs: ids),
            "an ADOPTED task re-pins to the generated team's own id, so it never matches")
    }

    // MARK: - Wired through migrateIfNeeded → openOrCreateWorkFolder

    func testReopen_taskPinnedToPlaceholder_healsTaskJSONAndIndex() throws {
        let taskID = try seedGeneratedTeamTask(withRun: true)
        try writePreFixChatMode(taskID: taskID)

        let reopened = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertEqual(
            try loadTask(taskID).isChatMode, false, "task.json healed")
        XCTAssertEqual(
            reopened.tasksIndex.tasks.first(where: { $0.id == taskID })?.isChatMode, false,
            "the index row list_tasks reads is healed in the same pass")
    }

    /// The gap `pinnedTeamID` alone cannot see: created and never started, so `runs` is
    /// empty and the summary carries no pin — yet it is still in `list_tasks`.
    func testReopen_neverStartedGeneratedTask_pinnedTeamIDNil_stillHeals() throws {
        let taskID = try seedGeneratedTeamTask(withRun: false)
        try writePreFixChatMode(taskID: taskID)
        XCTAssertNil(
            try loadIndex().tasks.first(where: { $0.id == taskID })?.pinnedTeamID,
            "precondition: no run ⇒ no pin")

        let reopened = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertEqual(try loadTask(taskID).isChatMode, false)
        XCTAssertEqual(
            reopened.tasksIndex.tasks.first(where: { $0.id == taskID })?.isChatMode, false)
    }

    /// The test that stops a future "just re-sync every task against its team" rewrite.
    func testReopen_genuineChatTask_isUntouched() throws {
        let context = try repository.openOrCreateWorkFolder(at: tempDir)
        guard let chatTeam = context.projection.teams.first(where: { $0.isChatMode }) else {
            XCTFail("expected a bundled chat-mode team"); return
        }
        let created = try repository.createTask(
            at: tempDir, title: "Chat", supervisorTask: "hi", preferredTeamID: chatTeam.id)
        XCTAssertTrue(try loadTask(created.taskID).isChatMode, "precondition")

        let reopened = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertTrue(try loadTask(created.taskID).isChatMode)
        XCTAssertEqual(
            reopened.tasksIndex.tasks.first(where: { $0.id == created.taskID })?.isChatMode, true)
    }

    /// `TeamResolution.resolveTeamID`'s first rung short-circuits on `generatedTeam`, so
    /// an adopted task is never a candidate — even one whose generated roster is
    /// genuinely chat-shaped.
    func testReopen_taskWithAdoptedChatShapedTeam_isUntouched() throws {
        let taskID = try seedGeneratedTeamTask(withRun: true)
        let chatRoster = Team(
            id: "gen_chat_abc", name: "Gen Chat",
            roles: [
                TeamRoleDefinition(
                    id: "sup", name: "Supervisor", prompt: "", toolIDs: [],
                    usePlanningPhase: false, dependencies: RoleDependencies(),
                    isSystemRole: true, systemRoleID: "supervisor")
            ],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        XCTAssertTrue(chatRoster.isChatMode, "fixture sanity")
        var task = try loadTask(taskID)
        task.adoptGeneratedTeam(chatRoster)
        try writeTask(task)

        _ = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertTrue(
            try loadTask(taskID).isChatMode,
            "adoption is the authority — the heal must not undo it")
    }

    func testReopen_isIdempotent() throws {
        let taskID = try seedGeneratedTeamTask(withRun: true)
        try writePreFixChatMode(taskID: taskID)

        _ = try repository.openOrCreateWorkFolder(at: tempDir)
        let afterHeal = try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).tasksIndexJSON)

        _ = try repository.openOrCreateWorkFolder(at: tempDir)
        let afterSecond = try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).tasksIndexJSON)

        XCTAssertEqual(afterHeal, afterSecond, "a second open has nothing left to do")
    }

    /// Fail OPEN per task, mirroring `scanRunningTeamRoles`' decode policy: one corrupt
    /// `task.json` must not throw out of the folder open, and must not stop the other
    /// candidate healing.
    func testReopen_undecodableTaskJSON_failsOpenAndTheOtherCandidateStillHeals() throws {
        // The corrupt one is created FIRST so the healthy one ends up active: the
        // active-task read in `openOrCreateWorkFolder` is not fail-open, and a corrupt
        // ACTIVE task.json throws out of the folder open for reasons unrelated to this
        // heal. BOTH tasks exist before either is back-dated — `seedGeneratedTeamTask`
        // opens the folder, and an intermediate open would heal the first one early.
        let badID = try seedGeneratedTeamTask(withRun: true, title: "Broken")
        let goodID = try seedGeneratedTeamTask(withRun: true)
        try writePreFixChatMode(taskID: badID)
        try writePreFixChatMode(taskID: goodID)
        try Data("{ not json".utf8).write(to: taskURL(badID))

        let reopened = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertEqual(try loadTask(goodID).isChatMode, false, "the healthy candidate healed")
        XCTAssertEqual(
            reopened.tasksIndex.tasks.first(where: { $0.id == badID })?.isChatMode, true,
            "the corrupt one is left exactly as it was, so the next open retries it")
    }

    /// The blob write is the authority: if it fails, the index row must be left claiming
    /// `true` so the two surfaces never disagree about which has been healed — and so the
    /// next open retries instead of recording a heal that did not happen.
    func testReopen_unwritableTaskJSON_leavesTheIndexRowUntouched() throws {
        let taskID = try seedGeneratedTeamTask(withRun: true, title: "ReadOnly")
        // A second, healthy task keeps the read-only one out of the ACTIVE slot: the
        // active-task read is a plain load, unrelated to this heal.
        _ = try seedGeneratedTeamTask(withRun: true)
        try writePreFixChatMode(taskID: taskID)
        // The PARENT directory, not the file: `AtomicJSONStore.write` falls back to
        // remove-then-move when `replaceItemAt` fails on a read-only target, and that
        // fallback succeeds as long as the directory is writable.
        let dir = taskURL(taskID).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        // Restore before tearDown, or the recursive temp-dir delete fails.
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }

        let reopened = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertTrue(try loadTask(taskID).isChatMode, "the blob could not be rewritten")
        XCTAssertEqual(
            reopened.tasksIndex.tasks.first(where: { $0.id == taskID })?.isChatMode, true,
            "so the index must not claim it was healed")
    }

    /// A folder that never picked "Generate Team..." has no placeholder, so nothing is a
    /// candidate by pin — and a chat task with no pin is still safely resolved by loading.
    func testReopen_noPlaceholderTeamInFolder_leavesEverythingAlone() throws {
        let context = try repository.openOrCreateWorkFolder(at: tempDir)
        guard let chatTeam = context.projection.teams.first(where: { $0.isChatMode }) else {
            XCTFail("expected a bundled chat-mode team"); return
        }
        let created = try repository.createTask(
            at: tempDir, title: "Chat", supervisorTask: "hi", preferredTeamID: chatTeam.id)

        let reopened = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertEqual(
            reopened.tasksIndex.tasks.first(where: { $0.id == created.taskID })?.isChatMode, true)
    }

    // MARK: - Fixtures

    private func summary(isChatMode: Bool, pinnedTeamID: NTMSID?) -> TaskSummary {
        TaskSummary(
            id: 1, title: "T", status: .running, updatedAt: Date(),
            isChatMode: isChatMode, parentTaskID: nil, nextRecurrenceFireAt: nil,
            pinnedTeamID: pinnedTeamID)
    }

    private func paths() -> NTMSPaths { NTMSPaths(workFolderRoot: tempDir) }

    private func taskURL(_ taskID: Int) -> URL {
        paths().taskJSON(taskID: taskID, ancestors: [])
    }

    private func loadIndex() throws -> TasksIndex {
        try JSONCoderFactory.makeDateDecoder()
            .decode(TasksIndex.self, from: Data(contentsOf: paths().tasksIndexJSON))
    }

    private func loadTask(_ taskID: Int) throws -> NTMSTask {
        try JSONCoderFactory.makeDateDecoder()
            .decode(NTMSTask.self, from: Data(contentsOf: taskURL(taskID)))
    }

    private func writeTask(_ task: NTMSTask) throws {
        try JSONCoderFactory.makePersistenceEncoder().encode(task).write(to: taskURL(task.id))
    }

    /// Installs the Generated Team placeholder and creates a task preferring it,
    /// optionally with the run `startRun` would have created (pinned to the placeholder).
    @discardableResult
    private func seedGeneratedTeamTask(withRun: Bool, title: String = "Gen") throws -> Int {
        var context = try repository.openOrCreateWorkFolder(at: tempDir)
        if !context.projection.teams.contains(where: { $0.isGeneratedPlaceholder }) {
            context = try repository.updateTeams(at: tempDir) { teams in
                teams.append(TeamTemplateFactory.generatedTeam())
            }
        }
        guard let template = context.projection.teams.first(where: { $0.isGeneratedPlaceholder })
        else { throw NSError(domain: "test", code: 1) }

        let created = try repository.createTask(
            at: tempDir, title: title, supervisorTask: "build a calculator",
            preferredTeamID: template.id)
        if withRun {
            var task = try loadTask(created.taskID)
            task.runs = [Run(id: 0, teamID: template.id)]
            try writeTask(task)
            var index = try loadIndex()
            if let i = index.tasks.firstIndex(where: { $0.id == created.taskID }) {
                index.tasks[i] = task.toSummary()
            }
            try JSONCoderFactory.makePersistenceEncoder().encode(index)
                .write(to: paths().tasksIndexJSON)
        }
        return created.taskID
    }

    /// Rewrites both surfaces to the bytes a pre-`seedChatModeForNewTask` build produced.
    private func writePreFixChatMode(taskID: Int) throws {
        var task = try loadTask(taskID)
        task.setStoredChatMode(true)
        try writeTask(task)

        var index = try loadIndex()
        if let i = index.tasks.firstIndex(where: { $0.id == taskID }) {
            index.tasks[i] = task.toSummary()
        }
        try JSONCoderFactory.makePersistenceEncoder().encode(index)
            .write(to: paths().tasksIndexJSON)

        XCTAssertTrue(try loadTask(taskID).isChatMode, "precondition: the lie is on disk")
        XCTAssertEqual(
            try loadIndex().tasks.first(where: { $0.id == taskID })?.isChatMode, true)
    }
}
