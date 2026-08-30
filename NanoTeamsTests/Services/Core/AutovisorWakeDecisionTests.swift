import XCTest
@testable import NanoTeams

/// Corner-case tests for the pure Autovisor wake predicate
/// (`NTMSOrchestrator.autovisorNeedsAttention`). EVERY case of
/// `AutovisorAttentionTrigger` is LEVEL-triggered (re-evaluated every tick; the caller's
/// deliver-once baseline bounds frequency) — stated as a property because this header read
/// "All four activation triggers" while there were five, and nothing noticed (#143).
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

    /// `waiting` is the DURABLE "someone is owed a Supervisor answer" fact
    /// (`TaskSummary.hasPendingSupervisorInput`), deliberately tri-state: `nil` is an
    /// index row written before the field existed, which is not the same as `false`.
    /// `gate` is the durable "a role is parked on an acceptance decision" fact
    /// (`TaskSummary.hasRolesAwaitingAcceptance`), tri-state for the same reason.
    private func sum(
        _ id: Int, _ status: TaskStatus, chat: Bool = false, waiting: Bool? = nil,
        gate: Bool? = nil
    ) -> TaskSummary {
        TaskSummary(id: id, title: "t\(id)", status: status, isChatMode: chat,
                    hasPendingSupervisorInput: waiting, hasRolesAwaitingAcceptance: gate)
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

    // MARK: - needsSupervisor reads the DURABLE fact, not only the engine mirror
    //
    // `taskEngineStates` is derived from step STATUS, and `StatusRecoveryService`
    // rewrites a parked step to `.paused` at launch while leaving the durable
    // `needsSupervisorInput` flag and the question intact — so the mirror says
    // "answered" for a task that is still waiting. `TaskSummary.isWaitingForSupervisor`
    // is the fact whose lifetime matches the question (CLAUDE.md #91).

    func testNeedsSupervisor_durableFlag_noEngineEntry_fires() {
        // The restart-recovered shape: the durable flag survives, the mirror does not
        // exist at all. With no engine entry the mirror arm cannot mask this.
        XCTAssertTrue(attn([sum(1, .paused, waiting: true)], engine: [:],
                           activation: act(needsSupervisor: true), seen: [1]),
                      "a task whose durable wait-fact is set must wake the manager even with no engine entry")
    }

    func testNeedsSupervisor_durableFlag_engineMirrorSaysPaused_fires() {
        // `syncEngineStateFromRun` seeds `.paused` from the recovered derived status.
        // Gating the durable arm on "no engine entry" would miss exactly this case.
        XCTAssertTrue(attn([sum(1, .paused, waiting: true)], engine: [1: .paused],
                           activation: act(needsSupervisor: true), seen: [1]),
                      "the seeded `.paused` mirror must not suppress the durable wait-fact")
    }

    func testNeedsSupervisor_askCallLandedButParkNotYet_doesNotFire() {
        // `hasActiveSupervisorInput` is `needsSupervisorInput || activeAskCall != nil`,
        // so the durable fact flips true when the `ask_supervisor` CALL is appended —
        // sub-second before `setNeedsSupervisorInput` writes the park. In that window
        // `answer_task_question` (which matches the STORED flag) would fail, so the
        // `.running` status vetoes the durable arm.
        XCTAssertFalse(attn([sum(1, .running, waiting: true)], engine: [1: .running],
                            activation: act(needsSupervisor: true), seen: [1]),
                       "a still-running step with an ask call but no park is not answerable yet")
    }

    func testNeedsSupervisor_legacyUnknownRow_fallsBackToEngineMirror() {
        // `hasPendingSupervisorInput == nil` is an index row older than the field. The
        // mirror is the only answer it can give, so the arm must remain a union.
        XCTAssertTrue(attn([sum(1, .paused, waiting: nil)], engine: [1: .needsSupervisorInput],
                           activation: act(needsSupervisor: true), seen: [1]),
                      "a legacy row with no durable fact must still fire via the engine mirror")
    }

    func testNeedsSupervisor_legacyUnknownRow_noEngineEntry_doesNotFire() {
        // `.unknown` must not be read as "waiting" — that would wake the manager for
        // every legacy row on the first launch after an upgrade.
        XCTAssertFalse(attn([sum(1, .paused, waiting: nil)], engine: [:],
                            activation: act(needsSupervisor: true), seen: [1]),
                       "unknown is not waiting — a legacy row with no mirror must stay quiet")
    }

    func testNeedsSupervisor_durableFalse_engineSaysWaiting_stillFires() {
        // The change is a pure WIDENING: the durable fact may only ADD wakes, never
        // veto one the engine mirror already establishes.
        XCTAssertTrue(attn([sum(1, .running, waiting: false)], engine: [1: .needsSupervisorInput],
                           activation: act(needsSupervisor: true), seen: [1]),
                      "a live parked engine must fire regardless of the durable fact")
    }

    func testNeedsSupervisor_durableFlag_off_noFire() {
        // The activation toggle still gates the durable arm, not just the mirror one.
        XCTAssertFalse(attn([sum(1, .paused, waiting: true)], engine: [:],
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
        // Neither trigger reads the engine MIRROR. The mirror and the row have different
        // lifetimes (CLAUDE.md #91): after a relaunch `mapDerivedStatusToEngineState` seeds
        // `.paused` for a task whose row still records the gate, and a torn-down engine can
        // leave a stale entry behind — so a wake keyed on it would fire for conditions that
        // no longer exist and never for ones that do. Mid-pipeline gates ARE now seen, via
        // the durable row fact instead; `testAcceptanceGate_*` below is the control pair.
        XCTAssertFalse(attn([sum(1, .running)], engine: [1: .needsAcceptance],
                            activation: act(needsSupervisor: true, completed: true), seen: [1]))
    }

    // MARK: - mid-pipeline acceptance gate (durable fact, never the engine mirror)

    func testAcceptanceGate_firesWhileTheTaskStillDerivesRunning() {
        // The stall this trigger exists for: with the default `.afterEachRole` mode a role
        // finishes, the run loop transitions to `.needsAcceptance` and RETURNS, but the
        // downstream roles are still `.ready`, so the task derives `.running` and NO
        // status-based trigger can see it. The pipeline is parked and nothing wakes.
        let got = items([sum(1, .running, gate: true)], activation: act(completed: true), seen: [1])
        XCTAssertEqual(got.map(\.trigger), [.acceptanceGate])
    }

    func testAcceptanceGate_legacyRowUnknown_doesNotFire() {
        // Tri-state: `nil` is "this row predates the field", not "no gate". Reading unknown
        // as yes would wake the manager for a condition the row cannot prove.
        XCTAssertFalse(attn([sum(1, .running, gate: nil)], activation: act(completed: true), seen: [1]))
    }

    func testAcceptanceGate_atReview_emitsOnlyCompleted() {
        // Disjoint by construction: at Review a gated role exists too, so without the
        // `status != .needsSupervisorAcceptance` qualifier one condition would emit two keys
        // and the manager would get two bullets naming the same thing.
        let got = items([sum(1, .needsSupervisorAcceptance, gate: true)],
                        activation: act(completed: true), seen: [1])
        XCTAssertEqual(got.map(\.trigger), [.completed])
    }

    func testAcceptanceGate_chatMode_doesNotFire() {
        // Checked per member, not inherited: a chat-mode run loop never parks on the
        // acceptance gate at all, so the failure this trigger names cannot occur there.
        XCTAssertFalse(attn([sum(1, .running, chat: true, gate: true)],
                            activation: act(completed: true), seen: [1]))
    }

    func testAcceptanceGate_sharesTheCompletionFlag() {
        // One toggle, two conditions — turning "wake for a review decision" off must silence
        // BOTH, or the setting lies about what it controls.
        XCTAssertFalse(attn([sum(1, .running, gate: true)], activation: act(completed: false), seen: [1]))
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

    /// The composer must emit the SHARED header constant, not a private literal.
    ///
    /// Two other places depend on that exact line: the notice ships unmarked, so it is what
    /// identifies the turn once a provider flattens consecutive user messages, and
    /// `SystemNoticePresentation` skips it when building the collapsed row's preview. A
    /// literal here that drifted from the constant would leave the row showing the banner it
    /// was supposed to hide, with nothing red anywhere.
    ///
    /// The constant's own text is pinned against a literal in `LLMMessageSourceContextTests`,
    /// so this pair is anchored rather than self-referential.
    func testCompose_headerIsTheSharedConstant() {
        let notice = NTMSOrchestrator.composeAutovisorEventNotice(
            [.init(taskID: 1, title: "A", trigger: .failed)])
        XCTAssertTrue(notice.hasPrefix(MessageSourceContext.autovisorEventNoticeHeader + "\n"))
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

    // MARK: - taskHasPendingHumanAnswer (Part A race-fix predicate)
    //
    // Guards the supersede paths: a parked manager whose latest step already
    // carries an unprocessed HUMAN answer must NOT be superseded (it would
    // `createNewRun` and orphan the answer). The idle park clears
    // `supervisorAnswer`, so a non-nil non-auto answer is unambiguous.

    private func taskWithLatestStep(_ step: StepExecution, priorRuns: [Run] = []) -> NTMSTask {
        NTMSTask(
            id: 1, title: "Manager", supervisorTask: "oversee",
            runs: priorRuns + [Run(id: priorRuns.count, steps: [step])]
        )
    }

    func testPendingHumanAnswer_humanAnswerOnLatestStep_true() {
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr", status: .pending,
                                 supervisorAnswer: "qwen3.5 default", supervisorAnswerWasAuto: false)
        XCTAssertTrue(NTMSOrchestrator.taskHasPendingHumanAnswer(taskWithLatestStep(step)))
    }

    func testPendingHumanAnswer_noAnswer_false() {
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr",
                                 status: .needsSupervisorInput, needsSupervisorInput: true,
                                 supervisorQuestion: AutovisorConstants.idleParkQuestion)
        XCTAssertFalse(NTMSOrchestrator.taskHasPendingHumanAnswer(taskWithLatestStep(step)))
    }

    func testPendingHumanAnswer_autoAnswer_false() {
        // An automated answer (the Autovisor / a delegating parent) must not block a
        // supersede — only genuine human input does.
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr", status: .pending,
                                 supervisorAnswer: "auto", supervisorAnswerWasAuto: true)
        XCTAssertFalse(NTMSOrchestrator.taskHasPendingHumanAnswer(taskWithLatestStep(step)))
    }

    func testPendingHumanAnswer_answerOnlyOnPriorRun_false() {
        // Only the LATEST run is state; a prior run's answer is history.
        let prior = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr", status: .pending,
                                  supervisorAnswer: "old human", supervisorAnswerWasAuto: false)
        let latest = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr",
                                   status: .needsSupervisorInput, needsSupervisorInput: true,
                                   supervisorQuestion: AutovisorConstants.idleParkQuestion)
        let task = taskWithLatestStep(latest, priorRuns: [Run(id: 0, steps: [prior])])
        XCTAssertFalse(NTMSOrchestrator.taskHasPendingHumanAnswer(task))
    }

    func testPendingHumanAnswer_nilTask_false() {
        XCTAssertFalse(NTMSOrchestrator.taskHasPendingHumanAnswer(nil))
    }

    func testPendingHumanAnswer_attachmentOnlyAnswer_true() {
        // Empty text + attachments: raw `supervisorAnswer` is nil but
        // `effectiveSupervisorAnswer` is non-nil. The predicate must use the latter
        // (matching the `resumeRun` branch that consumes it) so an attachment-only
        // human answer is still protected from a racing supersede.
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "Mgr", status: .pending,
                                 supervisorAnswer: nil,
                                 supervisorAnswerAttachmentPaths: ["a.pdf"],
                                 supervisorAnswerWasAuto: false)
        XCTAssertTrue(NTMSOrchestrator.taskHasPendingHumanAnswer(taskWithLatestStep(step)))
    }

    // MARK: - taskHasPendingHumanAnswer corner cases

    func testPendingHumanAnswer_noRuns_false() {
        // A task with no runs yet (`runs.last` is nil) must not crash and returns false.
        let task = NTMSTask(id: 1, title: "Manager", supervisorTask: "oversee", runs: [])
        XCTAssertFalse(NTMSOrchestrator.taskHasPendingHumanAnswer(task))
    }

    func testPendingHumanAnswer_latestRunHasNoSteps_false() {
        // `runs.last` exists but is empty — `.contains` over an empty step list is false.
        let task = NTMSTask(id: 1, title: "Manager", supervisorTask: "oversee",
                            runs: [Run(id: 0, steps: [])])
        XCTAssertFalse(NTMSOrchestrator.taskHasPendingHumanAnswer(task))
    }

    func testPendingHumanAnswer_answerOnNonFirstStepOfLatestRun_true() {
        // The predicate scans ALL steps of the latest run (`.contains`), not just the
        // first — a human answer on any step counts.
        let plain = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done)
        let answered = StepExecution(id: "b", role: .codeReviewer, title: "B", status: .pending,
                                     supervisorAnswer: "human reply", supervisorAnswerWasAuto: false)
        let task = NTMSTask(id: 1, title: "Manager", supervisorTask: "oversee",
                            runs: [Run(id: 0, steps: [plain, answered])])
        XCTAssertTrue(NTMSOrchestrator.taskHasPendingHumanAnswer(task))
    }
}
