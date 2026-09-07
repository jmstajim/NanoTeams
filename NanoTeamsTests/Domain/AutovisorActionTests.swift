import XCTest
@testable import NanoTeams

/// Pure-value corners for the Autovisor action types: `targetTaskID` drives
/// the orchestrator's self-guard, so its folder-level-vs-task-level split must be
/// exact; `AutovisorActionResult` factories; `AutovisorActivation` defaults.
final class AutovisorActionTests: XCTestCase {

    // MARK: - targetTaskID (self-guard input)

    func testTargetTaskID_taskScopedActions_returnTheirTaskID() {
        XCTAssertEqual(AutovisorAction.controlTask(taskID: 5, verb: .pause).targetTaskID, 5)
        XCTAssertEqual(AutovisorAction.manageRole(taskID: 7, roleID: "r", verb: .restart(comment: nil)).targetTaskID, 7)
        XCTAssertEqual(AutovisorAction.answerTaskQuestion(taskID: 3, answer: "a").targetTaskID, 3)
        XCTAssertEqual(AutovisorAction.messageTask(taskID: 9, text: "m", roleID: nil).targetTaskID, 9)
        XCTAssertEqual(AutovisorAction.scheduleTask(taskID: 4, intervalMinutes: 10).targetTaskID, 4)
    }

    func testTargetTaskID_folderLevelActions_areNil() {
        // nil target = the self-guard never blocks these (no task to compare against).
        XCTAssertNil(AutovisorAction.createManagedTask(title: "t", brief: "b", teamID: nil).targetTaskID)
        XCTAssertNil(AutovisorAction.setWorkFolderContext(content: "ctx").targetTaskID)
    }

    // MARK: - AutovisorActionResult

    func testResult_factories() {
        let ok = AutovisorActionResult.success("done", createdTaskID: 12)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.message, "done")
        XCTAssertEqual(ok.createdTaskID, 12)

