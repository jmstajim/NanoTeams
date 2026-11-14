import Foundation
import Observation

/// The Team Editor's write path: whole-team values, written one at a time, latest first, and
/// awaitable by the Save that staged one.
///
/// Every Team Editor surface — settings, prompts, roles, artifacts, the graph, and the role and
/// artifact sheets — edits a team through one `Binding<Team>` (`binding(for:editedIn:)`). Until
/// 2026-11-08 its setter started a `Task { await mutateWorkFolder … }` per write and its getter
/// returned the team as last rendered, so:
/// - a sheet's Save dismissed on the assignment, before anything was written, and a refused
///   `teams.json` write was a banner in another window — a ticked tool could vanish with no sign;
/// - two writes in one handler both started from the rendered copy, and the second dropped the
///   first;
/// - nothing ordered the writes on their way to disk.
///
/// What this queue guarantees instead:
/// - **Latest wins, per team.** A value staged while an earlier one waits replaces it. Every value
///   is the whole team and the binding reads the staged value back (`draft(for:editedIn:)`), so
///   the later value already carries the earlier edit.
/// - **One write at a time**, in the order teams were staged.
/// - **A Save can wait.** `settle(teamID:)` returns once everything staged for that team so far has
///   been written, with the outcome of the write that carried the newest value.
/// - **A value stays in its folder.** It carries the folder lifecycle it was read in: `stage`
///   refuses it once that lifecycle has ended, and the writer refuses it in any other — template
///   teams share ids across folders, so a value that outlived a folder switch would otherwise
///   replace the next folder's team of the same id.
/// - **A sheet saves into what it opened on.** Its `Session` is captured once, by the click that
///   opens it (`TeamEditSheetRequest`), and `commit(_:as:)` refuses a Save into another folder or
///   another team.
/// - **What a write leaves owed is awaitable.** A write that changed `teams.json` owes the folder's
///   residency reconcile; it runs beside the writes, never in front of one — a Save waits for
///   `teams.json`, not for a model server's listing — and `settleAll()` waits for it.
/// - **A refusal is heard in the editor.** A team's failed write stays in the Team Editor's banner
///   until a later write of that team lands — from here or from beside the queue
///   (`teamsWereWritten`) — and so does a refused editor action that writes the folder itself
///   (`perform`). Until 2026-11-08 both reached only the main window, behind Settings.
///
/// Owned by the orchestrator (`NTMSOrchestrator.teamEdits`), which is its `Folder`: one queue per
/// process, so two editors cannot race each other to `teams.json` either.
@MainActor
@Observable
final class TeamEditCommitQueue {

    /// The open work folder as the queue sees it — `NTMSOrchestrator` in the app.
    @MainActor
    protocol Folder: AnyObject {
        /// Replaces the stored team of `team.id` with `team` and says how it went
        /// (`NTMSOrchestrator.commitEditedTeam`).
        func writeEditedTeam(_ team: Team, editedIn lifecycle: WorkFolderLifecycle) async -> WorkFolderMutationOutcome
        /// Whether `lifecycle` is the open folder's: no later open has started since it began.
        func isCurrentFolderLifecycle(_ lifecycle: WorkFolderLifecycle) -> Bool
        /// The team of `teamID` as the folder stores it now — `nil` once `lifecycle` has ended,
        /// or when the folder holds no such team.
        func storedTeam(_ teamID: NTMSID, editedIn lifecycle: WorkFolderLifecycle) -> Team?
        /// What a write that changed `teams.json` leaves owed: the model-residency reconcile — a
        /// per-role `llmOverride` cleared in the editor orphans the model it pinned.
        func reconcileAfterTeamWrites() async
    }

    /// What the click that opened a Team Editor sheet captured: the team it edits and the folder
    /// lifecycle that team was read in. Captured ONCE (`WorkFolderLifecycle`) — never read off the
    /// binding the sheet is handed, which the editor rebuilds on every render: after a folder
    /// switch that binding names the next folder's team of the same id, after an edited-team
    /// change another team, and a Save through it wrote the draft there.
    nonisolated struct Session: Equatable, Sendable {
        let teamID: NTMSID
        let teamName: String
        let lifecycle: WorkFolderLifecycle

        init(team: Team, lifecycle: WorkFolderLifecycle) {
            self.teamID = team.id
            self.teamName = team.name
            self.lifecycle = lifecycle
        }
    }

    /// The newest value staged for a team, held until the write carrying it is done.
    struct Draft {
        let team: Team
        let lifecycle: WorkFolderLifecycle
        let revision: Int
    }

    /// Why the newest finished write of a team failed, in the folder it failed in.
    struct Failure: Equatable {
        let reason: String
        let lifecycle: WorkFolderLifecycle
    }

