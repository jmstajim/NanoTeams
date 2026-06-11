import XCTest
@testable import NanoTeams

/// Corner-case tests for the pure Autovisor wake predicate
/// (`NTMSOrchestrator.autovisorNeedsAttention`). All four activation triggers are
/// LEVEL-triggered (re-evaluated every tick; the caller's debounce bounds frequency).
///
/// Key contract pinned here: the completion trigger keys on the DERIVED `.needsSupervisorAcceptance`
/// ("Review") status, NOT `.done`. A finished task derives to Review until the manager closes it;
/// `.done` only happens AFTER close. Matching `.done` (the old bug) both missed the review AND
/// looped forever on every already-closed task — these tests forbid both.
///
/// The predicate is pure (no engine, no orchestrator state) so it is driven with hand-built
/// `TaskSummary` values, an `engineStates` dict, and a `seen` set.
final class AutovisorWakeDecisionTests: XCTestCase {

    // MARK: - Helpers

    private func sum(_ id: Int, _ status: TaskStatus, chat: Bool = false) -> TaskSummary {
        TaskSummary(id: id, title: "t\(id)", status: status, isChatMode: chat)
    }

    private func act(
        needsSupervisor: Bool = false,
        failed: Bool = false,
        completed: Bool = false,
        created: Bool = false,
        stuck: Bool = false
    ) -> AutovisorActivation {
        AutovisorActivation(
            onTaskNeedsSupervisor: needsSupervisor,
            onTaskFailed: failed,
            onTaskCompleted: completed,
            onTaskCreated: created,
            onTaskStuck: stuck
        )
    }

    private func attn(
        _ watchable: [TaskSummary],
        engine: [Int: TeamEngineState] = [:],
        activation: AutovisorActivation,
        seen: Set<Int> = [],
        stuck: Set<Int> = []
    ) -> Bool {
        NTMSOrchestrator.autovisorNeedsAttention(
            watchable: watchable, engineStates: engine, activation: activation, seen: seen, stuck: stuck
        )
    }

    // MARK: - Bug 1: completion fires on Review, never on Done

    func testCompletion_firesOnReview() {
        XCTAssertTrue(attn([sum(1, .needsSupervisorAcceptance)], activation: act(completed: true), seen: [1]),
                      "a task awaiting acceptance (Review) must wake the manager")
    }

    func testCompletion_doesNotFireOnDone() {
        // The old `.done` match never fired for the real review AND looped forever on closed
        // tasks (they persist in tasksIndex). The new check must ignore `.done` entirely.
        XCTAssertFalse(attn([sum(1, .done)], activation: act(completed: true), seen: [1]),
                       "a closed (.done) task must NOT wake the manager — no close-loop")
    }

    func testCompletion_off_reviewTask_noFire() {
        // Every other trigger ON; with onTaskCompleted OFF a Review task must stay quiet.
        XCTAssertFalse(attn([sum(1, .needsSupervisorAcceptance)],
                            activation: act(needsSupervisor: true, failed: true, completed: false, created: true),
                            seen: [1]))
    }

    // MARK: - failed

    func testFailed_firesOnFailed() {
        XCTAssertTrue(attn([sum(1, .failed)], activation: act(failed: true), seen: [1]))
    }

    func testFailed_off_noFire() {
        XCTAssertFalse(attn([sum(1, .failed)], activation: act(completed: true), seen: [1]))
    }

    // MARK: - created (Bug 2 at the predicate level)

    func testCreated_unseen_fires() {
        XCTAssertTrue(attn([sum(1, .running)], activation: act(created: true), seen: []),
                      "an unseen top-level task wakes the manager when onTaskCreated is on")
    }

    func testCreated_seen_noFire() {
        XCTAssertFalse(attn([sum(1, .running)], activation: act(created: true), seen: [1]),
                       "a seen task (e.g. one the manager created) must not self-trigger onTaskCreated")
    }

    // MARK: - stuck (poll-only trigger; ids supplied by computeStuckTaskIDs)

    func testStuck_inSet_fires() {
        XCTAssertTrue(attn([sum(1, .running)], activation: act(stuck: true), seen: [1], stuck: [1]),
                      "a running task the poll flagged stuck wakes the manager when onTaskStuck is on")
    }

