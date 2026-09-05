import XCTest

@testable import NanoTeams

/// Event-driven retirement of Watchtower dismissals — the half the sampling GC
/// cannot do. `WatchtowerInboxBuilder.staleDismissals` only expires a key whose
/// banner is ABSENT while its task is loaded, so a dismissal that survives into
/// the NEXT instance of the same banner (the same step failing again after a
/// restart, a second acceptance round after a revision) would suppress a banner
/// nobody has read. The orchestrator therefore retires keys at the transitions
/// that CONSUME the state a banner reported.
///
/// Pinned twice per CLAUDE.md #58: the helper directly, and through real callers
/// (`closeTask`, `resumeRun`'s failed-revive, `answerSupervisorQuestion`).
///
/// The `.supervisorInput` family retires on its ANSWER. The premise, stated precisely:
/// those dismissals are not "never retired" — the sampling GC reclaims one whenever the
/// task is loaded and the banner absent at a refresh (or the task is gone from the index).
/// The defect is the gap that rule leaves: a flag-only escalation is keyed on its TEXT, so
/// a key that outlives its answer is born-dismissing the next same-text escalation — and by
/// then the key is ACTIVE again, which the GC reads as "keep"; and the GC samples only from
/// `WatchtowerView.refreshNotifications`, which is not mounted while a task's chat is on
/// screen — so a chat session strands one read-dismissed UUID key per answered turn until
/// the Watchtower is next shown with the task still resident.
@MainActor
final class WatchtowerDismissRetirementTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func folderID() -> UUID { sut.snapshot!.projection.id }

    /// Plants a task whose run holds `steps`, every non-failed role `.working` — the
    /// shape a waiting step sits in while the Supervisor is typing.
    private func makeWaitingTask(steps: [StepExecution]) async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "goal")!
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: steps)
            for step in steps {
                run.roleStatuses[step.id] = step.status == .failed ? .failed : .working
            }
            task.runs = [run]
        }
        return taskID
    }

    private func callKeyedWaitingStep(id: String, question: String) -> StepExecution {
        StepExecution(
            id: id, role: .softwareEngineer, title: "W", status: .needsSupervisorInput,
            toolCalls: [StepToolCall(name: ToolNames.askSupervisor, argumentsJSON: "{\"question\":\"\(question)\"}")],
            needsSupervisorInput: true, supervisorQuestion: question)
    }

    private func flagOnlyWaitingStep(id: String, question: String) -> StepExecution {
        StepExecution(
            id: id, role: .softwareEngineer, title: "W", status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: question)
    }

    /// The key exactly the way the VIEW computes it — through the inbox builder, not a
    /// hand-spelled literal — so the test cannot pass on a spelling the banner never used.
    private func bannerKeys(taskID: Int) -> [String: WatchtowerDismissKey] {
        let all = WatchtowerInboxBuilder.build([.init(task: sut.loadedTask(taskID)!, teamRoles: [])])
        var byStep: [String: WatchtowerDismissKey] = [:]
        for notification in all {
            if case .supervisorInput(let stepID, _, _, _) = notification.type {
                byStep[stepID] = notification.dismissKey
            }
        }
        return byStep
    }

    /// Plants a task whose only step is `.failed` (role reconciled `.failed` too),
    /// the shape `resumeRun`'s revive loop looks for.
    private func makeFailedTask() async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "goal")!
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0)
            var step = StepExecution(
                id: "worker", role: .softwareEngineer, title: "Work", status: .failed)
            step.completedAt = MonotonicClock.shared.now()
            run.steps = [step]
            run.roleStatuses = ["worker": .failed]
            task.runs = [run]
        }
        return taskID
    }

    // MARK: - The helper, directly

    func testRetire_dropsBothFamilies_leavesOtherKeysAlone() async {
        let taskID = await makeFailedTask()
        let fid = folderID()
        let failedKey = WatchtowerDismissKey.failed(taskID: taskID, stepID: "worker")
        let acceptanceKey = WatchtowerDismissKey.acceptance(taskID: taskID, stepID: "worker")
        let questionKey = WatchtowerDismissKey(taskID: taskID, typeID: "worker::\(UUID().uuidString)")
        for key in [failedKey, acceptanceKey, questionKey] {
            sut.configuration.dismissNotification(workFolderID: fid, key: key)
        }

        sut.retireRoleBannerDismissals(taskID: taskID, roleIDs: ["worker"])

        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: failedKey))
        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: acceptanceKey))
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: questionKey),
                      "a supervisor-question dismissal has per-call identity and is not this helper's business")
    }

    // MARK: - Through resumeRun's failed-revive

    /// The user retries a failed run: the failure the dismissed banner reported is
    /// being re-attempted, so a NEW failure must produce a visible banner again.
    func testResumeRun_failedRevive_retiresTheFailedDismissal() async {
        let taskID = await makeFailedTask()
        let fid = folderID()
        let failedKey = WatchtowerDismissKey.failed(taskID: taskID, stepID: "worker")
        sut.configuration.dismissNotification(workFolderID: fid, key: failedKey)

        await sut.resumeRun(taskID: taskID)

        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: failedKey),
                       "reviving the failed step must retire its banner's dismissal")
    }

    // MARK: - Through closeTask

    func testCloseTask_forgetsEveryDismissalOfThatTaskOnly() async {
        let taskID = await makeFailedTask()
        let otherID = await sut.createTask(title: "Other", supervisorTask: "x")!
        let fid = folderID()
        let mine = WatchtowerDismissKey.failed(taskID: taskID, stepID: "worker")
        let other = WatchtowerDismissKey.failed(taskID: otherID, stepID: "worker")
        sut.configuration.dismissNotification(workFolderID: fid, key: mine)
        sut.configuration.dismissNotification(workFolderID: fid, key: other)

        let closed = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(closed)
        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: mine),
                       "a closed task produces no banners, so its dismissals are garbage")
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: other),
                      "closing one task must not touch a sibling's dismissals")
    }

    // MARK: - Through answerSupervisorQuestion (the question family)

    /// Chat mode: every turn is an `ask_supervisor` call, the key carries its UUID, and
    /// `MainLayoutView` read-dismisses each question as it arrives in the open chat — the
    /// Watchtower's GC is not mounted while the chat is, so without this retirement those
    /// keys accumulate one per answered turn until the Watchtower is next shown. Through
    /// the real caller the retirement is exactly ONE counted write (CLAUDE.md #58 — the
    /// helper's own count is pinned in `StoreConfigurationDismissScopeTests`).
    ///
    /// RED: delete the `retireSupervisorInputDismissal(key:)` call in
    /// `answerSupervisorQuestion` → the dismissal survives the answer.
    /// RED: move the `answeredBannerKey =` capture BELOW the `StepMessagingService` call
    /// inside the closure → post-answer the active call is nil ⇒ key nil ⇒ nothing retired.
    func testAnswer_retiresTheAnsweredQuestionDismissal_callKeyed() async {
        let taskID = await makeWaitingTask(steps: [callKeyedWaitingStep(id: "worker", question: "Q?")])
        let fid = folderID()
        let key = bannerKeys(taskID: taskID)["worker"]!
        XCTAssertTrue(key.typeID.hasPrefix("worker::"), "fixture: a call-keyed banner")
        XCTAssertNotEqual(key.typeID, "worker::Q?", "fixture: keyed on the call's UUID, not the text")
        sut.configuration.dismissNotification(workFolderID: fid, key: key)
        DismissalStoreProbe._testReset()

        let answered = await sut.answerSupervisorQuestion(stepID: "worker", taskID: taskID, answer: "go")

        XCTAssertTrue(answered)
        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: key),
                       "the answer consumed the banner; its dismissal must go with it")
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 1,
                       "one retired key ⇒ exactly one re-serialisation of the set")
    }

    /// The gap the sampling GC cannot close: a flag-only escalation is keyed on its
    /// TEXT, so the dismissal of round N is the dismissal of every later same-text round
    /// — and by the time a refresh could notice, the key is active again and reads as
    /// "keep". Retiring it at the answer is what lets the next escalation show.
    ///
    /// RED: in `activeSupervisorInputDismissKey` add
    /// `guard activeSupervisorQuestionID != nil else { return nil }` (retire call-keyed
    /// identities only) → the text key survives, the second banner is masked,
    /// `visible.count == 0`; the call-keyed test above stays green.
    func testAnswer_retiresFlagOnlyEscalationDismissal_soTheNextSameTextQuestionShows() async {
        let taskID = await makeWaitingTask(steps: [flagOnlyWaitingStep(id: "worker", question: "Continue?")])
        let fid = folderID()
        let key = bannerKeys(taskID: taskID)["worker"]!
        XCTAssertEqual(key.typeID, "worker::Continue?", "fixture: text-keyed, no call to name")
        sut.configuration.dismissNotification(workFolderID: fid, key: key)

        let answered = await sut.answerSupervisorQuestion(stepID: "worker", taskID: taskID, answer: "yes")
        XCTAssertTrue(answered)
        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: key))

        // The next escalation with identical text — the writes `setNeedsSupervisorInput` makes.
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].needsSupervisorInput = true
            task.runs[0].steps[0].supervisorQuestion = "Continue?"
            task.runs[0].steps[0].supervisorAnswer = nil
            task.runs[0].steps[0].status = .needsSupervisorInput
        }
        let all = WatchtowerInboxBuilder.build([.init(task: sut.loadedTask(taskID)!, teamRoles: [])])
        XCTAssertEqual(all.first?.dismissKey, key,
                       "same key by construction — which is why retirement, not identity, is the fix")
        XCTAssertEqual(
            WatchtowerInboxBuilder.visible(all, dismissed: sut.configuration.dismissedKeys(forWorkFolder: fid)).count,
            1, "the next same-text escalation must be visible")
    }

    /// Parallel roles (CLAUDE.md #45): the retirement names exactly ONE key — the answered
    /// step's banner — and leaves the task's other dismissals alone, including a sibling's
    /// still-open question and a `failed::` key of a third step.
    ///
    /// RED: replace the retirement with
    /// `configuration.forgetDismissals(workFolderID:taskID:)` → B's and C's keys vanish.
    func testAnswer_leavesEveryOtherDismissalOfTheTaskAlone() async {
        var failed = StepExecution(id: "c", role: .softwareEngineer, title: "C", status: .failed)
        failed.completedAt = MonotonicClock.shared.now()
        let taskID = await makeWaitingTask(steps: [
            callKeyedWaitingStep(id: "a", question: "A?"),
            flagOnlyWaitingStep(id: "b", question: "B?"),
            failed,
        ])
        let fid = folderID()
        let keys = bannerKeys(taskID: taskID)
        let keyA = keys["a"]!, keyB = keys["b"]!
        let keyC = WatchtowerDismissKey.failed(taskID: taskID, stepID: "c")
        for key in [keyA, keyB, keyC] {
            sut.configuration.dismissNotification(workFolderID: fid, key: key)
        }

        let answered = await sut.answerSupervisorQuestion(stepID: "a", taskID: taskID, answer: "yes")
        XCTAssertTrue(answered)

        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: keyA), "A was answered")
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: keyB),
                      "B is still waiting — its dismissal is not this answer's business")
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: keyC),
                      "C's failed banner is another family's key")
        sut.retireRoleBannerDismissals(taskID: taskID, roleIDs: ["b"])
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: keyB),
                      "and the role helper keeps ignoring question keys")
    }

    /// Cost, through the real caller (CLAUDE.md #58 — the guard is pinned directly in
    /// `StoreConfigurationDismissScopeTests`): the common answer never had a dismissed
    /// banner, and retiring an ABSENT key must not re-serialise the whole set to
    /// UserDefaults. Work counter, never wall-clock.
    ///
    /// RED: delete the `guard dismissedNotificationKeys.contains(entry)` in
    /// `StoreConfiguration.undismissNotification` → `Set.remove` of a non-member still fires
    /// `didSet`, `_testWrites() == 1`.
    func testAnswer_withNoDismissedBanner_costsZeroPersistenceWrites() async {
        let taskID = await makeWaitingTask(steps: [callKeyedWaitingStep(id: "worker", question: "Q?")])
        let fid = folderID()
        let planted = WatchtowerDismissKey.failed(taskID: taskID, stepID: "other")
        DismissalStoreProbe._testReset()
        sut.configuration.dismissNotification(workFolderID: fid, key: planted)
        XCTAssertEqual(DismissalStoreProbe._testWrites(), 1,
                       "anti-vacuum: the probe counts — planting the unrelated key is one write")
        XCTAssertNotNil(bannerKeys(taskID: taskID)["worker"], "anti-vacuum: there IS a key to retire")

        DismissalStoreProbe._testReset()
        let answered = await sut.answerSupervisorQuestion(stepID: "worker", taskID: taskID, answer: "go")
        XCTAssertTrue(answered)

        XCTAssertEqual(DismissalStoreProbe._testWrites(), 0,
                       "retiring a key that is not there must not write the set")
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: planted),
                      "and the unrelated dismissal is untouched")
    }

    /// Answering a step that shows NO banner must retire nothing — both degenerate
    /// inputs. `ghost` is not in the run at all, so the answer is refused before the
    /// retirement is reached; `settled` IS in the run and its answer is ACCEPTED, and
    /// there the only thing standing between an accepted answer and a stranger's key is
    /// `activeSupervisorInputDismissKey`'s activeness guard. Its question text outlives
    /// the answer (`supervisorQuestion` is never cleared), so the key it would spell is
    /// exactly the one a later same-text escalation will carry.
    ///
    /// RED: drop `hasActiveSupervisorInput` from the guard in
    /// `activeSupervisorInputDismissKey` → answering the already-settled step spells the
    /// text key anyway and retires it, and the second assertion fails. The three retiring
    /// tests above stay green (their steps are waiting, so the guard holds either way).
    func testAnswer_whenTheStepShowsNoBanner_retiresNothing() async {
        var settled = callKeyedWaitingStep(id: "settled", question: "Settled?")
        settled.needsSupervisorInput = false
        settled.status = .running
        settled.llmConversation = [LLMMessage(
            role: .user, content: "Supervisor answer: done", sourceRole: .supervisor,
            sourceContext: .supervisorAnswer)]
        let taskID = await makeWaitingTask(
            steps: [callKeyedWaitingStep(id: "worker", question: "Q?"), settled])
        let fid = folderID()
        XCTAssertNil(bannerKeys(taskID: taskID)["settled"], "fixture: the settled step shows no banner")
        let workerKey = bannerKeys(taskID: taskID)["worker"]!
        let settledTextKey = WatchtowerDismissKey.supervisorInput(
            taskID: taskID, stepID: "settled", toolCallID: nil, question: "Settled?")
        for key in [workerKey, settledTextKey] {
            sut.configuration.dismissNotification(workFolderID: fid, key: key)
        }

        let refused = await sut.answerSupervisorQuestion(stepID: "ghost", taskID: taskID, answer: "go")
        let accepted = await sut.answerSupervisorQuestion(stepID: "settled", taskID: taskID, answer: "go")

        XCTAssertFalse(refused, "a step that is not in the run cannot take an answer")
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: workerKey),
                      "a refused answer consumed no banner, so it retires no dismissal")
        XCTAssertTrue(accepted, "anti-vacuum: this answer IS applied, so the guard below is what holds")
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: settledTextKey),
                      "an accepted answer to a step showing no banner still consumes none")
    }
}