    /// What a write answers when nothing is wired to perform it.
    static let notConnectedReason = "Could not save the team: nothing is connected to write it."

    /// Why a value read in a folder that is no longer open is not written.
    static func folderChangedReason(teamName: String) -> String {
        "Could not save “\(teamName)”: another work folder was opened after this edit began, "
            + "so nothing was written."
    }

    /// Why a sheet opened on one team does not save into the team the editor shows now.
    static func otherTeamReason(opened session: Session) -> String {
        "Could not save into “\(session.teamName)”: the Team Editor switched to another team "
            + "while this was open, so nothing was written."
    }

    /// Why an editor action begun in a folder that is no longer open changed nothing.
    static let actionFolderChangedReason =
        "Nothing was changed: another work folder was opened before the Team Editor could write it."

    /// Read back by the editor's binding while a value waits or is in flight.
    ///
    /// OBSERVED, on purpose (2026-11-08, review finding 6). The write that carries a staged value
    /// runs one main-queue hop later and takes ~17 ms (`commitEditedTeam` on the FAANG folder,
    /// median of 40, Debug). If SwiftUI renders inside that hop, observing costs a render pass per
    /// staged value — the graph and the open tab render at the stage and again at the write — and
    /// that pass is what keeps a control drawn from the binding during `body` from showing the old
    /// value for those ~17 ms: the `[x]` of `TerminalToggleStyle` (Team meetings, invitable
    /// roles), the meeting coordinator's `TerminalPicker`, and a dragged graph node, whose
    /// `TeamNodeView` zeroes its own drag offset in the same handler that stages the new position
    /// and would jump back to the old one until the graph re-rendered. If it does not render in
    /// between, the stage and the write fall into one pass and observing costs nothing. Either
    /// way ignoring it saves no pass that is not paid for in a lagging control; the native text
    /// editors are the only controls that would not lag (they hold the typed text themselves).
    /// Pinned by `TeamEditCommitQueueTests.testAStagedValue_reachesWhatReadTheTeam_beforeItIsWritten`.
    private(set) var drafts: [NTMSID: Draft] = [:]
    /// Shown by the Team Editor until a later write of the same team succeeds — this queue's, or
    /// one from beside it that replaced the team (`teamsWereWritten`).
    private(set) var failures: [NTMSID: Failure] = [:]
    /// Why the newest Team Editor action that writes the folder itself was refused — shown by the
    /// editor until the next such action lands (`perform`).
    private(set) var actionFailure: Failure?

    /// The folder the queue writes into. Weak: the orchestrator owns the queue.
    @ObservationIgnored weak var folder: (any Folder)?

    /// The newest draft of every team no write has taken yet, in staging order — the ONE list the
    /// drain takes from, so there is no second place to look a queued team up in. A team re-staged
    /// while its draft waits here keeps its place and gets the newer value; one re-staged while its
    /// write is in flight is queued again, behind the rest. `drafts` is the read side of the same
    /// values and also covers the one in flight.
    @ObservationIgnored private var queued: [Draft] = []
    @ObservationIgnored private var stagedRevision: [NTMSID: Int] = [:]
    @ObservationIgnored private var finishedRevision: [NTMSID: Int] = [:]
    @ObservationIgnored private var waiters: [NTMSID: [Waiter]] = [:]
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    /// The reconcile writes left owed, while it runs; `reconcileOwed` asks it for one more pass.
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileOwed = false

    private struct Waiter {
        let revision: Int
        let continuation: CheckedContinuation<WorkFolderMutationOutcome, Never>
    }

    /// `folder` is assigned by the orchestrator after its own init; `nil` refuses every write
    /// rather than pretending to save.
    init(folder: (any Folder)? = nil) {
        self.folder = folder
    }

    // MARK: - Reading

    /// The value staged for `teamID` in `lifecycle` and not yet done writing — `nil` when there
    /// is none, or when it was staged in another folder.
    func draft(for teamID: NTMSID, editedIn lifecycle: WorkFolderLifecycle) -> Team? {
        guard let draft = drafts[teamID], draft.lifecycle == lifecycle else { return nil }
        return draft.team
    }

    /// Why the newest finished write of `teamID` failed, if it did, in this folder.
    func failure(for teamID: NTMSID, editedIn lifecycle: WorkFolderLifecycle) -> String? {
        guard let failure = failures[teamID], failure.lifecycle == lifecycle else { return nil }
        return failure.reason
    }