    func testStuck_off_noFire() {
        XCTAssertFalse(attn([sum(1, .running)], activation: act(stuck: false), seen: [1], stuck: [1]),
                       "onTaskStuck off → a flagged-stuck task must not wake")
    }

    func testStuck_emptySet_noFire() {
        // The observer path passes stuck:[] (default) — onTaskStuck on must then stay quiet.
        XCTAssertFalse(attn([sum(1, .running)], activation: act(stuck: true), seen: [1]),
                       "no stuck ids supplied (observer path) → no stuck wake")
    }

    func testStuck_independentOfSeen() {
        // `seen` gates only onTaskCreated; a seen, stuck task must still fire onTaskStuck.
        XCTAssertTrue(attn([sum(1, .running)], activation: act(created: true, stuck: true), seen: [1], stuck: [1]))
    }

    // MARK: - needsSupervisor reads engine state, not summary.status

    func testNeedsSupervisor_viaEngineState_fires() {
        XCTAssertTrue(attn([sum(1, .running)], engine: [1: .needsSupervisorInput],
                           activation: act(needsSupervisor: true), seen: [1]))
    }

    func testNeedsSupervisor_off_noFire() {
        XCTAssertFalse(attn([sum(1, .running)], engine: [1: .needsSupervisorInput],
                            activation: act(failed: true, completed: true), seen: [1]))
    }

    // MARK: - the two dedup inputs are independent

    func testSeenMembership_doesNotSuppressFailed() {
        // A seen task (so onTaskCreated cannot fire) must STILL fire onTaskFailed — `seen`
        // must never short-circuit a status-based trigger.
        XCTAssertTrue(attn([sum(1, .failed)], activation: act(failed: true, created: true), seen: [1]))
    }

    func testSeenMembership_doesNotSuppressCompletion() {
        XCTAssertTrue(attn([sum(1, .needsSupervisorAcceptance)],
                           activation: act(completed: true, created: true), seen: [1]))
    }

    func testSeenMembership_doesNotSuppressNeedsSupervisor() {
        // The supervisor trigger reads engine state and ignores `seen` entirely.
        XCTAssertTrue(attn([sum(1, .running)], engine: [1: .needsSupervisorInput],
                           activation: act(needsSupervisor: true, created: true), seen: [1]))
    }

    // MARK: - non-triggering statuses

    func testPausedAndWaiting_neverTrigger() {
        // `.paused` and `.waiting` match no trigger (only `.failed`/`.needsSupervisorAcceptance`
        // are settled; engine state isn't needsSupervisorInput; both are seen).
        let w = [sum(1, .paused), sum(2, .waiting)]
        XCTAssertFalse(attn(w, activation: act(needsSupervisor: true, failed: true, completed: true, created: true),
                            seen: [1, 2]))
    }

    // MARK: - level-triggered: the predicate has no memory

    func testSettledTask_levelTriggered_staysTrueAcrossRepeatedCalls() {
        // No edge-dedup: a task that stays settled keeps returning true on every call (the
        // caller's debounce — not the predicate — bounds wake frequency). Re-introducing a
        // `handled`-style dedup would break this. Covers both settled statuses.
        let review = [sum(1, .needsSupervisorAcceptance)]
        let failed = [sum(2, .failed)]
        let a = act(failed: true, completed: true)
        for _ in 0..<3 {
            XCTAssertTrue(attn(review, activation: a, seen: [1]))
            XCTAssertTrue(attn(failed, activation: a, seen: [2]))
        }
    }

    // MARK: - chat-mode tasks never reach a settled status

    func testChatModeRunning_neverCompletes() {
        // A finished chat-mode task derives to `.running` (never `.done`/`.needsSupervisorAcceptance`),
        // so it must match neither completed nor failed — else it would loop forever.
        XCTAssertFalse(attn([sum(1, .running, chat: true)],
                            activation: act(failed: true, completed: true), seen: [1]))
    }

    // MARK: - engine/derived divergence

