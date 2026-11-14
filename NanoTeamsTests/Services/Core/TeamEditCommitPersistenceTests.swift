import SwiftUI
import XCTest
@testable import NanoTeams

/// The Team Editor's write path against a real orchestrator and the disk: `NTMSOrchestrator.teamEdits`
/// wired to `commitEditedTeam`.
///
/// Field report (2026-11-08): a tool ticked for Startup → Software Engineer in the Role Editor,
/// Save pressed, the sheet closed — and `teams.json` never changed; only a second attempt
/// persisted. The Save dismissed on the Binding assignment, whose setter only started a
/// `Task { await mutateWorkFolder … }`; nothing waited for it and nothing heard a refusal. These
/// tests pin the replacement end to end: a Save returns only once the value is in `teams.json`, a
/// refused write comes back with its reason, and a value is never written into a folder other
/// than the one it was edited in.
@MainActor
final class TeamEditCommitPersistenceTests: XCTestCase, @unchecked Sendable {

    private var tempDir: URL!
    private var otherDir: URL!
    private var repo: SelectivelyFailingRepository!
    /// The model server the residency reconcile lists and unloads on.
    private var client: RecordingLLMClient!
    /// The ownership ledger that reconcile reclaims from.
    private var ensurer: ChatModelEnsurer!
    private var sut: NTMSOrchestrator!