    /// Why the newest Team Editor action that writes the folder was refused, if it was, in this
    /// folder.
    func actionFailure(editedIn lifecycle: WorkFolderLifecycle) -> String? {
        guard let actionFailure, actionFailure.lifecycle == lifecycle else { return nil }
        return actionFailure.reason
    }

    /// Why a sheet opened as `session` may not save into `team` — the team its binding names now —
    /// or `nil` when it may: `team` is the team it opened on, in the folder it opened in.
    func refusal(toSave session: Session, into team: Team) -> String? {
        guard team.id == session.teamID else { return Self.otherTeamReason(opened: session) }
        guard isCurrent(session.lifecycle) else {
            return Self.folderChangedReason(teamName: session.teamName)
        }
        return nil
    }

    // MARK: - Writing

    /// Queues `team` to replace the stored team of its id and returns at once — `nil` when it is
    /// queued (`settle(teamID:)` waits for the write), otherwise why it is not: the folder it was
    /// read in is no longer open, so the writer could only refuse it, and staged it would take the
    /// place of a value the open folder staged for its team of the same id.
    @discardableResult
    func stage(_ team: Team, editedIn lifecycle: WorkFolderLifecycle) -> String? {
        guard isCurrent(lifecycle) else { return Self.folderChangedReason(teamName: team.name) }
        enqueue(team, editedIn: lifecycle)
        return nil
    }

    /// A sheet's Save: `edited` written as the team the sheet opened on, in the folder it opened
    /// in, and the write that carries it awaited. The sheet closes only on a `nil`
    /// `failureReason`; a refusal — the folder or the edited team changed while it was open, or
    /// the write failed — keeps it open with the reason.
    ///
    /// Its door is `refusal(toSave:into:)` — the same check the sheet shows before it saves, and
    /// one that names the team as the sheet OPENED it — so the value goes straight to the queue:
    /// `stage`'s guard asks the lifecycle question this one has just answered.
    func commit(_ edited: Team, as session: Session) async -> WorkFolderMutationOutcome {
        if let refusal = refusal(toSave: session, into: edited) { return .failed(reason: refusal) }
        enqueue(edited, editedIn: session.lifecycle)
        return await settle(teamID: edited.id)
    }

    /// `team`, admitted by the check at its door — `stage`'s lifecycle guard or `commit`'s
    /// `refusal(toSave:into:)` — queued to replace the stored team of its id: latest wins per
    /// team, written in staging order by the one drain.
    private func enqueue(_ team: Team, editedIn lifecycle: WorkFolderLifecycle) {
        let id = team.id
        let revision = (stagedRevision[id] ?? 0) + 1
        stagedRevision[id] = revision
        // A value from a folder that is gone can never land: whoever waits on it hears so now,
        // not from the write that carries this folder's value.
        if let superseded = drafts[id], superseded.lifecycle != lifecycle {
            resolveWaiters(
                of: id, through: superseded.revision,
                with: .failed(reason: Self.folderChangedReason(teamName: superseded.team.name)))
        }
        let draft = Draft(team: team, lifecycle: lifecycle, revision: revision)
        drafts[id] = draft
        if let waiting = queued.firstIndex(where: { $0.team.id == id }) {
            queued[waiting] = draft
        } else {
            queued.append(draft)
        }
        guard drainTask == nil else { return }
        drainTask = Task { await self.drain() }
    }

    /// A Team Editor action that writes the folder itself rather than one team's content — New
    /// Team, Duplicate, Delete, Import, Restore Default Teams, a team picked in the selector:
    /// `write` awaited, and its refusal kept for the editor's banner, in the folder the action
    /// began in, until the next such action lands. Until 2026-11-08 these actions dropped the
    /// outcome, and a refusal was a banner in the main window behind Settings.
    @discardableResult
    func perform(
        editedIn lifecycle: WorkFolderLifecycle,
        _ write: () async -> WorkFolderMutationOutcome
    ) async -> WorkFolderMutationOutcome {
        let outcome = await write()
        if let reason = outcome.failureReason {
            actionFailure = Failure(reason: reason, lifecycle: lifecycle)
        } else if actionFailure != nil {
            actionFailure = nil
        }
        return outcome
    }