    func testEngineNeedsAcceptance_summaryRunning_completionDoesNotFire() {
        // Completion keys on the DERIVED summary.status, not the live engine `.needsAcceptance`
        // (a closed task can leave a stale engine `.needsAcceptance` → matching it would loop).
        XCTAssertFalse(attn([sum(1, .running)], engine: [1: .needsAcceptance],
                            activation: act(needsSupervisor: true, completed: true), seen: [1]))
    }

    // MARK: - empties / no-match

    func testEmptyWatchable_false() {
        XCTAssertFalse(attn([], activation: act(needsSupervisor: true, failed: true, completed: true, created: true),
                            seen: [7, 8]))
    }

    func testRunningTask_noTriggers_false() {
        // A plain running, seen task with no needsSupervisorInput engine state matches nothing.
        XCTAssertFalse(attn([sum(1, .running)],
                            activation: act(needsSupervisor: true, failed: true, completed: true, created: true),
                            seen: [1]))
    }

    // MARK: - mixed multi-task / multi-trigger

    func testMixed_multiTrigger_true() {
        let w = [sum(1, .failed), sum(2, .needsSupervisorAcceptance), sum(3, .running), sum(4, .done)]
        XCTAssertTrue(attn(w, engine: [3: .needsSupervisorInput],
                           activation: act(needsSupervisor: true, failed: true, completed: true, created: true),
                           seen: [1, 2, 3, 4]),
                      "failed #1, review #2, and needsSupervisorInput #3 each independently wake")
    }

    func testMixed_allQuiet_false() {
        // .done (closed), running+seen, paused+seen — every trigger is on but nothing matches.
        let w = [sum(1, .done), sum(2, .running), sum(3, .paused)]
        XCTAssertFalse(attn(w, activation: act(needsSupervisor: true, failed: true, completed: true, created: true),
                            seen: [1, 2, 3]))
    }

    // MARK: - itemized form (mid-review injection source)

    private func items(
        _ watchable: [TaskSummary],
        engine: [Int: TeamEngineState] = [:],
        activation: AutovisorActivation,
        seen: Set<Int> = [],
        stuck: Set<Int> = []
    ) -> [NTMSOrchestrator.AutovisorAttentionItem] {
        NTMSOrchestrator.autovisorAttentionItems(
            watchable: watchable, engineStates: engine, activation: activation, seen: seen, stuck: stuck
        )
    }

    func testItems_oneItemPerMatchingTrigger() {
        // Task 1 matches BOTH failed and created → two items with distinct keys.
        let result = items([sum(1, .failed)], activation: act(failed: true, created: true))
        XCTAssertEqual(result.count, 2, "a task matching several triggers emits one item per trigger")
        XCTAssertEqual(Set(result.map(\.trigger)), [.failed, .created])
        XCTAssertEqual(Set(result.map(\.key)).count, 2, "dedup keys are per (task, trigger)")
    }

    func testItems_carriesTitle_keyIgnoresIt() {
        let result = items([sum(7, .failed)], activation: act(failed: true))
        XCTAssertEqual(result.first?.title, "t7")
        XCTAssertEqual(result.first?.key,
                       NTMSOrchestrator.AutovisorAttentionKey(taskID: 7, trigger: .failed),
                       "the key is (taskID, trigger) — a rename must not re-notify")
    }

    func testItems_boolWrapperAgreesWithEmptiness() {
        let activation = act(needsSupervisor: true, failed: true, completed: true, created: true, stuck: true)
        let quiet = [sum(1, .done), sum(2, .running)]
        XCTAssertEqual(attn(quiet, activation: activation, seen: [1, 2]),
                       !items(quiet, activation: activation, seen: [1, 2]).isEmpty)
        let loud = [sum(3, .failed)]
        XCTAssertEqual(attn(loud, activation: activation, seen: [3]),
                       !items(loud, activation: activation, seen: [3]).isEmpty)
        XCTAssertTrue(attn(loud, activation: activation, seen: [3]))
    }

    func testItems_emptyWatchable_returnsEmpty() {
        // A non-empty stuck set with nothing watchable must not synthesize items.
        let result = items([],
                           activation: act(needsSupervisor: true, failed: true, completed: true,
                                           created: true, stuck: true),
                           stuck: [1])
        XCTAssertTrue(result.isEmpty)
    }

