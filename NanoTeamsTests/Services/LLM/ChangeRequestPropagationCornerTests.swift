import XCTest

@testable import NanoTeams

/// Corner-case tests for the downstream-propagation half of the `request_changes` flow
/// (Fix B at the service layer):
/// - `propagateAmendmentDownstream` done-vs-running-vs-skipped branching
/// - `executeAmendment` → `holdDownstreamForRevision` wiring (only fires for running roles)
///
/// Mirrors `ChangeRequestIntegrationTests` setUp/tearDown and the `service`/`mockDelegate`
/// fields exactly. Helpers are file-private local builders so the tests stay self-contained.
@MainActor
final class ChangeRequestPropagationCornerTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try? FileManager.default.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        mockDelegate = nil
        service = nil
        super.tearDown()
    }

    // MARK: - propagate: done-branch acceptance sub-states

    /// The done-branch accepts roleStatus ∈ {.done, .accepted, .needsAcceptance}. A
    /// `.needsAcceptance` downstream role (a mid-pipeline acceptance gate) on a `.done`
    /// step must be queued for revision like any other completed role — otherwise a
    /// regression narrowing that set would silently strand it.
    func testPropagate_doneStepWithNeedsAcceptanceRoleStatus_isDoneBranch() async {
        let (task, team) = makeTaskWithDownstream(
            downstreamStepStatus: .done,
            downstreamRoleStatus: .needsAcceptance
        )
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Updated implementation",
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        XCTAssertEqual(updated.runs[0].roleStatuses["code_reviewer"], .revisionRequested,
                       ".done step + .needsAcceptance roleStatus must be treated as the done-branch (queued for revision)")
        XCTAssertFalse(result.runningRoleIDs.contains("code_reviewer"),
                       "a done-branch role is NOT a running role — it is flipped directly, not held")
        XCTAssertTrue(result.summary.contains("Downstream amendments triggered"))
    }

    /// Same for `.accepted` — also a member of the done-branch set.
    func testPropagate_doneStepWithAcceptedRoleStatus_isDoneBranch() async {
        let (task, team) = makeTaskWithDownstream(
            downstreamStepStatus: .done,
            downstreamRoleStatus: .accepted
        )
        mockDelegate.taskToMutate = task

        _ = await service._testPropagateAmendmentDownstream(
            taskID: task.id, sourceRoleID: "engineer", changes: "X", team: team
        )

        XCTAssertEqual(mockDelegate.taskToMutate!.runs[0].roleStatuses["code_reviewer"], .revisionRequested,
                       ".done step + .accepted roleStatus must be treated as the done-branch")
    }

    // MARK: - propagate: SKIPPED branches

    /// Downstream step is `.done` but its roleStatus is `.failed` — that is NOT one of
    /// {.done,.accepted,.needsAcceptance}, so it does NOT count as the done-branch, and
    /// stepStatus != .running so it is not the running-branch either → SKIPPED.
    func testPropagate_doneStepWithFailedRoleStatus_isSkipped() async {
        let (task, team) = makeTaskWithDownstream(
            downstreamStepStatus: .done,
            downstreamRoleStatus: .failed
        )
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Updated implementation",
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        XCTAssertEqual(updated.runs[0].roleStatuses["code_reviewer"], .failed,
                       "A .done step with a .failed roleStatus must be skipped — roleStatus stays .failed, never flipped to .revisionRequested")
        XCTAssertFalse(result.runningRoleIDs.contains("code_reviewer"),
                       "A skipped role must not be reported in runningRoleIDs")
        let crStep = updated.runs[0].steps.first { $0.effectiveRoleID == "code_reviewer" }!
        XCTAssertNil(crStep.revisionComment,
                     "A skipped role must not have a revisionComment set")
    }

    /// Downstream step `.paused` is neither `.done`-terminal nor `.running` → SKIPPED entirely.
    func testPropagate_pausedStep_isSkipped() async {
        let (task, team) = makeTaskWithDownstream(
            downstreamStepStatus: .paused,
            downstreamRoleStatus: .working
        )
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Updated implementation",
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        XCTAssertEqual(updated.runs[0].roleStatuses["code_reviewer"], .working,
                       "A .paused downstream step must be skipped — its roleStatus is left untouched")
        XCTAssertFalse(result.runningRoleIDs.contains("code_reviewer"),
                       "A .paused step must not be reported in runningRoleIDs")
        let crStep = updated.runs[0].steps.first { $0.effectiveRoleID == "code_reviewer" }!
        XCTAssertNil(crStep.revisionComment,
                     "A skipped .paused step must not have a revisionComment set")
    }

    // MARK: - propagate: RUNNING branch details

    /// A running downstream role gets the raw notice block as its revisionComment and is
    /// reported in runningRoleIDs (so the caller can hold it); propagate does NOT flip its status.
    func testPropagate_runningRole_setsRawRevisionCommentAndReportsIt() async {
        let (task, team) = makeTaskWithDownstream(
            downstreamStepStatus: .running,
            downstreamRoleStatus: .working
        )
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Updated implementation",
            team: team
        )

        let updated = mockDelegate.taskToMutate!
        let crStep = updated.runs[0].steps.first { $0.effectiveRoleID == "code_reviewer" }!
        XCTAssertTrue(result.runningRoleIDs.contains("code_reviewer"),
                      "A running downstream role must be reported in runningRoleIDs for the hold hook")
        XCTAssertEqual(crStep.revisionComment, crStep.messages.last?.content,
                       "A running role's revisionComment must equal the injected notice block")
        XCTAssertTrue(crStep.revisionComment?.contains("UPSTREAM AMENDMENT NOTICE") ?? false,
                      "A running role's injected revisionComment must be the UPSTREAM AMENDMENT NOTICE block")
    }

    // MARK: - propagate: MIXED done + running

    /// One downstream role `.done`(+.done roleStatus) and a second `.running`:
    /// - done one flipped to `.revisionRequested` and named in the "amendments triggered" summary
    /// - running one collected into runningRoleIDs, NOT status-flipped by propagate (stays .working),
    ///   but its revisionComment IS set
    /// - summary mentions BOTH the "amendments triggered" and "held for revision" phrases
    func testPropagate_mixedDoneAndRunning_branchesIndependently() async {
        let (task, team) = makeMixedDownstreamTask()
        mockDelegate.taskToMutate = task

        let result = await service._testPropagateAmendmentDownstream(
            taskID: task.id,
            sourceRoleID: "engineer",
            changes: "Updated implementation",
            team: team
        )

        let updated = mockDelegate.taskToMutate!

        // Done branch
        XCTAssertEqual(updated.runs[0].roleStatuses["code_reviewer"], .revisionRequested,
                       "The done downstream role must be flipped to .revisionRequested")
        XCTAssertTrue(result.summary.contains("Downstream amendments triggered"),
                      "Summary must report the done-branch amendment")

        // Running branch
        XCTAssertTrue(result.runningRoleIDs.contains("sre"),
                      "The running downstream role must be collected into runningRoleIDs")
        XCTAssertEqual(updated.runs[0].roleStatuses["sre"], .working,
                       "propagate must NOT flip the running role's status — the hold hook does that")
        let sreStep = updated.runs[0].steps.first { $0.effectiveRoleID == "sre" }!
        XCTAssertNotNil(sreStep.revisionComment,
                        "The running role must still get its revisionComment set by propagate")
        XCTAssertTrue(result.summary.contains("held for revision"),
                      "Summary must report the running-branch hold")
    }

    // MARK: - executeAmendment → holdDownstreamForRevision wiring

    /// With a RUNNING downstream role present, executeAmendment must call the hold hook:
    /// heldDownstreamCalls is non-empty, its last entry's runningRoleIDs contains the running
    /// role, and requesterStepID equals the value passed; target role set to .revisionRequested.
    func testExecuteAmendment_withRunningDownstream_firesHoldHook() async {
        let (task, team) = makeTaskWithDownstream(
            downstreamStepStatus: .running,
            downstreamRoleStatus: .working
        )
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: "engineer", taskID: task.id)

        _ = await service._testExecuteAmendment(
            taskID: task.id,
            targetRoleID: "engineer",
            changes: "Add error handling",
            reasoning: "Missing null checks",
            requestingRoleID: "code_reviewer",
            requesterStepID: "code_reviewer",
            meetingID: nil,
            team: team
        )

        XCTAssertFalse(mockDelegate.heldDownstreamCalls.isEmpty,
                       "executeAmendment must fire holdDownstreamForRevision when a running downstream role exists")
        let lastHold = mockDelegate.heldDownstreamCalls.last!
        XCTAssertTrue(lastHold.runningRoleIDs.contains("code_reviewer"),
                      "The hold hook must carry the running downstream role")
        XCTAssertEqual(lastHold.requesterRoleID, "code_reviewer",
                       "The hold hook must carry the requester role id passed to executeAmendment")

        let updated = mockDelegate.taskToMutate!
        XCTAssertEqual(updated.runs[0].roleStatuses["engineer"], .revisionRequested,
                       "The amended target role must be set to .revisionRequested")
    }

    /// With NO running downstream roles (target done, downstream done), the hold hook must
    /// NOT fire — it only triggers when propagate reports a non-empty runningRoleIDs.
    func testExecuteAmendment_noRunningDownstream_holdHookStaysEmpty() async {
        let (task, team) = makeTaskWithDownstream(
            downstreamStepStatus: .done,
            downstreamRoleStatus: .done
        )
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: "engineer", taskID: task.id)

        _ = await service._testExecuteAmendment(
            taskID: task.id,
            targetRoleID: "engineer",
            changes: "Add error handling",
            reasoning: "Missing null checks",
            requestingRoleID: "code_reviewer",
            requesterStepID: "code_reviewer",
            meetingID: nil,
            team: team
        )

        XCTAssertTrue(mockDelegate.heldDownstreamCalls.isEmpty,
                      "holdDownstreamForRevision must NOT fire when there are no running downstream roles")
    }

    // MARK: - Helpers

    /// Task with a done `engineer` (target) step + a single downstream `code_reviewer`
    /// step whose status is configurable. The engineer produces "Engineering Notes" which
    /// code_reviewer requires (direct downstream consumer).
    private func makeTaskWithDownstream(
        downstreamStepStatus: StepStatus,
        downstreamRoleStatus: RoleExecutionStatus
    ) -> (NTMSTask, Team) {
        var task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Build feature")

        let engArtifact = Artifact(
            name: "Engineering Notes",
            mimeType: "text/markdown",
            relativePath: "steps/test/engineering_notes.md"
        )
        let engStep = StepExecution(
            id: "engineer",
            role: .softwareEngineer,
            title: "Engineer",
            expectedArtifacts: ["Engineering Notes"],
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            artifacts: [engArtifact]
        )
        let crStep = StepExecution(
            id: "code_reviewer",
            role: .codeReviewer,
            title: "Code Reviewer",
            expectedArtifacts: ["Code Review"],
            status: downstreamStepStatus,
            completedAt: downstreamStepStatus == .done ? MonotonicClock.shared.now() : nil
        )

        var run = Run(id: 0, steps: [engStep, crStep])
        run.roleStatuses["engineer"] = .done
        run.roleStatuses["code_reviewer"] = downstreamRoleStatus
        task.runs = [run]

        return (task, makeTeam(secondDownstream: false))
    }

    /// Task with a done `engineer` + a DONE downstream `code_reviewer` + a RUNNING downstream
    /// `sre`. Both code_reviewer and sre directly consume "Engineering Notes".
    private func makeMixedDownstreamTask() -> (NTMSTask, Team) {
        var task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Build feature")

        let engArtifact = Artifact(
            name: "Engineering Notes",
            mimeType: "text/markdown",
            relativePath: "steps/test/engineering_notes.md"
        )
        let engStep = StepExecution(
            id: "engineer",
            role: .softwareEngineer,
            title: "Engineer",
            expectedArtifacts: ["Engineering Notes"],
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            artifacts: [engArtifact]
        )
        let crStep = StepExecution(
            id: "code_reviewer",
            role: .codeReviewer,
            title: "Code Reviewer",
            expectedArtifacts: ["Code Review"],
            status: .done,
            completedAt: MonotonicClock.shared.now()
        )
        let sreStep = StepExecution(
            id: "sre",
            role: .custom(id: "sre"),
            title: "SRE",
            expectedArtifacts: ["Production Readiness"],
            status: .running
        )

        var run = Run(id: 0, steps: [engStep, crStep, sreStep])
        run.roleStatuses["engineer"] = .done
        run.roleStatuses["code_reviewer"] = .done
        run.roleStatuses["sre"] = .working
        task.runs = [run]

        return (task, makeTeam(secondDownstream: true))
    }

    /// Team with engineer producing "Engineering Notes", code_reviewer consuming it, and
    /// optionally an `sre` role also consuming it (second direct downstream).
    private func makeTeam(secondDownstream: Bool) -> Team {
        var roles: [TeamRoleDefinition] = []

        roles.append(TeamRoleDefinition(
            id: "engineer",
            name: "Software Engineer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Engineering Notes"]
            )
        ))

        roles.append(TeamRoleDefinition(
            id: "code_reviewer",
            name: "Code Reviewer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Engineering Notes"],
                producesArtifacts: ["Code Review"]
            )
        ))

        if secondDownstream {
            roles.append(TeamRoleDefinition(
                id: "sre",
                name: "SRE",
                prompt: "",
                toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(
                    requiredArtifacts: ["Engineering Notes"],
                    producesArtifacts: ["Production Readiness"]
                )
            ))
        }

        return Team(
            name: "Test Team",
            roles: roles,
            artifacts: [],
            settings: .default,
            graphLayout: TeamGraphLayout()
        )
    }
}
