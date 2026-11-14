import Observation
import SwiftUI
import XCTest
@testable import NanoTeams

/// Whether an observation fired — written from `withObservationTracking`'s `@Sendable` `onChange`,
/// read by the test once it has joined. Every write happens on the main actor here.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

/// Pins `TeamEditCommitQueue` — the Team Editor's write path — against a writer the test holds.
///
/// The defect it replaces: `TeamEditorView.binding(for:)` answered a write with
/// `Task { await mutateWorkFolder { … } }` and returned the team as last rendered. A sheet's Save
/// therefore dismissed on the assignment, before anything was written, and nothing waited to hear
/// that `teams.json` refused it; two writes in one handler both started from the rendered copy, so
/// the second dropped the first; and nothing ordered the writes on their way to disk. Each test
/// below names the guarantee that replaces one of those.
@MainActor
final class TeamEditCommitQueueTests: XCTestCase, @unchecked Sendable {

    private var writer: HeldTeamWriter!
    private var sut: TeamEditCommitQueue!
    /// What a `Task` that awaited a settle or a commit saw — `nil` while it still waits.
    private var awaitedOutcome: WorkFolderMutationOutcome?

    private static let folder = WorkFolderLifecycle(generation: 1)
    private static let nextFolder = WorkFolderLifecycle(generation: 2)

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        let writer = HeldTeamWriter()
        self.writer = writer
        sut = TeamEditCommitQueue(folder: writer)
        awaitedOutcome = nil
    }

    override func tearDown() async throws {
        // A held write that a failing test never released would keep the drain alive.
        writer?.releaseAll()
        sut = nil
        writer = nil
        try await super.tearDown()
    }

    // MARK: - A Save waits for its write

    /// The reported defect, at the seam: the sheet dismissed before the write ran. `settle` must
    /// not return while the write carrying the staged value is still in flight.
    ///
    /// RED: resolve waiters at `stage` instead of after the write → `awaitedOutcome` is set
    /// while the writer still holds the value.
    func testSettle_returnsOnlyOnceTheWriteCarryingTheValueHasFinished() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "ticked")
        sut.stage(alpha, editedIn: Self.folder)

        let save = Task { self.awaitedOutcome = await self.sut.settle(teamID: alpha.id) }
        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        await yieldABit()
        XCTAssertNil(awaitedOutcome, "settle returned while its write was still in flight")

        writer.releaseAll()
        await save.value
        XCTAssertEqual(awaitedOutcome, .persisted)
    }

    /// The same promise through the commit a sheet's Save makes — what `RoleEditorSheet` and
    /// `ArtifactEditorSheet` call.
    func testCommit_returnsOnlyOnceTheWriteHasLanded() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "before")
        let binding = sut.binding(for: alpha, editedIn: Self.folder)
        var edited = binding.wrappedValue
        edited.description = "saved"
        let session = TeamEditCommitQueue.Session(team: alpha, lifecycle: Self.folder)

        let save = Task { self.awaitedOutcome = await self.sut.commit(edited, as: session) }
        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        await yieldABit()
        XCTAssertNil(awaitedOutcome, "the Save came back before its write landed")
        XCTAssertEqual(writer.calls.first?.team.description, "saved")

        writer.releaseAll()
        await save.value
        XCTAssertEqual(awaitedOutcome, .persisted)
    }

    /// A refused write reaches the Save that waited on it — with the writer's reason, so the sheet
    /// can stay open and say why.
    func testSettle_carriesTheReasonAWriteWasRefused() async {
        writer.outcomes = [.failed(reason: "teams.json: disk full")]
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.folder)

        let outcome = await sut.settle(teamID: alpha.id)

        XCTAssertEqual(outcome, .failed(reason: "teams.json: disk full"))
        XCTAssertEqual(outcome.failureReason, "teams.json: disk full")
    }

    /// Nothing staged for the team — nothing to wait for, and nothing to report.
    func testSettle_withNothingStaged_answersAtOnceThatNothingWasWaiting() async {
        let outcome = await sut.settle(teamID: "never-staged")
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(writer.calls.isEmpty)
    }

    /// A queue nobody wired cannot save anything, and must say so rather than pretend.
    func testAnUnwiredQueue_refusesWithAReason() async {
        sut = TeamEditCommitQueue()
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.folder)

        let outcome = await sut.settle(teamID: alpha.id)

        XCTAssertNotNil(outcome.failureReason)
        XCTAssertEqual(sut.failure(for: alpha.id, editedIn: Self.folder), outcome.failureReason)
    }

    // MARK: - Edits compose and land in order

    /// Two writes in one handler — `TeamGraphEditorView.ensureAllRolesHavePositions` does
    /// several — both start from the value staged before them, not from the team as rendered.
    ///
    /// RED: make the binding's getter return the captured `team` only → the second write starts
    /// from the rendered copy and the supervisor-mode change is gone from the written value.
    func testTwoWritesInOneHandler_composeOnTheStagedValue() async {
        let alpha = Self.team("Alpha", marker: "rendered")
        let binding = sut.binding(for: alpha, editedIn: Self.folder)

        binding.wrappedValue.settings.supervisorMode = .autonomous
        binding.wrappedValue.description = "described"
        _ = await sut.settle(teamID: alpha.id)

        let written = writer.calls.last?.team
        XCTAssertEqual(written?.settings.supervisorMode, .autonomous, "the first write was dropped")
        XCTAssertEqual(written?.description, "described")
    }

    /// Per-keystroke edits while a write is in flight: the queue writes the one in flight, then
    /// the LATEST — never an intermediate one, never out of order.
    ///
    /// RED: append every staged value to a FIFO instead of replacing the waiting one → the
    /// writer sees `v1, v2, v3`; drop the re-queue of a team already taken → `v3` is never
    /// written.
    func testRapidEditsWhileAWriteIsInFlight_landInOrder_latestWins() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "v0")
        let binding = sut.binding(for: alpha, editedIn: Self.folder)

        binding.wrappedValue.description = "v1"
        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        binding.wrappedValue.description = "v2"
        binding.wrappedValue.description = "v3"
        XCTAssertEqual(binding.wrappedValue.description, "v3", "the editor reads the newest staged value")

        writer.releaseAll()
        let outcome = await sut.settle(teamID: alpha.id)

        XCTAssertEqual(outcome, .persisted)
        XCTAssertEqual(writer.calls.map(\.team.description), ["v1", "v3"])
        XCTAssertNil(sut.draft(for: alpha.id, editedIn: Self.folder),
                     "a value whose write landed is the snapshot's again — the draft must go")
    }

    /// One write at a time, across teams, in the order they were staged.
    func testWritesRunOneAtATime_inStagingOrder_acrossTeams() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "a")
        let beta = Self.team("Beta", marker: "b")
        let gamma = Self.team("Gamma", marker: "c")
        sut.stage(alpha, editedIn: Self.folder)
        sut.stage(beta, editedIn: Self.folder)
        sut.stage(gamma, editedIn: Self.folder)

        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        writer.releaseOne()
        await waitUntil("the second write is in flight") { self.writer.calls.count == 2 }
        writer.releaseOne()
        await waitUntil("the third write is in flight") { self.writer.calls.count == 3 }
        writer.releaseAll()
        await sut.settleAll()

        XCTAssertEqual(writer.calls.map(\.team.id), [alpha.id, beta.id, gamma.id])
        XCTAssertEqual(writer.maxInFlight, 1, "two writes of teams.json ran at once")
    }

    /// A team re-staged while its earlier value still WAITS (another team's write is in flight)
    /// keeps its place in the order and only its value moves: the writes land Alpha, Beta, Gamma
    /// with Beta's newest value — not Alpha, Gamma, Beta, and not Beta twice.
    ///
    /// RED: append on every stage → Beta is written twice; drop a waiting team to the end on a
    /// re-stage → Beta lands after Gamma.
    func testAReStageOfAWaitingTeam_keepsItsPlaceInTheOrder_withTheNewerValue() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "a")
        let beta = Self.team("Beta", marker: "b1")
        let gamma = Self.team("Gamma", marker: "c")
        sut.stage(alpha, editedIn: Self.folder)
        await waitUntil("Alpha's write is in flight") { self.writer.calls.count == 1 }
        sut.stage(beta, editedIn: Self.folder)
        sut.stage(gamma, editedIn: Self.folder)
        sut.stage(Self.team("Beta", marker: "b2"), editedIn: Self.folder)

        writer.releaseAll()
        await sut.settleAll()

        XCTAssertEqual(writer.calls.map(\.team.description), ["a", "b2", "c"])
        XCTAssertTrue(sut.drafts.isEmpty)
    }

    /// `settleAll` waits for every team that had something staged.
    func testSettleAll_waitsForEveryTeamWithAStagedValue() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "a")
        let beta = Self.team("Beta", marker: "b")
        sut.stage(alpha, editedIn: Self.folder)
        sut.stage(beta, editedIn: Self.folder)

        let settleAll = Task { await self.sut.settleAll(); self.awaitedOutcome = .persisted }
        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        writer.releaseOne()
        await waitUntil("the second write is in flight") { self.writer.calls.count == 2 }
        await yieldABit()
        XCTAssertNil(awaitedOutcome, "settleAll returned with the second team still being written")

        writer.releaseAll()
        await settleAll.value
        XCTAssertTrue(sut.drafts.isEmpty)
    }

    /// A value staged while `settleAll` waits is waited for too: Restore Default Teams settles
    /// first so that no edit lands over it afterwards, and an edit staged during that wait is one.
    ///
    /// RED: settle only the teams that had a draft when `settleAll` began → it returns with Beta's
    /// write still held.
    func testSettleAll_waitsForAValueStagedWhileItWaits() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "a")
        let beta = Self.team("Beta", marker: "b")
        sut.stage(alpha, editedIn: Self.folder)
        let settleAll = Task { await self.sut.settleAll(); self.awaitedOutcome = .persisted }
        await waitUntil("Alpha's write is in flight") { self.writer.calls.count == 1 }
        sut.stage(beta, editedIn: Self.folder)

        writer.releaseOne()
        await waitUntil("Beta's write is in flight") { self.writer.calls.count == 2 }
        await yieldABit()
        XCTAssertNil(awaitedOutcome, "settleAll returned with Beta's write still in flight")

        writer.releaseAll()
        await settleAll.value
        XCTAssertTrue(sut.drafts.isEmpty)
    }

    /// Nothing staged and nothing owed: `settleAll` has nothing to wait for and comes back at once
    /// — a hang here is the failure.
    func testSettleAll_withNothingStagedAndNothingOwed_returnsAtOnce() async {
        await sut.settleAll()

        XCTAssertTrue(writer.calls.isEmpty)
        XCTAssertEqual(writer.reconcileCount, 0)
    }

    // MARK: - What the editor reads back

    /// Until its write is done the editor reads the staged value, after it the snapshot's.
    func testTheStagedValue_isReadBackUntilItsWriteFinishes() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "rendered")
        let binding = sut.binding(for: alpha, editedIn: Self.folder)
        XCTAssertEqual(binding.wrappedValue.description, "rendered", "no draft: the rendered team")

        binding.wrappedValue.description = "staged"
        XCTAssertEqual(binding.wrappedValue.description, "staged")
        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        XCTAssertEqual(binding.wrappedValue.description, "staged", "in flight is still not stored")

        writer.releaseAll()
        _ = await sut.settle(teamID: alpha.id)
        XCTAssertNil(sut.draft(for: alpha.id, editedIn: Self.folder))
    }

    /// A refused value is not kept: the editor goes back to what is stored (the writer re-synced
    /// the snapshot from disk), and the reason is kept for the editor's banner until a later write
    /// of that team succeeds.
    func testARefusedWrite_dropsTheDraft_andLeavesItsReasonUntilTheNextSuccess() async {
        writer.outcomes = [.failed(reason: "refused"), .persisted]
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.folder)
        _ = await sut.settle(teamID: alpha.id)

        XCTAssertNil(sut.draft(for: alpha.id, editedIn: Self.folder))
        XCTAssertEqual(sut.failure(for: alpha.id, editedIn: Self.folder), "refused")

        sut.stage(Self.team("Alpha", marker: "v2"), editedIn: Self.folder)
        _ = await sut.settle(teamID: alpha.id)
        XCTAssertNil(sut.failure(for: alpha.id, editedIn: Self.folder), "a later success clears it")
    }

    /// An unchanged write is a success too: it clears an earlier failure.
    func testAnUnchangedWrite_countsAsSaved() async {
        writer.outcomes = [.failed(reason: "refused"), .unchanged]
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.folder)
        _ = await sut.settle(teamID: alpha.id)
        sut.stage(alpha, editedIn: Self.folder)

        let outcome = await sut.settle(teamID: alpha.id)

        XCTAssertNil(outcome.failureReason)
        XCTAssertNil(sut.failure(for: alpha.id, editedIn: Self.folder))
    }

    /// A view that read the team through the binding — the graph, a toggle drawing its `[x]` —
    /// is invalidated by the STAGE, not only once the write lands: until then it would draw the
    /// value from before the click. The decision `drafts` documents (review finding 6, 2026-11-08):
    /// observed, at the cost of one more render pass per staged value.
    ///
    /// RED: mark `drafts` `@ObservationIgnored` → nothing the read registered changes at the stage,
    /// and `onChange` does not fire while the write is held.
    func testAStagedValue_reachesWhatReadTheTeam_beforeItIsWritten() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "rendered")
        let binding = sut.binding(for: alpha, editedIn: Self.folder)
        let invalidated = ObservationFlag()
        withObservationTracking {
            _ = binding.wrappedValue.settings.meetingsEnabled
        } onChange: {
            invalidated.fired = true
        }

        binding.wrappedValue.settings.meetingsEnabled.toggle()
        await Task.yield()

        XCTAssertTrue(invalidated.fired, "the toggle would draw its old state until the write lands")
        XCTAssertTrue(writer.calls.count <= 1, "precondition: the write is held, not landed")
        XCTAssertEqual(binding.wrappedValue.settings.meetingsEnabled, !alpha.settings.meetingsEnabled)
    }

    // MARK: - A value stays in its folder

    /// Template teams share ids across folders. A value edited in one folder must never be read
    /// back as the next folder's team of the same id.
    func testAStagedValue_isReadBackOnlyInTheFolderItWasEditedIn() async {
        writer.isHolding = true
        let alpha = Self.team("Alpha", marker: "folder A")
        sut.stage(alpha, editedIn: Self.folder)

        XCTAssertEqual(sut.draft(for: alpha.id, editedIn: Self.folder)?.description, "folder A")
        XCTAssertNil(sut.draft(for: alpha.id, editedIn: Self.nextFolder))
        let nextFolderBinding = sut.binding(for: Self.team("Alpha", marker: "folder B"), editedIn: Self.nextFolder)
        XCTAssertEqual(nextFolderBinding.wrappedValue.description, "folder B")
    }

    /// The writer is handed the lifecycle the value was edited in — the orchestrator refuses a
    /// value whose folder is no longer open.
    func testTheWriterIsHandedTheLifecycleTheValueWasEditedIn() async {
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.nextFolder)
        _ = await sut.settle(teamID: alpha.id)
        XCTAssertEqual(writer.calls.first?.lifecycle, Self.nextFolder)
    }

    /// A value from a folder that is gone can never land. When the next folder stages the same team
    /// id over it, whoever waits on the old value hears so at once — not the next folder's outcome.
    func testRestagingInAnotherFolder_failsTheWaitOnTheOldValueAtOnce() async {
        writer.isHolding = true
        let blocker = Self.team("Blocker", marker: "x")
        let alpha = Self.team("Alpha", marker: "folder A")
        sut.stage(blocker, editedIn: Self.folder)
        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        sut.stage(alpha, editedIn: Self.folder)
        let save = Task { self.awaitedOutcome = await self.sut.settle(teamID: alpha.id) }
        await yieldABit()
        XCTAssertNil(awaitedOutcome)

        sut.stage(Self.team("Alpha", marker: "folder B"), editedIn: Self.nextFolder)
        await save.value

        XCTAssertNotNil(awaitedOutcome?.failureReason, "the old value's wait was answered by the new folder")
        writer.releaseAll()
        await sut.settleAll()
        XCTAssertEqual(writer.calls.map(\.team.description), ["x", "folder B"],
                       "the old folder's value must never be written")
    }

    /// A failure is reported in the folder whose write failed, not in the next one.
    func testAFailure_isReportedOnlyInTheFolderItHappenedIn() async {
        writer.outcomes = [.failed(reason: "refused")]
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.folder)
        _ = await sut.settle(teamID: alpha.id)

        XCTAssertEqual(sut.failure(for: alpha.id, editedIn: Self.folder), "refused")
        XCTAssertNil(sut.failure(for: alpha.id, editedIn: Self.nextFolder))
    }

    // MARK: - A sheet saves into what it opened on

    /// The sheet opened in a folder that a later open has ended: its Save writes nothing — and
    /// stages nothing, so it cannot take the place of an edit the open folder staged.
    func testACommit_asASessionWhoseFolderHasEnded_isRefused_andNothingIsStaged() async {
        let alpha = Self.team("Alpha", marker: "edited in folder A")
        let session = TeamEditCommitQueue.Session(team: alpha, lifecycle: Self.folder)
        writer.endedLifecycles = [Self.folder]

        let outcome = await sut.commit(alpha, as: session)

        XCTAssertEqual(outcome, .failed(reason: TeamEditCommitQueue.folderChangedReason(teamName: "Alpha")))
        XCTAssertTrue(writer.calls.isEmpty, "a value from a folder that is gone must not be written")
        XCTAssertTrue(sut.drafts.isEmpty, "nor staged")
    }

    /// The editor moved to another team while the sheet was open: the team the sheet's binding
    /// names now is not the one it opened on, and its Save writes neither.
    func testACommit_ofAnotherTeamThanTheSessionOpenedOn_isRefused() async {
        let alpha = Self.team("Alpha", marker: "opened")
        let beta = Self.team("Beta", marker: "shown now")
        let session = TeamEditCommitQueue.Session(team: alpha, lifecycle: Self.folder)

        let outcome = await sut.commit(beta, as: session)

        XCTAssertEqual(outcome, .failed(reason: TeamEditCommitQueue.otherTeamReason(opened: session)))
        XCTAssertTrue(writer.calls.isEmpty)
        XCTAssertNil(sut.refusal(toSave: session, into: alpha), "the team it opened on, in its folder, may be saved")
    }

    /// The refusal names the team as the sheet OPENED it — the `Session`'s name, what the person
    /// saw when they clicked — not the name the edited value carries now: the Team Editor's
    /// General tab may have renamed the team through the binding while the sheet stayed open. The
    /// one observable reason `commit` asks `refusal(toSave:into:)` at its door rather than
    /// `stage`'s guard, which knows only the value.
    func testACommit_refusedForItsFolder_namesTheTeamTheSheetOpenedOn() async {
        let opened = Self.team("Alpha", marker: "opened")
        var renamed = opened
        renamed.name = "Alpha, renamed meanwhile"
        let session = TeamEditCommitQueue.Session(team: opened, lifecycle: Self.folder)
        writer.endedLifecycles = [Self.folder]

        let outcome = await sut.commit(renamed, as: session)

        XCTAssertEqual(outcome, .failed(reason: TeamEditCommitQueue.folderChangedReason(teamName: "Alpha")))
        XCTAssertTrue(writer.calls.isEmpty)
        XCTAssertTrue(sut.drafts.isEmpty, "nor staged")
    }

    /// A binding rendered before a folder switch fires after it: the folder it was read in is
    /// gone, so its value is refused at `stage` — and the open folder's edit of the team with the
    /// same id stays the one that is written, its waiter answered by its own write.
    ///
    /// RED: drop the lifecycle guard in `stage` → the old folder's value replaces the open
    /// folder's draft, its Save hears "the work folder changed", and only the old value is written.
    func testAStageFromAFolderThatHasEnded_cannotTakeThePlaceOfTheOpenFoldersEdit() async {
        writer.isHolding = true
        let blocker = Self.team("Blocker", marker: "x")
        let inB = Self.team("Alpha", marker: "folder B")
        sut.stage(blocker, editedIn: Self.nextFolder)
        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        sut.stage(inB, editedIn: Self.nextFolder)
        let save = Task { self.awaitedOutcome = await self.sut.settle(teamID: inB.id) }
        await yieldABit()
        writer.endedLifecycles = [Self.folder]

        let refusal = sut.stage(Self.team("Alpha", marker: "folder A"), editedIn: Self.folder)

        XCTAssertNotNil(refusal)
        XCTAssertEqual(sut.draft(for: inB.id, editedIn: Self.nextFolder)?.description, "folder B")
        writer.releaseAll()
        await save.value
        XCTAssertEqual(awaitedOutcome, .persisted)
        XCTAssertEqual(writer.calls.map(\.team.description), ["x", "folder B"])
    }

    // MARK: - What a write leaves owed

    /// A write that changed `teams.json` owes the folder's reconcile. The Save that waited for the
    /// write is answered without it; `settleAll` waits for it too.
    ///
    /// RED: owe nothing after a write (the reconcile the writer used to detach) →
    /// `reconcileCount` stays 0 and `settleAll` returns at once.
    func testAWrite_owesTheReconcile_whichTheSaveDoesNotWaitFor_andSettleAllDoes() async {
        writer.isHoldingReconcile = true
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.folder)

        let outcome = await sut.settle(teamID: alpha.id)
        XCTAssertEqual(outcome, .persisted, "the Save is answered while the reconcile is still held")
        await waitUntil("the reconcile has started") { self.writer.reconcileCount == 1 }

        let settled = Task { await self.sut.settleAll(); self.awaitedOutcome = .persisted }
        await yieldABit()
        XCTAssertNil(awaitedOutcome, "settleAll returned with the reconcile still running")
        writer.releaseReconcile()
        await settled.value
        XCTAssertEqual(writer.reconcileCount, 1)
    }

    /// Writes keep landing while a reconcile runs — it never stands in front of one — and what they
    /// owe is one more pass after it, not one per write.
    func testWritesDuringAReconcile_areNotHeldBack_andOweOneMorePass() async {
        writer.isHoldingReconcile = true
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.folder)
        _ = await sut.settle(teamID: alpha.id)
        await waitUntil("the first reconcile has started") { self.writer.reconcileCount == 1 }

        // Polled, not settled: a write that waited for the reconcile would never land while it is
        // held, and this test must fail on that rather than hang.
        sut.stage(Self.team("Alpha", marker: "v2"), editedIn: Self.folder)
        sut.stage(Self.team("Beta", marker: "b"), editedIn: Self.folder)
        await waitUntil("both writes landed while the reconcile was held") { self.writer.calls.count == 3 }
        XCTAssertEqual(writer.calls.map(\.team.description), ["v1", "v2", "b"],
                       "a write waited for the reconcile")

        writer.releaseReconcile()
        await sut.settleAll()
        XCTAssertEqual(writer.reconcileCount, 2, "the writes during a pass owe one more pass, not one each")
    }

    /// A refused write and an unchanged one wrote nothing: nothing is owed.
    func testARefusedOrUnchangedWrite_owesNothing() async {
        writer.outcomes = [.failed(reason: "refused"), .unchanged]
        let alpha = Self.team("Alpha", marker: "v1")
        sut.stage(alpha, editedIn: Self.folder)
        _ = await sut.settle(teamID: alpha.id)
        sut.stage(Self.team("Alpha", marker: "v2"), editedIn: Self.folder)
        _ = await sut.settle(teamID: alpha.id)

        await sut.settleAll()
        XCTAssertEqual(writer.reconcileCount, 0)
    }

    // MARK: - A refusal is heard in the editor

    /// A refused editor action — Delete, Restore Default Teams, … — is kept for the editor's
    /// banner until the next one lands, and the outcome reaches the action that awaited it.
    ///
    /// RED: drop the outcome in `perform` (the pre-fix `await store.mutateWorkFolder { … }` whose
    /// result nobody read) → no reason is kept for the banner.
    func testARefusedEditorAction_isKeptForTheBanner_untilTheNextOneLands() async {
        let refused = await sut.perform(editedIn: Self.folder) { .failed(reason: "teams.json: disk full") }

        XCTAssertEqual(refused, .failed(reason: "teams.json: disk full"))
        XCTAssertEqual(sut.actionFailure(editedIn: Self.folder), "teams.json: disk full")

        await sut.perform(editedIn: Self.folder) { .unchanged }
        XCTAssertNil(sut.actionFailure(editedIn: Self.folder), "an action that landed clears the row")
    }

    /// A refusal belongs to the folder it happened in.
    func testARefusedEditorAction_isReportedOnlyInItsFolder() async {
        await sut.perform(editedIn: Self.folder) { .failed(reason: "refused") }

        XCTAssertNil(sut.actionFailure(editedIn: Self.nextFolder))
    }

    /// A write from beside the queue replaced a team whose edit had failed: the team on disk is
    /// what the editor shows now, so the failure row goes. A team that write left alone, and a
    /// failure in another folder, keep theirs; a team the write removed loses its row too.
    ///
    /// RED: keep `failures` until a queue write of the same team (the pre-fix rule) → the
    /// replaced team's row survives Restore Default Teams.
    func testAWriteFromBesideTheQueue_clearsTheRowsOfTheTeamsItReplaced() async {
        writer.outcomes = [.failed(reason: "a"), .failed(reason: "b"), .failed(reason: "c"), .failed(reason: "d")]
        let replaced = Self.team("Alpha", marker: "v1")
        let untouched = Self.team("Beta", marker: "v1")
        let removed = Self.team("Gamma", marker: "v1")
        let elsewhere = Self.team("Delta", marker: "v1")
        sut.stage(replaced, editedIn: Self.folder)
        sut.stage(untouched, editedIn: Self.folder)
        sut.stage(removed, editedIn: Self.folder)
        sut.stage(elsewhere, editedIn: Self.nextFolder)
        await sut.settleAll()
        XCTAssertEqual(sut.failures.count, 4, "precondition: every write failed")

        sut.teamsWereWritten(
            replacing: [replaced, untouched, removed, elsewhere],
            with: [Self.team("Alpha", marker: "restored"), untouched, elsewhere],
            editedIn: Self.folder)

        XCTAssertNil(sut.failure(for: replaced.id, editedIn: Self.folder), "a replaced team's row must go")
        XCTAssertNil(sut.failure(for: removed.id, editedIn: Self.folder), "a removed team's row must go")
        XCTAssertEqual(sut.failure(for: untouched.id, editedIn: Self.folder), "b", "a team left alone keeps its row")
        XCTAssertEqual(sut.failure(for: elsewhere.id, editedIn: Self.nextFolder), "d",
                       "a write in one folder says nothing about another")
    }

    /// Two teams of one id do reach the folder: `addTeam` renames at ITS door only, `teams` is a
    /// plain array any `mutateWorkFolder` closure may append to, and a `teams.json` edited by hand
    /// decodes as it is. The row then follows the FIRST team of the id — the one `first(where:)`
    /// finds, so the one `Folder.storedTeam` shows the editor: a write that replaced the first
    /// copy clears the row, one that touched only the second leaves it.
    ///
    /// RED: key the teams with `uniqueKeysWithValues` → a trap on the second copy; key them last
    /// copy wins → Alpha's row goes for a copy the editor never shows, and Beta's stays.
    func testAWriteFromBesideTheQueue_judgesATeamIDHeldTwice_byItsFirstCopy() async {
        writer.outcomes = [.failed(reason: "a"), .failed(reason: "b")]
        let alpha = Self.team("Alpha", marker: "first")
        let beta = Self.team("Beta", marker: "first")
        sut.stage(alpha, editedIn: Self.folder)
        sut.stage(beta, editedIn: Self.folder)
        await sut.settleAll()
        XCTAssertEqual(sut.failures.count, 2, "precondition: both writes failed")

        sut.teamsWereWritten(
            replacing: [alpha, Self.team("Alpha", marker: "second"), beta, Self.team("Beta", marker: "second")],
            with: [
                alpha, Self.team("Alpha", marker: "second, rewritten"),
                Self.team("Beta", marker: "first, rewritten"), Self.team("Beta", marker: "second"),
            ],
            editedIn: Self.folder)

        XCTAssertEqual(sut.failure(for: alpha.id, editedIn: Self.folder), "a",
                       "only the copy the editor does not show changed: the row stays")
        XCTAssertNil(sut.failure(for: beta.id, editedIn: Self.folder),
                     "the copy the editor shows was replaced: the row goes")
    }

    // MARK: - What the binding reads once no draft covers the team

    /// A write that landed after the binding was rendered — from beside the queue, or the queue's
    /// own — is the base of the next edit: the getter reads the team as stored, not the copy it
    /// was rendered with, so a read-modify-write through it cannot revert that write.
    ///
    /// RED: let the getter fall back to the rendered `team` → the description reads "rendered"
    /// and the written value carries it back.
    func testTheBinding_readsTheStoredTeam_onceNoDraftCoversIt() async {
        let rendered = Self.team("Alpha", marker: "rendered")
        let binding = sut.binding(for: rendered, editedIn: Self.folder)
        writer.stored[rendered.id] = Self.team("Alpha", marker: "written since")

        XCTAssertEqual(binding.wrappedValue.description, "written since")
        binding.wrappedValue.settings.supervisorMode = .autonomous
        _ = await sut.settle(teamID: rendered.id)

        XCTAssertEqual(writer.calls.last?.team.description, "written since", "the edit reverted a write it did not make")
        XCTAssertEqual(writer.calls.last?.team.settings.supervisorMode, .autonomous)
    }

    /// Once its folder is gone, the binding keeps the copy it was rendered with: the folder that is
    /// open now may hold a team of the same id, and that one is not what this binding edited.
    func testTheBinding_ofAFolderThatHasEnded_keepsItsRenderedCopy() async {
        let rendered = Self.team("Alpha", marker: "folder A")
        let binding = sut.binding(for: rendered, editedIn: Self.folder)
        writer.stored[rendered.id] = Self.team("Alpha", marker: "folder B")
        writer.endedLifecycles = [Self.folder]

        XCTAssertEqual(binding.wrappedValue.description, "folder A")
    }

    // MARK: - Helpers

    private static func team(_ name: String, marker: String) -> Team {
        var team = TeamTemplateFactory.empty(name: name)
        team.description = marker
        return team
    }

    /// Long enough for any task that COULD run to have run — the negative half of a wait (the
    /// shared `waitUntil` is the positive half).
    private func yieldABit() async {
        for _ in 0..<200 { await Task.yield() }
    }
}