    func testItems_allTriggersDisabled_returnsEmpty() {
        // Every condition is "hot" (failed status, live needsSupervisorInput engine,
        // unseen, in the stuck set) but every toggle is off — nothing may match.
        let result = items([sum(1, .failed)], engine: [1: .needsSupervisorInput],
                           activation: act(), stuck: [1])
        XCTAssertTrue(result.isEmpty)
    }

    func testItems_simultaneousTriggers_fixedEvaluationOrder() {
        // One task matching every co-satisfiable trigger at once. `failed` and
        // `completed` are mutually exclusive by construction (both read the single
        // `status` value), so the maximum is four. Order is the declared evaluation
        // sequence — deterministic notice text and stable tests depend on it.
        let result = items([sum(1, .failed)],
                           engine: [1: .needsSupervisorInput],
                           activation: act(needsSupervisor: true, failed: true, completed: true,
                                           created: true, stuck: true),
                           stuck: [1])
        XCTAssertEqual(result.map(\.trigger), [.needsSupervisor, .failed, .created, .stuck])
        XCTAssertEqual(Set(result.map(\.key)).count, 4, "four distinct per-condition dedup keys")
    }

    func testItems_stuckIDOutsideWatchable_noItem() {
        // The stuck set is matched against watchable membership — a stale id from a
        // deleted/child task must not produce a phantom item.
        let result = items([sum(1, .running)], activation: act(stuck: true), seen: [1], stuck: [99])
        XCTAssertTrue(result.isEmpty)
    }

    func testItems_orderFollowsWatchableOrder() {
        let result = items([sum(2, .failed), sum(1, .failed)], activation: act(failed: true))
        XCTAssertEqual(result.map(\.taskID), [2, 1],
                       "items preserve watchable order — notice bullets stay deterministic")
    }

    // MARK: - event-notice composer

    func testCompose_phrasingPerTrigger() {
        func bullet(_ trigger: NTMSOrchestrator.AutovisorAttentionTrigger) -> String {
            NTMSOrchestrator.composeAutovisorEventNotice(
                [.init(taskID: 5, title: "X", trigger: trigger)]
            )
        }
        XCTAssertTrue(bullet(.needsSupervisor).contains("answer_task_question"))
        XCTAssertTrue(bullet(.failed).contains("failed"))
        XCTAssertTrue(bullet(.completed).contains("control_task close"))
        XCTAssertTrue(bullet(.created).contains("New task"))
        XCTAssertTrue(bullet(.stuck).contains("stuck"))
    }

    func testCompose_multiItem_headerPlusOneBulletEach() {
        let notice = NTMSOrchestrator.composeAutovisorEventNotice([
            .init(taskID: 1, title: "A", trigger: .failed),
            .init(taskID: 2, title: "B", trigger: .completed),
        ])
        let lines = notice.split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "header + one bullet per item")
        XCTAssertTrue(lines[0].contains("new since this pass started"))
        XCTAssertTrue(lines[1].contains("Task #1 \"A\""))
        XCTAssertTrue(lines[2].contains("Task #2 \"B\""))
    }

    func testCompose_emptyItems_headerOnly() {
        // Production guards `!fresh.isEmpty` before composing — this pins the
        // degenerate shape so a future caller without that guard produces a
        // harmless header rather than crashing or emitting an empty payload
        // (an empty text would fail QueuedChatMessage's failable init).
        let notice = NTMSOrchestrator.composeAutovisorEventNotice([])
        XCTAssertEqual(notice.split(separator: "\n").count, 1)
        XCTAssertFalse(notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testCompose_emptyTitle_stillNamesTask() {
        // Auto-derived titles can't be empty and rename paths reject empty input,
        // but a whitespace-only UI rename gets through (confirmRename doesn't trim) —
        // the bullet must still carry the actionable task id.
        let notice = NTMSOrchestrator.composeAutovisorEventNotice(
            [.init(taskID: 12, title: "", trigger: .failed)]
        )
        XCTAssertTrue(notice.contains("Task #12"))
    }
}