        let fail = AutovisorActionResult.failure("nope")
        XCTAssertFalse(fail.ok)
        XCTAssertEqual(fail.message, "nope")
        XCTAssertNil(fail.createdTaskID)
    }

    func testResult_successWithoutTaskID_defaultsNil() {
        XCTAssertNil(AutovisorActionResult.success("ok").createdTaskID)
    }

    // MARK: - AutovisorActivation

    func testActivation_defaults() {
        let a = AutovisorActivation.default
        XCTAssertTrue(a.onTaskNeedsSupervisor, "needs-supervisor (the supervisor-routing gate) defaults ON")
        XCTAssertTrue(a.onTaskFailed)
        XCTAssertTrue(a.onTaskCompleted, "wake-on-complete defaults ON so the manager reviews finished work")
        XCTAssertFalse(a.onTaskCreated)
        XCTAssertTrue(a.onTaskStuck)
    }

    func testActivation_roundTrip() throws {
        var a = AutovisorActivation.default
        a.onTaskCompleted = true
        a.onTaskNeedsSupervisor = false
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(a)
        let back = try JSONCoderFactory.makeDateDecoder().decode(AutovisorActivation.self, from: data)
        XCTAssertEqual(back, a)
    }

    func testActivation_legacyDebounceKey_ignoredOnDecode() throws {
        // The removed `minSecondsBetweenRuns` (no throttle anymore) — an old settings.json
        // carrying it must still decode, the stale key simply dropped.
        let json = #"{"onTaskNeedsSupervisor":true,"onTaskFailed":true,"onTaskCompleted":false,"onTaskCreated":false,"minSecondsBetweenRuns":0}"#
        let back = try JSONCoderFactory.makeDateDecoder()
            .decode(AutovisorActivation.self, from: Data(json.utf8))
        XCTAssertFalse(back.onTaskCompleted, "present fields still decode")
    }

    // MARK: - ControlVerb / RoleVerb decode boundary (D1)

    func testControlVerb_parse_validAndArgs() {
        XCTAssertEqual(try? ControlVerb.parse(action: "pause", arg: nil).get(), .pause)
        XCTAssertEqual(try? ControlVerb.parse(action: "STOP", arg: nil).get(), .stop, "case-insensitive")
        XCTAssertEqual(try? ControlVerb.parse(action: "rename", arg: "  New  ").get(), .rename(title: "New"))
        XCTAssertEqual(try? ControlVerb.parse(action: "set_timeout", arg: "90").get(), .setTimeout(seconds: 90))
        XCTAssertEqual(try? ControlVerb.parse(action: "set_timeout", arg: "0").get(), .setTimeout(seconds: nil),
                       "0 clears the timeout")
        XCTAssertEqual(try? ControlVerb.parse(action: "set_timeout", arg: nil).get(), .setTimeout(seconds: nil))
    }

    /// `arg` is read by `rename` and `set_timeout` only. Until 2026-09-06 the six other verbs
    /// accepted it and dropped it — an `ok:true` for a call that asked for something else
    /// (the schema even said "Ignored otherwise."). Now the call is refused and the error
    /// names the two verbs that read it; whitespace-only is still "absent".
    func testControlVerb_parse_rejectsAStrayArgOnVerbsThatDoNotReadIt() {
        for action in ["start", "pause", "resume", "stop", "close", "delete"] {
            guard case .failure(let error) = ControlVerb.parse(action: action, arg: "42") else {
                return XCTFail("\(action) with a non-empty arg must be refused, not silently applied")
            }
            XCTAssertTrue(error.message.contains("rename") && error.message.contains("set_timeout"),
                          "\(action): the refusal names the verbs `arg` belongs to")
            XCTAssertTrue(error.message.contains("`\(action)`"), "\(action): the refusal names the verb sent")
            XCTAssertEqual(try? ControlVerb.parse(action: action, arg: "   ").get(),
                           try? ControlVerb.parse(action: action, arg: nil).get(),
                           "\(action): whitespace-only arg is absent, not stray")
        }
    }

    func testControlVerb_parse_rejectsUnknownAndEmptyRename() {
        guard case .failure = ControlVerb.parse(action: "frobnicate", arg: nil) else { return XCTFail("unknown action must fail") }
        guard case .failure = ControlVerb.parse(action: "rename", arg: "   ") else { return XCTFail("empty rename title must fail") }
    }

    func testRoleVerb_parse_commentRequirements() {
        XCTAssertEqual(try? RoleVerb.parse(action: "restart", comment: nil).get(), .restart(comment: nil))
        XCTAssertEqual(try? RoleVerb.parse(action: "restart", comment: " go ").get(), .restart(comment: "go"))
        XCTAssertEqual(try? RoleVerb.parse(action: "accept", comment: nil).get(), .accept)
        XCTAssertEqual(try? RoleVerb.parse(action: "request_changes", comment: "fix it").get(), .requestChanges(comment: "fix it"))
        XCTAssertEqual(try? RoleVerb.parse(action: "correct", comment: "do X").get(), .correct(comment: "do X"))
        XCTAssertEqual(try? RoleVerb.parse(action: "finish_advisory", comment: nil).get(), .finishAdvisory)
    }

    func testRoleVerb_parse_rejectsMissingComment() {
        guard case .failure = RoleVerb.parse(action: "request_changes", comment: "  ") else { return XCTFail() }
        guard case .failure = RoleVerb.parse(action: "correct", comment: nil) else { return XCTFail() }
        guard case .failure = RoleVerb.parse(action: "nope", comment: nil) else { return XCTFail() }
    }

    // MARK: - AutovisorStatus.lastError (F2: task-scoped, not the global banner)

    func testStatusLastError_returnsFailedStepNote() {
        let step = StepExecution(
            id: "engineer", role: .custom(id: "engineer"), title: "Engineer",
            status: .failed,
            messages: [StepMessage(role: .custom(id: "engineer"), content: "LLM error: boom")]
        )
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "do", runs: [Run(id: 0, steps: [step])])
        XCTAssertEqual(AutovisorStatus.lastError(for: task), "LLM error: boom")
    }

    func testStatusLastError_nilWhenNoFailedStep() {
        let step = StepExecution(id: "engineer", role: .custom(id: "engineer"), title: "Engineer", status: .done)
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "do", runs: [Run(id: 0, steps: [step])])
        XCTAssertNil(AutovisorStatus.lastError(for: task),
                     "a healthy task reports no error (NOT the global banner)")
    }

    func testStatusLastError_genericFallbackWhenNoNote() {
        let step = StepExecution(id: "pm", role: .custom(id: "pm"), title: "PM", status: .failed)
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "do", runs: [Run(id: 0, steps: [step])])
        XCTAssertEqual(AutovisorStatus.lastError(for: task), "Role 'pm' failed.")
    }

    // MARK: - AutovisorStatus.acceptRejectionAdvice (remedy at the decision point)

    private func adviceValue(
        _ status: RoleExecutionStatus?, chat: Bool = false, ready: Bool = false
    ) -> AutovisorStatus.AcceptRejectionAdvice? {
        AutovisorStatus.acceptRejectionAdvice(
            roleStatus: status, isChatModeTask: chat, taskReadyToClose: ready,
            taskID: 7, roleID: "pm")
    }

    private func advice(_ status: RoleExecutionStatus?, chat: Bool = false, ready: Bool = false) -> String? {
        adviceValue(status, chat: chat, ready: ready)?.prose
    }

    func testAcceptAdvice_doneInReview_advisesClose() {
        XCTAssertTrue(advice(.done, ready: true)?.contains("control_task close") == true,
                      "the incident case: a .done role on a ready-to-close Review task must be steered to close")
    }

    func testAcceptAdvice_acceptedInReview_advisesClose() {
        XCTAssertTrue(advice(.accepted, ready: true)?.contains("control_task close") == true,
                      "an already-accepted role on a ready-to-close Review task is finalized the same way")
    }

    func testAcceptAdvice_doneOrAcceptedNotReadyToClose_neutral_noCloseMention() {
        for status in [RoleExecutionStatus.done, .accepted] {
            let a = advice(status, ready: false)
            XCTAssertNotNil(a, "\(status) still deserves advice when the task is not closeable")
            XCTAssertFalse(a?.contains("control_task close") == true,
                           "\(status) beside working OR gated siblings must NOT be told to close")
            XCTAssertTrue(a?.contains("task_status") == true,
                          "\(status) outside ready-to-close points at task_status to see what remains")
        }
    }

    func testAcceptAdvice_doneOrAcceptedOnChatTask_advisesChatClose() {
        for status in [RoleExecutionStatus.done, .accepted] {
            XCTAssertTrue(advice(status, chat: true)?.contains("control_task close") == true,
                          "\(status): a chat task's honest exit is close — a chat task never finishes on its own")
        }
    }

    func testAcceptAdvice_failed_advisesRestart_neverDelete() {
        for ready in [false, true] {
            let a = advice(.failed, ready: ready)
            XCTAssertTrue(a?.contains("manage_role restart") == true,
                          "a failed role's remedy is restart, never a forced accept")
            XCTAssertFalse(a?.contains("delete") == true,
                           "an error string a small model may obey verbatim must not volunteer the irreversible cascade")
        }
    }

    func testAcceptAdvice_working_advisesWaitOrMessageTask() {
        XCTAssertTrue(advice(.working)?.contains("message_task") == true,
                      "a live role can be steered, not accepted")
    }

    func testAcceptAdvice_idleAndReady_adviseNothingProducedYet() {
        for status in [RoleExecutionStatus.idle, .ready] {
            XCTAssertTrue(advice(status)?.contains("task_status") == true,
                          "\(status) has produced nothing to accept — point back at task_status")
        }
    }

    func testAcceptAdvice_revisionRequested_advisesRevisionInFlight() {
        XCTAssertTrue(advice(.revisionRequested)?.contains("revision") == true)
    }

    func testAcceptAdvice_skipped_advisesRestart_namingTheCascade() {
        let a = advice(.skipped)
        XCTAssertTrue(a?.contains("manage_role restart") == true)
        XCTAssertTrue(a?.contains("downstream") == true,
                      "restart resets downstream roles — a Review task's accepted work is at stake, so the cost must be stated")
    }

    func testAcceptAdvice_missingStatusEntry_advisesTaskStatus() {
        XCTAssertTrue(advice(nil)?.contains("task_status") == true,
                      "no status entry → the manager needs the per-role view, not a bare refusal")
    }

    func testAcceptAdvice_needsAcceptance_isNil() {
        for ready in [false, true] {
            XCTAssertNil(advice(.needsAcceptance, ready: ready),
                         ".needsAcceptance routes to .accept — routeAccept never rejects it, so no advice exists")
        }
    }

    /// Capability lint through the house lint, NOT a hand-written tool list: the
    /// derived denylist in `AutovisorGoalLint` is `ToolHandlerRegistry.allTypes` minus
    /// the manager's real toolset, so a tool added or renamed tomorrow is covered the
    /// same day — its own doc records that the previous hand-list-in-a-test missed
    /// 19 of the 25 real gaps. Advising a tool the manager's schema withholds is the
    /// loopWarningMessage defect class.
    func testAcceptAdvice_namesOnlyManagerTools() {
        var checked = 0
        for status in RoleExecutionStatus.allCases {
            for chat in [false, true] {
                for ready in [false, true] {
                    guard let a = advice(status, chat: chat, ready: ready) else { continue }
                    checked += 1
                    let findings = AutovisorGoalLint.scanStrict(a)
                    XCTAssertTrue(findings.isEmpty,
                                  "\(status) chat=\(chat) ready=\(ready): advice names tools the manager lacks: \(findings.map(\.token))")
                }
            }
        }
        // Exactly .needsAcceptance (all four flag combinations) returns nil — a lower
        // count means an arm of the table stopped producing advice.
        XCTAssertEqual(checked, RoleExecutionStatus.allCases.count * 4 - 4,
                       "anti-vacuum: every non-.needsAcceptance arm must produce advice under every flag combination")
    }

    // MARK: - The machine-copyable half (`next`)

    /// The incident this whole slot exists for: the manager got prose and had to
    /// re-derive the call. Every arm that speaks must also hand back a call.
    func testAcceptAdvice_everyArmCarriesAMachineCopyableNextHint() {
        var checked = 0
        for status in RoleExecutionStatus.allCases {
            for chat in [false, true] {
                for ready in [false, true] {
                    guard let a = adviceValue(status, chat: chat, ready: ready) else { continue }
                    checked += 1
                    let ctx = "\(status) chat=\(chat) ready=\(ready)"
                    let cmd = a.next.suggested_cmd
                    XCTAssertNotNil(cmd, "\(ctx): next hint names no command")
                    // Through the house lint, not a hand-written list — same reason the
                    // prose pin above uses it: a tool renamed tomorrow is covered today.
                    XCTAssertTrue(
                        AutovisorGoalLint.scanStrict(cmd ?? "").isEmpty,
                        "\(ctx): next hint names '\(cmd ?? "")', which the manager's schema does not carry")
                    XCTAssertEqual(a.next.suggested_args?["task_id"], "7",
                                   "\(ctx): the hint must carry the task it applies to")
                    XCTAssertFalse(a.next.reason?.isEmpty ?? true, "\(ctx): hint has no reason")
                }
            }
        }
        XCTAssertEqual(checked, RoleExecutionStatus.allCases.count * 4 - 4,
                       "anti-vacuum: same arms as the prose pin above")
    }

    /// One factory, two surfaces. `task_status`'s success envelope and an `accept`
    /// rejection both offer close on a ready-to-close Review task; they were built
    /// independently and are now required to be the same value.
    func testAcceptAdvice_readyToClose_reusesTheSharedCloseHint() throws {
        let a = try XCTUnwrap(adviceValue(.done, ready: true))
        let shared = AutovisorStatus.closeTaskHint(taskID: 7, reason: a.next.reason ?? "")
        XCTAssertEqual(a.next, shared,
                       "the accept-rejection close hint must BE the shared factory's value, not a copy of it")
        XCTAssertEqual(a.next.suggested_args, ["task_id": "7", "action": "close"])
    }

    func testAcceptAdvice_restartHint_carriesRoleAndNoGhostComment() throws {
        for status in [RoleExecutionStatus.failed, .skipped] {
            let a = try XCTUnwrap(adviceValue(status))
            XCTAssertEqual(a.next.suggested_cmd, ToolNames.manageRole, "\(status)")
            XCTAssertEqual(a.next.suggested_args?["role_id"], "pm", "\(status)")
            XCTAssertEqual(a.next.suggested_args?["action"], "restart", "\(status)")
            // A placeholder comment is copied verbatim by exactly the models this hint
            // is for, so the guidance stays the manager's to write.
            XCTAssertNil(a.next.suggested_args?["comment"], "\(status)")
        }
    }

    func testAcceptAdvice_needsAcceptance_hasNoHintEither() {
        for ready in [false, true] {
            XCTAssertNil(adviceValue(.needsAcceptance, ready: ready), "ready=\(ready)")
        }
    }

    /// The funnel end of the same fix: `.failure` must be able to CARRY a hint, or the
    /// Domain half above never reaches the wire.
    func testActionResult_failureCarriesNextHint_andDefaultsToNone() {
        let hint = AutovisorStatus.closeTaskHint(taskID: 3, reason: "why")
        XCTAssertEqual(AutovisorActionResult.failure("no", next: hint).next, hint)
        XCTAssertNil(AutovisorActionResult.failure("no").next)
        XCTAssertEqual(AutovisorActionResult.success("ok", next: hint).next, hint)
        XCTAssertNil(AutovisorActionResult.success("ok").next)
    }
}