    /// A write from beside the queue — a Team Editor action, an Autovisor sync, an open's
    /// reconcile — landed in `teams.json`, replacing `before` with `after`. Every team whose failed
    /// write it replaced or removed now has a newer finished write than the one that failed, and its
    /// row goes: the team on disk is what the editor shows. A team it left as it was keeps its row.
    /// Compared encoded, not with `Team.==`, which looks at the id and `updatedAt` alone
    /// (CLAUDE.md #42) — a replacement that kept the timestamp is still a replacement.
    func teamsWereWritten(replacing before: [Team], with after: [Team], editedIn lifecycle: WorkFolderLifecycle) {
        guard !failures.isEmpty else { return }
        // Keyed by id, the FIRST team of an id winning — the one `first(where:)` finds, so the one
        // `Folder.storedTeam` shows the editor. Two teams of one id do reach here: nothing on the
        // write path refuses a duplicate a `mutateWorkFolder` closure appends (`addTeam` renames
        // at its own door only), and a `teams.json` edited by hand decodes as it is.
        let previousByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let writtenByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        for (teamID, failure) in failures where failure.lifecycle == lifecycle {
            guard let written = writtenByID[teamID] else {
                failures[teamID] = nil
                continue
            }
            if previousByID[teamID].flatMap({ try? encoder.encode($0) }) != (try? encoder.encode(written)) {
                failures[teamID] = nil
            }
        }
    }

    /// Waits until every value staged for `teamID` so far has been written, and answers with the
    /// outcome of the write that carried the newest. `.unchanged` when nothing was waiting.
    func settle(teamID: NTMSID) async -> WorkFolderMutationOutcome {
        guard let target = stagedRevision[teamID], target > (finishedRevision[teamID] ?? 0) else {
            return .unchanged
        }
        return await withCheckedContinuation { continuation in
            waiters[teamID, default: []].append(Waiter(revision: target, continuation: continuation))
        }
    }

    /// Waits until nothing is staged and nothing is owed — every value written, the reconcile those
    /// writes left owed run. What an action that rewrites teams wholesale does first, so a waiting
    /// edit cannot land over it afterwards (a value staged while it waited included), and what a
    /// test awaits before it reads what the writes caused.
    func settleAll() async {
        while true {
            if let teamID = drafts.keys.first {
                _ = await settle(teamID: teamID)
            } else if let reconcile = reconcileTask {
                await reconcile.value
            } else {
                break
            }
        }
    }

    // MARK: - Draining

    private func drain() async {
        while !queued.isEmpty {
            let draft = queued.removeFirst()
            let outcome: WorkFolderMutationOutcome
            if let folder {
                outcome = await folder.writeEditedTeam(draft.team, editedIn: draft.lifecycle)
            } else {
                outcome = .failed(reason: Self.notConnectedReason)
            }
            finish(draft, outcome: outcome)
        }
        drainTask = nil
    }

    private func finish(_ draft: Draft, outcome: WorkFolderMutationOutcome) {
        let teamID = draft.team.id
        finishedRevision[teamID] = max(finishedRevision[teamID] ?? 0, draft.revision)
        // Owed before any waiter resumes, so one that goes on to `settleAll` finds it.
        if outcome == .persisted { oweReconcile() }
        if let reason = outcome.failureReason {
            failures[teamID] = Failure(reason: reason, lifecycle: draft.lifecycle)
        } else if failures[teamID] != nil {
            failures[teamID] = nil
        }
        resolveWaiters(of: teamID, through: draft.revision, with: outcome)
        // Written, the value is the snapshot's; refused, the writer re-synced the snapshot from
        // disk and the editor must show that again. Either way the draft has served — unless a
        // newer one was staged while this one was being written.
        if drafts[teamID]?.revision == draft.revision {
            drafts[teamID] = nil
        }
    }

    private func resolveWaiters(
        of teamID: NTMSID, through revision: Int, with outcome: WorkFolderMutationOutcome
    ) {
        guard let pending = waiters[teamID] else { return }
        let due = pending.filter { $0.revision <= revision }
        let later = pending.filter { $0.revision > revision }
        waiters[teamID] = later.isEmpty ? nil : later
        for waiter in due {
            waiter.continuation.resume(returning: outcome)
        }
    }

    /// A write changed `teams.json`: the folder's reconcile is owed. One task runs it, beside the
    /// writes — a Save waits for its write, not for a model server's listing — and passes again
    /// while writes keep landing during a pass; `settleAll()` waits for it. Not detached: until
    /// 2026-11-08 the writer started a task per write that nothing could await, and deleting it
    /// left every test green.
    private func oweReconcile() {
        reconcileOwed = true
        guard reconcileTask == nil else { return }
        reconcileTask = Task {
            while self.reconcileOwed {
                self.reconcileOwed = false
                await self.folder?.reconcileAfterTeamWrites()
            }
            self.reconcileTask = nil
        }
    }

    /// No folder wired means no folder to compare against: the lifecycle is taken as current, and
    /// the drain refuses the write instead (`notConnectedReason`).
    private func isCurrent(_ lifecycle: WorkFolderLifecycle) -> Bool {
        folder?.isCurrentFolderLifecycle(lifecycle) ?? true
    }
}