    private static let baseURL = "http://127.0.0.1:1234"

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = Self.makeDir("team-edit-commit")
        otherDir = Self.makeDir("team-edit-commit-other")
        repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        client = RecordingLLMClient()
        ensurer = ChatModelEnsurer()
        sut = TestOrchestrator.make(repository: repo, chatLifecycleClient: client, chatModelEnsurer: ensurer)
    }

    override func tearDown() async throws {
        await sut?.teamEdits.settleAll()
        sut?.stopAllEngines()
        sut = nil
        ensurer = nil
        client = nil
        repo = nil
        for dir in [tempDir, otherDir].compactMap({ $0 }) { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
        otherDir = nil
        try await super.tearDown()
    }

    // MARK: - The field report

    /// Tick a tool the Startup engineer lacks, Save the way the sheet does — compose on the team
    /// the editor reads, commit through the Team Editor's binding — and the tool is in
    /// `teams.json` by the time the Save returns.
    ///
    /// RED (pre-fix): there is no awaited commit; the Binding setter returned at once and the
    /// sheet dismissed with nothing written yet.
    func testATickedToolIsInTeamsJSON_whenTheSaveReturns() async throws {
        await sut.openWorkFolder(tempDir)
        let team = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        let engineer = try XCTUnwrap(team.roles.first { !$0.isSupervisor })
        let tool = try XCTUnwrap(
            ToolNames.allNames.first {
                !engineer.toolIDs.contains($0)
                    && !ToolHandlerRegistry.delegationToolsExcludedFromToolIDs.contains($0)
            },
            "precondition: some tool the engineer does not hold")

        var editorState = RoleEditorState.loaded(from: engineer)
        editorState.selectedTools.insert(tool)
        let lifecycle = sut.currentFolderLifecycle
        let binding = sut.teamEdits.binding(for: team, editedIn: lifecycle)
        var edited = binding.wrappedValue
        XCTAssertTrue(RoleEditorMutations.applyEdit(to: &edited, editorState: editorState, existingRoleID: engineer.id))

        let outcome = await sut.teamEdits.commit(edited, as: TeamEditCommitQueue.Session(team: team, lifecycle: lifecycle))

        XCTAssertEqual(outcome, .persisted)
        let onDisk = try diskTeams(in: tempDir).first { $0.id == team.id }?.roles.first { $0.id == engineer.id }
        XCTAssertTrue(onDisk?.toolIDs.contains(tool) == true, "the ticked tool is not in teams.json")
        XCTAssertTrue(
            sut.workFolder?.teams.first { $0.id == team.id }?.roles.first { $0.id == engineer.id }?
                .toolIDs.contains(tool) == true,
            "the snapshot must hold what was written")
        XCTAssertNil(sut.teamEdits.draft(for: team.id, editedIn: sut.currentFolderLifecycle))
    }

    /// Per-keystroke edits from a live view (the Prompts tab writes the whole template on every
    /// keystroke) land in order, and `teams.json` ends on the LAST one.
    func testRapidLiveEdits_endOnTheLatestValueOnDisk() async throws {
        await sut.openWorkFolder(tempDir)
        let team = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        let binding = sut.teamEdits.binding(for: team, editedIn: sut.currentFolderLifecycle)

        for text in ["S", "Sy", "Sys", "Syst", "System prompt v2"] {
            binding.wrappedValue.assignPromptTemplate(.system, value: text)
        }
        binding.wrappedValue.settings.supervisorMode = .autonomous
        let outcome = await sut.teamEdits.settle(teamID: team.id)

        XCTAssertNil(outcome.failureReason)
        let stored = try XCTUnwrap(try diskTeams(in: tempDir).first { $0.id == team.id })
        XCTAssertEqual(stored.systemPromptTemplate, "System prompt v2")
        XCTAssertEqual(stored.settings.supervisorMode, .autonomous,
                       "a write staged after the prompt edits dropped them, or they dropped it")
    }

    // MARK: - Refusals carry a reason

    /// `teams.json` refuses the write: the Save hears why, the reason is surfaced for the person,
    /// and memory is re-synced to what is on disk — the editor stops showing the unsaved value.
    func testARefusedTeamsWrite_comesBackWithItsReason_andMemoryMatchesTheDisk() async throws {
        await sut.openWorkFolder(tempDir)
        let team = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        repo.failUpdateTeams = true
        let errorsBefore = sut.errorSurfaceCount
        let lifecycle = sut.currentFolderLifecycle
        let binding = sut.teamEdits.binding(for: team, editedIn: lifecycle)
        var edited = binding.wrappedValue
        edited.description = "never stored"

        let outcome = await sut.teamEdits.commit(edited, as: TeamEditCommitQueue.Session(team: team, lifecycle: lifecycle))

        let reason = try XCTUnwrap(outcome.failureReason)
        XCTAssertTrue(reason.contains("teams.json"), reason)
        XCTAssertEqual(sut.errorSurfaced(since: errorsBefore), reason)
        XCTAssertNotEqual(sut.workFolder?.teams.first { $0.id == team.id }?.description, "never stored")
        XCTAssertNotEqual(try diskTeams(in: tempDir).first { $0.id == team.id }?.description, "never stored")
        XCTAssertEqual(binding.wrappedValue.description, team.description,
                       "a refused value must not be read back: the editor shows what is stored")
        XCTAssertEqual(sut.teamEdits.failure(for: team.id, editedIn: sut.currentFolderLifecycle), reason)
    }

    /// An edit of Startup was refused, so the Team Editor's banner says so. A later write of
    /// ANOTHER team leaves that row; Restore Default Teams, which replaces Startup, lands — the
    /// team on disk is now what the editor shows, and the row goes.
    ///
    /// RED: drop `teamsWereWritten` from `mutateWorkFolder` → the row survives the restore until
    /// some later edit of Startup happens to succeed.
    func testAWriteFromBesideTheQueue_thatReplacedTheTeam_clearsItsFailedWrite() async throws {
        let (startup, lifecycle) = try await openFolderWithAFailedEditOfStartup()
        let other = try XCTUnwrap(sut.workFolder?.teams.first { $0.id != startup.id })

        await sut.mutateWorkFolder { projection in
            guard let index = projection.teams.firstIndex(where: { $0.id == other.id }) else { return }
            projection.teams[index].description = "another team, written"
        }
        XCTAssertNotNil(sut.teamEdits.failure(for: startup.id, editedIn: lifecycle),
                       "a write that left Startup alone says nothing about Startup's edit")

        let restored = await TeamEditorView.restoreDefaultTeams(in: sut, editedIn: lifecycle)

        XCTAssertNil(restored.failureReason)
        XCTAssertNil(sut.teamEdits.failure(for: startup.id, editedIn: lifecycle),
                     "Startup was replaced and written: its failed edit is no longer its newest write")
    }

    /// Two teams of one id reach `teams.json`: nothing on the write path refuses a duplicate a
    /// closure appends — `addTeam` renames only at its own door. The editor shows the FIRST
    /// (`storedTeam` is a `first(where:)`), so the row follows the first copy: the write that
    /// added the second leaves it, a later write that replaced the first clears it.
    func testAWriteThatAddedASecondTeamOfTheSameID_leavesTheRow_untilTheFirstCopyIsReplaced() async throws {
        let (startup, lifecycle) = try await openFolderWithAFailedEditOfStartup()
        var secondCopy = startup
        secondCopy.description = "a second team of the same id"

        let added = await sut.mutateWorkFolder { $0.teams.append(secondCopy) }

        XCTAssertEqual(added, .persisted)
        XCTAssertEqual(try diskTeams(in: tempDir).filter { $0.id == startup.id }.count, 2,
                       "precondition: teams.json holds the id twice")
        XCTAssertNotNil(sut.teamEdits.failure(for: startup.id, editedIn: lifecycle),
                        "the copy the editor shows was left as it was: the row stays")

        let replaced = await sut.mutateWorkFolder { projection in
            guard let first = projection.teams.firstIndex(where: { $0.id == startup.id }) else { return }
            projection.teams[first].description = "the first copy, rewritten"
        }

        XCTAssertEqual(replaced, .persisted)
        XCTAssertNil(sut.teamEdits.failure(for: startup.id, editedIn: lifecycle),
                     "the copy the editor shows was replaced: its failed edit is no longer its newest write")
    }

    /// A write that left `teams.json` alone — a settings edit — says nothing about any team's
    /// edit: the row stays.
    func testAWriteThatLeftTeamsJSONAlone_leavesTheRow() async throws {
        let (startup, lifecycle) = try await openFolderWithAFailedEditOfStartup()
        repo.resetCounters()

        let outcome = await sut.mutateWorkFolder { $0.settings.context = "a settings edit" }

        XCTAssertEqual(outcome, .persisted)
        XCTAssertEqual(repo.updateTeamsCalls, 0, "precondition: teams.json was not written")
        XCTAssertNotNil(sut.teamEdits.failure(for: startup.id, editedIn: lifecycle))
    }

    /// A team deleted while its edit waited: replacing nothing is not a save.
    func testAnEditOfATeamThatIsGone_isRefusedWithAReason() async throws {
        await sut.openWorkFolder(tempDir)
        let team = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        let lifecycle = sut.currentFolderLifecycle
        await sut.mutateWorkFolder { $0.removeTeam(team.id) }
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).teamsJSON)

        let outcome = sut.commitEditedTeam(team, editedIn: lifecycle)

        let reason = try XCTUnwrap(outcome.failureReason)
        XCTAssertTrue(reason.contains(team.name), reason)
        XCTAssertFalse(sut.workFolder?.teams.contains { $0.id == team.id } == true, "the deleted team came back")
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).teamsJSON), teamsBefore)
    }

    /// A value edited in folder A, written after folder B opened, must not land in B — template
    /// teams share ids across folders, so it would replace B's team of the same id.
    ///
    /// RED: drop the lifecycle guard in `commitEditedTeam` → folder B's Startup team takes folder
    /// A's description.
    func testAValueEditedInAFolderThatIsNoLongerOpen_isRefused_andTheOpenFolderIsUntouched() async throws {
        await sut.openWorkFolder(tempDir)
        var fromA = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        let folderA = sut.currentFolderLifecycle
        fromA.description = "edited in folder A"

        await sut.openWorkFolder(otherDir)
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON)
        XCTAssertTrue(sut.workFolder?.teams.contains { $0.id == fromA.id } == true,
                      "precondition: folder B has a team with the same id")

        let outcome = sut.commitEditedTeam(fromA, editedIn: folderA)

        XCTAssertNotNil(outcome.failureReason)
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON), teamsBefore)
        XCTAssertNotEqual(sut.workFolder?.teams.first { $0.id == fromA.id }?.description, "edited in folder A")
    }

    /// With no folder open there is nowhere to save — said, not swallowed.
    func testWithNoFolderOpen_anEditIsRefusedWithAReason() async throws {
        let team = TeamTemplateFactory.empty(name: "Nowhere")

        let outcome = sut.commitEditedTeam(team, editedIn: sut.currentFolderLifecycle)

        XCTAssertNotNil(outcome.failureReason)
        XCTAssertNil(sut.workFolder)
    }

    /// A commit identical to what is stored writes nothing and is still a successful save.
    func testCommittingTheStoredValue_isASaveThatWritesNothing() async throws {
        await sut.openWorkFolder(tempDir)
        let team = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        repo.resetCounters()

        let outcome = sut.commitEditedTeam(team, editedIn: sut.currentFolderLifecycle)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(repo.updateTeamsCalls, 0)
    }

    // MARK: - A sheet's Save stays in the folder and the team it opened on

    /// The Role Editor opened in folder A; folder B — whose active team has the same id, as every
    /// fresh folder's Coding Assistant does — opened while it stayed open; Save. The binding the
    /// sheet holds by then is the one the Team Editor rebuilt for B, so nothing in it says the
    /// draft was read in A: only the session the click captured does.
    ///
    /// RED: commit the Save through the binding the sheet holds, as the pre-fix
    /// `commit(_:through:)` did → the draft lands in folder B (its teams.json 174 304 → 174 343
    /// bytes in the 2026-11-08 red run).
    func testARoleSave_afterAnotherFolderOpened_writesNothingIntoIt() async throws {
        await sut.openWorkFolder(tempDir)
        let teamInA = try XCTUnwrap(sut.workFolder?.activeTeam)
        let opened = TeamEditCommitQueue.Session(team: teamInA, lifecycle: sut.currentFolderLifecycle)
        let role = try XCTUnwrap(teamInA.roles.first { !$0.isSupervisor })
        var draft = RoleEditorState.loaded(from: role)
        draft.selectedTools.insert(try Self.tool(notHeldBy: role))

        await sut.openWorkFolder(otherDir)
        let teamInB = try XCTUnwrap(sut.workFolder?.activeTeam)
        XCTAssertEqual(teamInB.id, teamInA.id, "precondition: folder B's active team has folder A's team id")
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON)
        let binding = sut.teamEdits.binding(for: teamInB, editedIn: sut.currentFolderLifecycle)

        let failure = await RoleEditorSheet.save(
            draft, mode: .edit(role), session: opened, onto: binding.wrappedValue, through: sut.teamEdits)

        XCTAssertEqual(failure, TeamEditCommitQueue.folderChangedReason(teamName: teamInA.name),
                       "a role edited in folder A was saved into folder B")
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON), teamsBefore)
    }

    /// The same in create mode: the new role must not be added to folder B's team.
    func testANewRoleSave_afterAnotherFolderOpened_writesNothingIntoIt() async throws {
        await sut.openWorkFolder(tempDir)
        let teamInA = try XCTUnwrap(sut.workFolder?.activeTeam)
        let opened = TeamEditCommitQueue.Session(team: teamInA, lifecycle: sut.currentFolderLifecycle)
        var draft = RoleEditorState()
        draft.roleName = "Reviewer from A"
        draft.rolePrompt = "Review the change."

        await sut.openWorkFolder(otherDir)
        let teamInB = try XCTUnwrap(sut.workFolder?.activeTeam)
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON)
        let binding = sut.teamEdits.binding(for: teamInB, editedIn: sut.currentFolderLifecycle)

        let failure = await RoleEditorSheet.save(
            draft, mode: .create, session: opened, onto: binding.wrappedValue, through: sut.teamEdits)

        XCTAssertEqual(failure, TeamEditCommitQueue.folderChangedReason(teamName: teamInA.name),
                       "a role created in folder A was added in folder B")
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON), teamsBefore)
    }

    /// The Artifact Editor the same: an artifact created in folder A is not added in folder B.
    func testANewArtifactSave_afterAnotherFolderOpened_writesNothingIntoIt() async throws {
        await sut.openWorkFolder(tempDir)
        let teamInA = try XCTUnwrap(sut.workFolder?.activeTeam)
        let opened = TeamEditCommitQueue.Session(team: teamInA, lifecycle: sut.currentFolderLifecycle)
        var draft = ArtifactEditorMutations.Draft.new
        draft.name = "Threat Model from A"

        await sut.openWorkFolder(otherDir)
        let teamInB = try XCTUnwrap(sut.workFolder?.activeTeam)
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON)
        let binding = sut.teamEdits.binding(for: teamInB, editedIn: sut.currentFolderLifecycle)

        let outcome = await ArtifactEditorSheet.save(
            draft, mode: .create, session: opened, onto: binding.wrappedValue, through: sut.teamEdits)

        XCTAssertEqual(outcome, .refused(TeamEditCommitQueue.folderChangedReason(teamName: teamInA.name)))
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: otherDir).teamsJSON), teamsBefore)
    }

    /// A refused `teams.json` write: the artifact is not stored, and the Save answers the reason —
    /// so the Role Editor's Dependencies tab, which puts a created artifact into the role's draft
    /// only on `.saved`, never names it.
    func testANewArtifactSave_whoseWriteIsRefused_storesNothing_andSaysWhy() async throws {
        await sut.openWorkFolder(tempDir)
        let team = try XCTUnwrap(sut.workFolder?.activeTeam)
        let session = TeamEditCommitQueue.Session(team: team, lifecycle: sut.currentFolderLifecycle)
        var draft = ArtifactEditorMutations.Draft.new
        draft.name = "Threat Model"
        repo.failUpdateTeams = true

        let outcome = await ArtifactEditorSheet.save(
            draft, mode: .create, session: session,
            onto: sut.teamEdits.binding(for: team, editedIn: session.lifecycle).wrappedValue, through: sut.teamEdits)

        guard case .refused(let reason) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertTrue(reason.contains("teams.json"), reason)
        XCTAssertFalse(try diskTeams(in: tempDir).first { $0.id == team.id }?.artifacts.contains { $0.name == "Threat Model" } ?? true)
        XCTAssertFalse(sut.workFolder?.teams.first { $0.id == team.id }?.artifacts.contains { $0.name == "Threat Model" } ?? true)
    }

    /// The Team Editor moved to another team while the sheet was open — the main window switched
    /// the active team. A new role composed for the first team must not be added to the second.
    func testANewRoleSave_afterTheEditedTeamChanged_writesNothing() async throws {
        await sut.openWorkFolder(tempDir)
        let first = try XCTUnwrap(sut.workFolder?.activeTeam)
        let opened = TeamEditCommitQueue.Session(team: first, lifecycle: sut.currentFolderLifecycle)
        var draft = RoleEditorState()
        draft.roleName = "Reviewer"
        draft.rolePrompt = "Review the change."
        let other = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        await sut.mutateWorkFolder { $0.setActiveTeam(other.id) }
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).teamsJSON)
        let binding = sut.teamEdits.binding(for: other, editedIn: sut.currentFolderLifecycle)

        let failure = await RoleEditorSheet.save(
            draft, mode: .create, session: opened, onto: binding.wrappedValue, through: sut.teamEdits)

        XCTAssertEqual(failure, TeamEditCommitQueue.otherTeamReason(opened: opened),
                       "a role meant for one team was added to the team the editor switched to")
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).teamsJSON), teamsBefore)
    }

    /// In edit mode the switched-to team has no such role, so nothing was written even before —
    /// but the sheet said the role "no longer exists", which is not what happened. (Opened on
    /// Startup, whose role is not named after its team, so the team's name in the reason means
    /// the team.)
    func testARoleSave_afterTheEditedTeamChanged_saysTheTeamChanged() async throws {
        await sut.openWorkFolder(tempDir)
        let startup = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        let other = try XCTUnwrap(sut.workFolder?.activeTeam)
        XCTAssertNotEqual(other.id, startup.id, "precondition: the editor starts on another team")
        await sut.mutateWorkFolder { $0.setActiveTeam(startup.id) }
        let role = try XCTUnwrap(startup.roles.first { !$0.isSupervisor })
        XCTAssertFalse(role.name.contains(startup.name), "precondition: the role is not named after its team")
        let opened = TeamEditCommitQueue.Session(team: startup, lifecycle: sut.currentFolderLifecycle)
        var draft = RoleEditorState.loaded(from: role)
        draft.rolePrompt = "Edited."
        await sut.mutateWorkFolder { $0.setActiveTeam(other.id) }
        let teamsBefore = try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).teamsJSON)
        let binding = sut.teamEdits.binding(for: other, editedIn: sut.currentFolderLifecycle)

        let failure = await RoleEditorSheet.save(
            draft, mode: .edit(role), session: opened, onto: binding.wrappedValue, through: sut.teamEdits)

        let reason = try XCTUnwrap(failure)
        XCTAssertTrue(reason.contains(startup.name), "the refusal must name the team the sheet was opened on: \(reason)")
        XCTAssertEqual(reason, TeamEditCommitQueue.otherTeamReason(opened: opened))
        XCTAssertEqual(try Data(contentsOf: NTMSPaths(workFolderRoot: tempDir).teamsJSON), teamsBefore)
    }

    // MARK: - What a write leaves owed

    /// A role pinned to its own model; the Role Editor clears the override and saves. Nothing
    /// references that model any more, so the write leaves the residency reconcile owed — and the
    /// reconcile unloads it. It runs beside the writes (a Save waits for `teams.json`, not for a
    /// model server), and `settleAll` waits for it.
    ///
    /// RED: drop the reconcile the queue owes after a write → the pinned model stays resident and
    /// no unload is recorded.
    func testClearingARolesModelOverride_inTheRoleEditor_unloadsTheModelItPinned() async throws {
        await sut.openWorkFolder(tempDir)
        sut.configuration.llmBaseURLString = Self.baseURL
        sut.configuration.llmModelName = "chat-model"
        let team = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        let engineer = try XCTUnwrap(team.roles.first { !$0.isSupervisor })
        let lifecycle = sut.currentFolderLifecycle
        let session = TeamEditCommitQueue.Session(team: team, lifecycle: lifecycle)
        var pinned = RoleEditorState.loaded(from: engineer)
        pinned.llmModelName = "role-pinned-model"
        let pinFailure = await RoleEditorSheet.save(
            pinned, mode: .edit(engineer), session: session,
            onto: sut.teamEdits.binding(for: team, editedIn: lifecycle).wrappedValue, through: sut.teamEdits)
        XCTAssertNil(pinFailure)
        await sut.teamEdits.settleAll()
        // Resident and owned, as a step on that role would have left it.
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "role-pinned-model", instanceID: "role-pinned-model"),
        ]
        _ = try await ensurer.ensureLoaded(modelName: "role-pinned-model", baseURLString: Self.baseURL, client: client)
        client.calls.removeAll()

        let stored = try XCTUnwrap(sut.workFolder?.teams.first { $0.id == team.id })
        let pinnedRole = try XCTUnwrap(stored.roles.first { $0.id == engineer.id })
        XCTAssertEqual(pinnedRole.llmOverride?.modelName, "role-pinned-model", "precondition: the override is stored")
        var cleared = RoleEditorState.loaded(from: pinnedRole)
        cleared.llmModelName = ""
        let failure = await RoleEditorSheet.save(
            cleared, mode: .edit(pinnedRole), session: session,
            onto: sut.teamEdits.binding(for: stored, editedIn: lifecycle).wrappedValue, through: sut.teamEdits)
        XCTAssertNil(failure)
        await sut.teamEdits.settleAll()

        let unloaded = client.calls.compactMap { call -> String? in
            if case .unload(let id, _) = call { return id } else { return nil }
        }
        XCTAssertEqual(unloaded, ["role-pinned-model"], "the model the cleared override pinned is still resident")
    }

    // MARK: - What the editor's binding reads

    /// A write from beside the queue — here a plain `mutateWorkFolder`, as an Autovisor sync or a
    /// Team Editor action makes — lands after the editor rendered the team. The next edit through
    /// the binding the editor rendered must start from that write, not revert it.
    ///
    /// RED: let the binding's getter fall back to the rendered copy → the description written
    /// beside the queue is reverted by the next edit.
    func testAnEditThroughTheBinding_keepsAWriteThatLandedAfterTheRender() async throws {
        await sut.openWorkFolder(tempDir)
        let rendered = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        let binding = sut.teamEdits.binding(for: rendered, editedIn: sut.currentFolderLifecycle)
        await sut.mutateWorkFolder { projection in
            guard let index = projection.teams.firstIndex(where: { $0.id == rendered.id }) else { return }
            projection.teams[index].description = "written beside the queue"
        }

        XCTAssertEqual(binding.wrappedValue.description, "written beside the queue")
        binding.wrappedValue.settings.supervisorMode = .autonomous
        _ = await sut.teamEdits.settle(teamID: rendered.id)

        let stored = try XCTUnwrap(try diskTeams(in: tempDir).first { $0.id == rendered.id })
        XCTAssertEqual(stored.description, "written beside the queue", "the edit reverted a write it did not make")
        XCTAssertEqual(stored.settings.supervisorMode, .autonomous)
    }

    /// A binding rendered in folder A, read after folder B opened: B's team of the same id is not
    /// what it edited, so it answers the copy it was rendered with.
    ///
    /// RED: drop the lifecycle guard in `NTMSOrchestrator.storedTeam` → it reads folder B's team.
    func testABindingOfAFolderThatIsNoLongerOpen_neverReadsTheNextFoldersTeam() async throws {
        await sut.openWorkFolder(tempDir)
        var renderedInA = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        renderedInA.description = "rendered in folder A"
        let binding = sut.teamEdits.binding(for: renderedInA, editedIn: sut.currentFolderLifecycle)

        await sut.openWorkFolder(otherDir)
        XCTAssertNotEqual(sut.workFolder?.teams.first { $0.id == renderedInA.id }?.description, "rendered in folder A",
                          "precondition: folder B's team of that id is a different value")

        XCTAssertEqual(binding.wrappedValue.description, "rendered in folder A")
    }

    // MARK: - Helpers

    /// Opens `tempDir` and leaves Startup with a failed edit — the row the Team Editor's banner
    /// shows — then lets `teams.json` writes through again. Answers the team and the folder
    /// lifecycle the edit was made in.
    private func openFolderWithAFailedEditOfStartup() async throws -> (startup: Team, lifecycle: WorkFolderLifecycle) {
        await sut.openWorkFolder(tempDir)
        let lifecycle = sut.currentFolderLifecycle
        let startup = try XCTUnwrap(sut.workFolder?.teams.first { $0.templateID == "startup" })
        repo.failUpdateTeams = true
        var edited = startup
        edited.description = "never stored"
        _ = await sut.teamEdits.commit(edited, as: TeamEditCommitQueue.Session(team: startup, lifecycle: lifecycle))
        XCTAssertNotNil(sut.teamEdits.failure(for: startup.id, editedIn: lifecycle), "precondition: the edit failed")
        repo.failUpdateTeams = false
        return (startup, lifecycle)
    }

    private static func tool(notHeldBy role: TeamRoleDefinition) throws -> String {
        try XCTUnwrap(
            ToolNames.allNames.first {
                !role.toolIDs.contains($0) && !ToolHandlerRegistry.delegationToolsExcludedFromToolIDs.contains($0)
            },
            "precondition: some tool the role does not hold")
    }

    private static func makeDir(_ prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func diskTeams(in root: URL) throws -> [Team] {
        let data = try Data(contentsOf: NTMSPaths(workFolderRoot: root).teamsJSON)
        return try JSONCoderFactory.makeDateDecoder().decode(TeamsFile.self, from: data).teams
    }
}
