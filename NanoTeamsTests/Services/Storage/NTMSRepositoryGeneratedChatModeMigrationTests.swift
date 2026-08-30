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

    // MARK: - The candidate filter (pure, tri-state)

    /// Mirrors `TeamResolution.resolveTeamID`'s rung order — one assertion per rung,
    /// plus the tri-state contract (#91): `.unknown` is a first-class answer, never
    /// read as "clear".
    func testPlaceholderChatCandidacy_matrix() {
        let placeholder: NTMSID = "generated_placeholder"
        let ids: Set<NTMSID> = [placeholder]
        let resolvable: Set<NTMSID> = [placeholder, "coding_assistant"]

        func candidacy(
            isChatMode: Bool = true, pinned: NTMSID? = nil,
            hasGenerated: Bool? = false, preferred: NTMSID? = nil,
            parent: Int? = nil, activeIsPlaceholder: Bool = false
        ) -> PlaceholderChatCandidacy {
            summary(isChatMode: isChatMode, pinnedTeamID: pinned,
                    hasGeneratedTeam: hasGenerated, preferredTeamID: preferred,
                    parentTaskID: parent)
                .placeholderChatCandidacy(
                    placeholderTeamIDs: ids, resolvableTeamIDs: resolvable,
                    activeTeamIsPlaceholder: activeIsPlaceholder)
        }

        XCTAssertEqual(candidacy(isChatMode: false, pinned: placeholder), .decidedClear,
                       "false can never be the bug — the old seed only erred toward true")
        XCTAssertEqual(candidacy(hasGenerated: nil), .unknown,
                       "a legacy row answers nothing — pay the read, never assume (#91)")
        XCTAssertEqual(candidacy(pinned: placeholder, hasGenerated: true), .decidedClear,
                       "rung 1: an adopted generated team is never the placeholder")
        XCTAssertEqual(candidacy(pinned: placeholder), .decidedCandidate,
                       "rung 2: the run pin names the placeholder")
        XCTAssertEqual(candidacy(pinned: "coding_assistant"), .decidedClear,
                       "rung 2: a real team's pin rules the placeholder out with no I/O")
        XCTAssertEqual(candidacy(pinned: "gen_abc123"), .decidedClear,
                       "rung 2: an ADOPTED task re-pins to the generated team's own id")
        XCTAssertEqual(candidacy(preferred: "coding_assistant"), .decidedClear,
                       "rung 3: the never-run-chat-task fix — a resolvable real preferred decides with no I/O")
        XCTAssertEqual(candidacy(preferred: placeholder), .decidedCandidate,
                       "rung 3: a resolvable preferred naming the placeholder is a candidate")
        XCTAssertEqual(candidacy(preferred: "deleted_team", parent: 7), .decidedClear,
                       "rung 4: an unresolvable preferred falls through, and a child resolves to childOrphan = nil")
        XCTAssertEqual(candidacy(preferred: "deleted_team", activeIsPlaceholder: true), .decidedCandidate,
                       "rung 5: root fallback — the effective active team decides")
        XCTAssertEqual(candidacy(preferred: "deleted_team", activeIsPlaceholder: false), .decidedClear,
                       "rung 5: root fallback, active team is real")
        XCTAssertEqual(candidacy(activeIsPlaceholder: true), .decidedCandidate,
                       "rung 5 with no preferred at all")
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

    // MARK: - Index-decisive candidacy (zero reads on later opens)

    /// The cost this rework removes: a never-run chat task on a REAL team used to
    /// be "undecidable" (nil pin) and paid one `task.json` read on EVERY open,
    /// forever — including plain Coding Assistant tasks, the default team.
    ///
    /// RED (pre-rework): the Bool filter selects the row on every open and the
    /// second open probes the blob → the zero-probe assertion fails.
    func testReopen_neverRunChatTaskOnRealTeam_paysZeroReadsOnLaterOpens() throws {
        _ = try repository.openOrCreateWorkFolder(at: tempDir)
        let victim = try repository.createTask(
            at: tempDir, title: "Never run", supervisorTask: "hi", makeActive: false).taskID
        // A separate ACTIVE task, so the victim's blob is not legitimately read
        // by the active-task load in openOrCreateWorkFolder.
        _ = try repository.createTask(at: tempDir, title: "Active", supervisorTask: "x")

        let spy = ProbeCountingFileManager()
        let spied = NTMSRepository(fileManager: spy)
        _ = try spied.openOrCreateWorkFolder(at: tempDir)

        let victimPath = taskURL(victim).path
        XCTAssertEqual(spy.probes[victimPath, default: 0], 0,
                       "a decided-clear row must cost zero blob probes on reopen")
    }

    /// A row written BEFORE the mirrored fields existed pays exactly ONE more
    /// read: the sweep's convergence write stamps the deciding facts into the
    /// row, and the next open decides from the index alone.
    func testReopen_legacyRow_paysOneReadThenConverges() throws {
        _ = try repository.openOrCreateWorkFolder(at: tempDir)
        let victim = try repository.createTask(
            at: tempDir, title: "Legacy", supervisorTask: "hi", makeActive: false).taskID
        _ = try repository.createTask(at: tempDir, title: "Active", supervisorTask: "x")
        try stripMirroredFields(taskID: victim)

        let spy1 = ProbeCountingFileManager()
        _ = try NTMSRepository(fileManager: spy1).openOrCreateWorkFolder(at: tempDir)
        let victimPath = taskURL(victim).path
        XCTAssertGreaterThan(spy1.probes[victimPath, default: 0], 0,
                             "the legacy row must pay its one deciding read")
        let row = try loadIndex().tasks.first(where: { $0.id == victim })
        XCTAssertNotNil(row?.hasGeneratedTeam,
                        "the convergence write must stamp the mirrored facts on disk")

        let spy2 = ProbeCountingFileManager()
        _ = try NTMSRepository(fileManager: spy2).openOrCreateWorkFolder(at: tempDir)
        XCTAssertEqual(spy2.probes[victimPath, default: 0], 0,
                       "after convergence the row decides from the index alone")
    }

    /// The #91 pin: `.unknown` must never be read as "clear". A legacy row hiding
    /// the placeholder lie has NOTHING in the index to decide by — an
    /// implementation that treats a nil `hasGeneratedTeam` as "no generated team,
    /// decide from the remaining rungs" would skip the read and never heal.
    func testReopen_legacyRowHidingThePlaceholderLie_isStillHealed() throws {
        let taskID = try seedGeneratedTeamTask(withRun: false)
        try writePreFixChatMode(taskID: taskID)
        try stripMirroredFields(taskID: taskID)
        // Keep the placeholder OUT of the active slot so rung 5 would say
        // "clear" — the wrong implementation then has no rung left that reads.
        XCTAssertNil(try loadIndex().tasks.first(where: { $0.id == taskID })?.preferredTeamID,
                     "precondition: the stripped row carries no deciding fact")

        _ = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertEqual(try loadTask(taskID).isChatMode, false,
                       "an unknown row must pay the read and heal, never be assumed clear")
    }

    // MARK: - Split-task rows: the sweep must not wipe the supervisor flag (#91)

    /// The sweep reads task.json RAW (no step-log hydration), so a split task's
    /// stream arrays are empty and a recomputed `hasPendingSupervisorInput`
    /// would be a false NEGATIVE. The convergence write must carry the row's
    /// existing answer forward, not overwrite persisted seen-state with `false`.
    ///
    /// RED: drop the `!task.streamsHydrated` preservation in the convergence
    /// branch → the row's `true` becomes `false`.
    func testConvergence_splitTaskRow_preservesPendingSupervisorFlag() throws {
        _ = try repository.openOrCreateWorkFolder(at: tempDir)
        let victim = try repository.createTask(
            at: tempDir, title: "Split", supervisorTask: "hi", makeActive: false).taskID
        _ = try repository.createTask(at: tempDir, title: "Active", supervisorTask: "x")
        try splitifyBlob(taskID: victim)
        try setRowPendingSupervisorInput(taskID: victim, value: true)
        try stripMirroredFields(taskID: victim)  // .unknown → the sweep must pay the read

        _ = try repository.openOrCreateWorkFolder(at: tempDir)

        let row = try XCTUnwrap(loadIndex().tasks.first(where: { $0.id == victim }))
        XCTAssertNotNil(row.hasGeneratedTeam,
                        "anti-vacuum: the convergence write must actually have run")
        XCTAssertEqual(row.hasPendingSupervisorInput, true,
                       "converging a raw-read split task must keep the row's answer (#91)")
    }

    /// The HEAL branch is the second, independent writer of the same row —
    /// pinned separately (#60): a split task that genuinely carries the
    /// placeholder chat-mode lie is healed WITHOUT losing the supervisor flag.
    ///
    /// RED: drop the preservation in the heal branch → `true` becomes `false`
    /// while the convergence pin above stays green.
    func testHeal_splitTaskRow_preservesPendingSupervisorFlag() throws {
        let taskID = try seedGeneratedTeamTask(withRun: true)
        // A separate ACTIVE task: the open's active-task load hydrates and
        // refreshes ITS row, and this fixture's log file deliberately does not
        // exist — fail-open hydration of an ACTIVE victim would legitimately
        // recompute the flag from empty streams after the sweep ran.
        _ = try repository.createTask(at: tempDir, title: "Active", supervisorTask: "x")
        try splitifyBlob(taskID: taskID)
        try writePreFixChatMode(taskID: taskID)
        try setRowPendingSupervisorInput(taskID: taskID, value: true)

        _ = try repository.openOrCreateWorkFolder(at: tempDir)

        XCTAssertEqual(try loadTask(taskID).isChatMode, false,
                       "anti-vacuum: the heal must actually have fired")
        let row = try XCTUnwrap(loadIndex().tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(row.isChatMode, false)
        XCTAssertEqual(row.hasPendingSupervisorInput, true,
                       "healing a raw-read split task must keep the row's answer (#91)")
    }

    // MARK: - Fixtures

    // No restated `@unchecked Sendable`: the SDK marks FileManager's Sendable conformance
    // unavailable, so the restatement never granted anything and both language modes warn
    // "conformance … is already unavailable" — the probe compiles and is used without it.
    private final class ProbeCountingFileManager: FileManager {
        nonisolated(unsafe) var probes: [String: Int] = [:]
        override func fileExists(atPath path: String) -> Bool {
            probes[path, default: 0] += 1
            return super.fileExists(atPath: path)
        }
    }

    /// Rewrites the blob to the SPLIT shape: a step whose `logCommit` says work
    /// happened while the embedded arrays are empty — exactly what a raw
    /// (non-hydrating) read of a post-split task decodes to. The decoder
    /// derives `streamsHydrated == false` from this shape.
    private func splitifyBlob(taskID: Int) throws {
        var task = try loadTask(taskID)
        var step = StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
        // Terminal, so the stale-status sweep (which visits running /
        // needs-input rows and rewrites them from a HYDRATED read) never
        // touches this row — the two sweeps under test stay the only writers.
        step.status = .done
        step.logCommit = StepLogCommit(seq: 3, conversation: 2, wire: 0, toolCalls: 1, messages: 0)
        if task.runs.isEmpty {
            task.runs = [Run(id: 0, steps: [step])]
        } else {
            task.runs[0].steps = [step]
        }
        try writeTask(task)
        XCTAssertFalse(try loadTask(taskID).streamsHydrated,
                       "precondition: the blob decodes as a raw split task")
    }

    /// Stamps the seen-state flag onto the index row byte-directly — the
    /// persisted `true` the sweep must not recompute away.
    private func setRowPendingSupervisorInput(taskID: Int, value: Bool) throws {
        let data = try Data(contentsOf: paths().tasksIndexJSON)
        var root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(root["tasks"] as? [[String: Any]])
        for i in rows.indices where (rows[i]["id"] as? Int) == taskID {
            rows[i]["hasPendingSupervisorInput"] = value
        }
        root["tasks"] = rows
        try JSONSerialization.data(withJSONObject: root)
            .write(to: paths().tasksIndexJSON)
        XCTAssertEqual(
            try loadIndex().tasks.first(where: { $0.id == taskID })?.hasPendingSupervisorInput,
            value, "precondition: the flag is on disk")
    }

    /// Rewrites one index row to the byte-shape a pre-2026-08-21 build produced:
    /// no `hasGeneratedTeam`, no `preferredTeamID`.
    private func stripMirroredFields(taskID: Int) throws {
        let data = try Data(contentsOf: paths().tasksIndexJSON)
        var root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(root["tasks"] as? [[String: Any]])
        for i in rows.indices where (rows[i]["id"] as? Int) == taskID {
            rows[i].removeValue(forKey: "hasGeneratedTeam")
            rows[i].removeValue(forKey: "preferredTeamID")
        }
        root["tasks"] = rows
        try JSONSerialization.data(withJSONObject: root)
            .write(to: paths().tasksIndexJSON)
        let reread = try loadIndex().tasks.first(where: { $0.id == taskID })
        XCTAssertNil(reread?.hasGeneratedTeam, "precondition: the row is legacy-shaped")
    }

    private func summary(
        isChatMode: Bool, pinnedTeamID: NTMSID?,
        hasGeneratedTeam: Bool? = false, preferredTeamID: NTMSID? = nil,
        parentTaskID: Int? = nil
    ) -> TaskSummary {
        TaskSummary(
            id: 1, title: "T", status: .running, updatedAt: Date(),
            isChatMode: isChatMode, parentTaskID: parentTaskID, nextRecurrenceFireAt: nil,
            pinnedTeamID: pinnedTeamID, hasGeneratedTeam: hasGeneratedTeam,
            preferredTeamID: preferredTeamID)
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
            context = try repository.updateTeams(at: tempDir, activeTask: nil) { teams in
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
