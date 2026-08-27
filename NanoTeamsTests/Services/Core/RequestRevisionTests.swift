import XCTest

@testable import NanoTeams

/// Tests for `requestRevision()` — Supervisor (or Autovisor via `manage_role(request_changes)`)
/// requests changes from a completed role.
///
/// Regression focus: the "Supervisor Feedback: " prefix must be applied exactly ONCE,
/// at LLM-send time. `requestRevision` stores the RAW comment in `revisionComment`
/// (the appended StepMessage keeps the prefixed copy for the stateless conversation
/// rebuild — `PromptBuilder` reads `step.messages` when no session survives), and
/// `resetStepForRevision` prefers that raw comment over re-deriving from the
/// prefixed message content. Pre-fix, the derive-from-message path produced
/// "Supervisor Feedback: Supervisor Feedback: …" in the activity feed and on the wire.
@MainActor
final class RequestRevisionTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Helpers

    private func createTaskWithDoneStep(roleID: String) async -> Int {
        await sut.openWorkFolder(tempDir)
        // AFTER openWorkFolder — that reloads teams from disk and would discard the roster edit.
        await registerRolesOnActiveTeam([roleID])
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        let step = StepExecution(
            id: roleID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            messages: [StepMessage(role: .softwareEngineer, content: "Done.")]
        )
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [step], roleStatuses: [roleID: .needsAcceptance])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return taskID
    }

    // MARK: - Raw comment invariant

    func testRequestRevision_storesRawRevisionComment_andPrefixedMessage() async {
        let roleID = "swe-revision"
        let taskID = await createTaskWithDoneStep(roleID: roleID)
        let comment = "Fix restartGame() to preserve the selected character."

        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: comment)

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.revisionComment, comment,
                       "revisionComment must hold the RAW comment — prefix is applied at send time")
        XCTAssertEqual(step?.messages.last?.role, .supervisor)
        XCTAssertEqual(step?.messages.last?.content, "Supervisor Feedback: \(comment)",
                       "StepMessage keeps a SINGLE prefixed copy for history display")
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses[roleID], .revisionRequested)
    }

    func testRequestRevision_neverDoublesPrefix_throughResetStepForRevision() async {
        let roleID = "swe-no-double"
        let taskID = await createTaskWithDoneStep(roleID: roleID)
        let comment = "Verify and document the drop-spawning logic."

        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: comment)

        // Simulate the engine's follow-up: resetStepForRevision via the real adapter.
        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: taskID)
        await adapter.resetStepForRevision(stepID: roleID)

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.status, .pending, "Step resets to pending for re-execution")
        XCTAssertEqual(step?.revisionComment, comment,
                       "Raw revisionComment survives resetStepForRevision unchanged")
        XCTAssertFalse(step?.revisionComment?.contains("Supervisor Feedback:") ?? true,
                       "The doubled-prefix bug: revisionComment must never contain the prefix")
    }

    /// Defense-in-depth: a step that reaches `.revisionRequested` without a stored raw
    /// `revisionComment` (a task persisted by an older build, or a future status writer)
    /// must fall back to the last supervisor message content. All current production
    /// flows (`requestRevision`, `executeAmendment`, `propagateAmendmentDownstream`)
    /// store the raw comment explicitly — this pins the fallback so it isn't deleted
    /// as dead code.
    func testResetStepForRevision_fallsBackToMessage_whenNoRawCommentSet() async {
        let roleID = "swe-amendment"
        let taskID = await createTaskWithDoneStep(roleID: roleID)
        let amendmentText = "## AMENDMENT REQUEST\nPlease address the review findings."

        await sut.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == roleID })
            else { return }
            task.runs[runIndex].steps[stepIndex].messages.append(
                StepMessage(role: .supervisor, content: amendmentText)
            )
            task.runs[runIndex].roleStatuses[roleID] = .revisionRequested
        }

        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: taskID)
        await adapter.resetStepForRevision(stepID: roleID)

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.revisionComment, amendmentText,
                       "Without a raw comment, the last supervisor message is the fallback")
    }

    // MARK: - Status gate (loud failure instead of silent corruption)

    /// A revision against a role whose step is still `.running` must fail loudly.
    /// Pre-gate, flipping the role to `.revisionRequested` made the engine's revision
    /// branch call `runStep` on a live step (`resetStepForRevision` no-ops on
    /// non-done steps), spawning a second concurrent LLM execution — while the
    /// Autovisor's `manage_role(request_changes)` reported success.
    func testRequestRevision_runningStep_failsLoudly() async {
        let roleID = "swe-running"
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        let step = StepExecution(
            id: roleID, role: .softwareEngineer, title: "SWE",
            status: .running,
            messages: [StepMessage(role: .softwareEngineer, content: "Streaming…")]
        )
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [step], roleStatuses: [roleID: .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        sut.lastErrorMessage = nil

        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: "Change this")

        XCTAssertNotNil(sut.lastErrorMessage,
                        "Revision on a running step must surface an error (Autovisor converts it to a failure envelope)")
        let updated = sut.activeTask?.runs.last
        XCTAssertEqual(updated?.roleStatuses[roleID], .working,
                       "Role status must NOT flip — a live step cannot be reset for revision")
        XCTAssertNil(updated?.steps.first?.revisionComment,
                     "No revisionComment on a live step — it would gate artifact auto-completion mid-stream")
        XCTAssertEqual(updated?.steps.first?.messages.count, 1,
                       "No feedback message appended on the rejected path")
    }

    func testRequestRevision_unknownRole_failsLoudly() async {
        let roleID = "swe-known"
        let taskID = await createTaskWithDoneStep(roleID: roleID)
        sut.lastErrorMessage = nil

        await sut.requestRevision(taskID: taskID, roleID: "nonexistent-role", comment: "Fix")

        XCTAssertNotNil(sut.lastErrorMessage,
                        "Unknown roleID must surface an error, not silently no-op")
        let updated = sut.activeTask?.runs.last
        XCTAssertNil(updated?.roleStatuses["nonexistent-role"],
                     "No phantom role status entry for an unknown role")
        XCTAssertNil(updated?.steps.first?.revisionComment,
                     "Existing step must remain untouched")
    }

    // MARK: - Corner: gate boundaries

    /// `.failed` is revisable — it's the other status `resetStepForRevision` acts on
    /// (re-running a failed revision attempt with fresh guidance is a legitimate flow).
    func testRequestRevision_failedStep_isAllowed() async {
        let roleID = "swe-failed"
        await sut.openWorkFolder(tempDir)
        await registerRolesOnActiveTeam([roleID])
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        let step = StepExecution(
            id: roleID, role: .softwareEngineer, title: "SWE",
            status: .failed
        )
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [step], roleStatuses: [roleID: .failed])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        sut.lastErrorMessage = nil

        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: "Try a simpler approach")

        XCTAssertNil(sut.lastErrorMessage, "Failed steps are revisable — no error expected")
        let updated = sut.activeTask?.runs.last
        XCTAssertEqual(updated?.roleStatuses[roleID], .revisionRequested)
        XCTAssertEqual(updated?.steps.first?.revisionComment, "Try a simpler approach")
    }

    /// A step parked in `.needsSupervisorInput` has a pending question — revision is
    /// the wrong verb (the answer path owns that state). Must reject loudly, not
    /// strand the role with a status flip the run loop's supervisor-input branch
    /// will shadow forever.
    func testRequestRevision_needsSupervisorInputStep_failsLoudly() async {
        let roleID = "swe-waiting"
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        let step = StepExecution(
            id: roleID, role: .softwareEngineer, title: "SWE",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Which database?"
        )
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [step], roleStatuses: [roleID: .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        sut.lastErrorMessage = nil

        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: "Change this")

        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertEqual(sut.activeTask?.runs.last?.roleStatuses[roleID], .working,
                       "Role status untouched — the question/answer path owns this state")
    }

    // MARK: - Corner: comment normalization at entry

    func testRequestRevision_emptyComment_failsLoudly() async {
        let roleID = "swe-empty"
        let taskID = await createTaskWithDoneStep(roleID: roleID)
        sut.lastErrorMessage = nil

        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: "   \n\t ")

        XCTAssertNotNil(sut.lastErrorMessage, "Whitespace-only comment must be rejected")
        let updated = sut.activeTask?.runs.last
        XCTAssertNil(updated?.steps.first?.revisionComment)
        XCTAssertNotEqual(updated?.roleStatuses[roleID], .revisionRequested)
    }

    /// The Autovisor's LLM sees "Supervisor Feedback: …" turns in conversation history
    /// and can echo the prefix inside its `comment` argument. Entry normalization
    /// strips it so neither storage layer carries a baked-in prefix.
    func testRequestRevision_commentCarryingPrefix_isNormalizedToRaw() async {
        let roleID = "swe-prefixed"
        let taskID = await createTaskWithDoneStep(roleID: roleID)

        await sut.requestRevision(
            taskID: taskID, roleID: roleID,
            comment: "Supervisor Feedback: Fix the restart bug.")

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.revisionComment, "Fix the restart bug.",
                       "revisionComment must be raw — caller-supplied prefix stripped")
        XCTAssertEqual(step?.messages.last?.content, "Supervisor Feedback: Fix the restart bug.",
                       "StepMessage carries exactly one prefix, not two")
    }

    /// A comment that merely MENTIONS the prefix mid-text is user content — only a
    /// leading occurrence is attribution.
    func testRequestRevision_prefixMidComment_isPreserved() async {
        let roleID = "swe-midtext"
        let taskID = await createTaskWithDoneStep(roleID: roleID)
        let comment = "Rename the 'Supervisor Feedback: ' label in the template"

        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: comment)

        XCTAssertEqual(sut.activeTask?.runs.last?.steps.first?.revisionComment, comment)
    }

    // MARK: - Corner: multi-run task targets the latest run only

    /// `requestRevision` operates on `runs.last`. A role that completed in an OLD run
    /// but has no step in the current one must be rejected — mutating history would
    /// produce a `.revisionRequested` the engine (which also reads `runs.last`) acts
    /// on against a step from a different lifecycle.
    func testRequestRevision_roleOnlyInPriorRun_failsLoudly() async {
        let roleID = "swe-old-run"
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!
        let oldStep = StepExecution(
            id: roleID, role: .softwareEngineer, title: "SWE",
            status: .done,
            completedAt: MonotonicClock.shared.now()
        )
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [
                Run(id: 0, steps: [oldStep], roleStatuses: [roleID: .done]),
                Run(id: 1, steps: [], roleStatuses: [:]),  // fresh run, role not started
            ]
        }
        sut.lastErrorMessage = nil

        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: "Fix it")

        XCTAssertNotNil(sut.lastErrorMessage)
        XCTAssertNil(sut.activeTask?.runs.first?.steps.first?.revisionComment,
                     "Prior-run step must never be mutated")
        XCTAssertTrue(sut.activeTask?.runs.last?.roleStatuses.isEmpty ?? false,
                      "Latest run untouched")
    }

    // MARK: - Corner: whitespace-only legacy revisionComment falls through

    /// Legacy data: a persisted step whose `revisionComment` is whitespace-only is
    /// "no usable feedback" — `resetStepForRevision` must fall through to the message
    /// content instead of propagating blank feedback to the send site.
    func testResetStepForRevision_whitespaceOnlyComment_fallsBackToMessage() async {
        let roleID = "swe-blank-comment"
        let taskID = await createTaskWithDoneStep(roleID: roleID)
        let messageText = "Supervisor Feedback: The real guidance lives here."

        await sut.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == roleID })
            else { return }
            task.runs[runIndex].steps[stepIndex].messages.append(
                StepMessage(role: .supervisor, content: messageText)
            )
            task.runs[runIndex].steps[stepIndex].revisionComment = "   \n"
            task.runs[runIndex].roleStatuses[roleID] = .revisionRequested
        }

        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: taskID)
        await adapter.resetStepForRevision(stepID: roleID)

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.revisionComment, messageText,
                       "Blank stored comment must fall through to the message fallback")
    }

    // MARK: - Sequential revisions

    /// Two full revision cycles: each `requestRevision` overwrites `revisionComment`
    /// with its own raw comment, and each cycle leaves exactly one single-prefixed
    /// feedback message. Guards the overwrite semantics against a future
    /// "only set if nil" conditioning — under which cycle 2 would fall back to the
    /// LAST prefixed message and resurrect the doubled prefix.
    func testRequestRevision_sequentialCycles_overwriteRawComment() async {
        let roleID = "swe-sequential"
        let taskID = await createTaskWithDoneStep(roleID: roleID)
        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: taskID)

        // Cycle 1
        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: "First pass fix")
        await adapter.resetStepForRevision(stepID: roleID)

        // Simulate the revision completing: LLM produced a new artifact (clears the
        // comment — pinned by RevisionContinuationTests) and the step finished.
        await sut.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last,
                  let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == roleID })
            else { return }
            task.runs[runIndex].steps[stepIndex].revisionComment = nil
            task.runs[runIndex].steps[stepIndex].status = .done
            task.runs[runIndex].roleStatuses[roleID] = .needsAcceptance
        }

        // Cycle 2
        await sut.requestRevision(taskID: taskID, roleID: roleID, comment: "Second pass fix")
        await adapter.resetStepForRevision(stepID: roleID)

        let step = sut.activeTask?.runs.last?.steps.first
        XCTAssertEqual(step?.revisionComment, "Second pass fix",
                       "Cycle 2 must carry its own raw comment, not cycle 1's")
        let feedbackMessages = step?.messages.filter {
            $0.role == .supervisor && $0.content.hasPrefix("Supervisor Feedback:")
        } ?? []
        XCTAssertEqual(feedbackMessages.count, 2, "One single-prefixed message per cycle")
        for message in feedbackMessages {
            XCTAssertEqual(
                message.content.components(separatedBy: "Supervisor Feedback:").count, 2,
                "Each feedback message carries exactly one prefix: \(message.content)")
        }
    }

}
