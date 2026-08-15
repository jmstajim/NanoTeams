import XCTest
@testable import NanoTeams

/// `retryTeamGenerationReportingResult` — the seam `manage_role restart` routes to when the
/// manager targets the synthetic `team_generation_*` step.
///
/// Reporting honestly here is not cosmetic. `retryTeamGeneration` deletes every
/// `team_generation_*` step BEFORE it re-checks `needsTeamGeneration`, so calling it on a
/// task that has nothing to regenerate is destructive: the `create_team` card is the only
/// record of how the team was produced, and the deletion also erases the very evidence a
/// "did anything change?" test would look at — which is how the first cut came to report
/// `ok:true` for a call that regenerated nothing.
@MainActor
final class TeamGenerationRetryReportingTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Nothing to retry

    func testNoPendingGeneration_reportsFailure_andPreservesTheRecord() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build something")
        else { XCTFail("createTask returned nil"); return }
        await seedGenerationStep(taskID: taskID, status: .done, isError: false)

        let result = await sut.retryTeamGenerationReportingResult(taskID: taskID)

        XCTAssertFalse(result.ok, "regenerating nothing must not report success: \(result.message)")
        XCTAssertTrue(
            result.message.contains("no pending team generation"), result.message)
        XCTAssertTrue(
            hasGenerationStep(taskID: taskID),
            "the create_team record must survive a refused retry")
    }

    /// Same guard through the manager's actual entry point.
    func testManageRoleRestartOnGenerationStep_withNothingToRetry_isRefusedNonDestructively()
        async
    {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build something")
        else { XCTFail("createTask returned nil"); return }
        let stepID = await seedGenerationStep(taskID: taskID, status: .done, isError: false)

        let result = await sut.performAutovisorAction(
            .manageRole(taskID: taskID, roleID: stepID, verb: .restart(comment: nil)))

        XCTAssertFalse(result.ok, result.message)
        XCTAssertTrue(hasGenerationStep(taskID: taskID))
    }

    // MARK: - A retry that cannot start

    /// The re-entrancy guard reports through `lastInfoMessage`, so wrapping the plain call
    /// in `reportingError` would have called this a success. Reading the outcome off
    /// durable state instead also makes it immune to the error banner, which consumes
    /// `lastErrorMessage`/`lastInfoMessage` on any render during the await.
    func testGenerationAlreadyInFlight_reportsFailure() async {
        await sut.openWorkFolder(tempDir)
        await seedGeneratedTemplate()
        guard let template = sut.workFolder?.teams.first(where: { $0.templateID == "generated" })
        else { XCTFail("expected the generated template"); return }
        guard let taskID = await sut.createTask(
            title: "Gen", supervisorTask: "build something", preferredTeamID: template.id)
        else { XCTFail("createTask returned nil"); return }
        let stepID = await seedGenerationStep(taskID: taskID, status: .failed, isError: true)

        // Occupy the slot the way an in-flight detached generation would.
        XCTAssertTrue(sut.beginTeamGeneration(taskID: taskID))
        defer { sut.endTeamGeneration(taskID: taskID) }

        let result = await sut.retryTeamGenerationReportingResult(taskID: taskID)

        XCTAssertFalse(result.ok, result.message)
        // NOT "failed again": the surviving `.failed` step is the PRIOR attempt's, because
        // the re-entrancy guard returns before the cleanup mutation. Reporting its error
        // here would blame this call for a failure it never produced.
        XCTAssertTrue(result.message.contains("already in progress"), result.message)
        XCTAssertFalse(result.message.contains("prior failure"), result.message)
        XCTAssertTrue(
            hasGenerationStep(taskID: taskID),
            "a retry that never began must not have cleared the prior step")
        _ = stepID
    }

    // MARK: - Non-restart verbs on the synthetic step

    /// The refusal branch: every role verb OTHER than `restart` must be rejected on a
    /// `team_generation_*` id, non-destructively. Unpinned, `manage_role request_changes`
    /// reached `requestRevision` and `finish_advisory` reached `finishRoleAndMaybeClose`
    /// on a step that belongs to no roster and that the engine can never advance —
    /// "not a no-op, it is destructive", as the guard's own comment puts it.
    func testNonRestartVerbsOnGenerationStep_areRefused_andChangeNothing() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build something")
        else { XCTFail("createTask returned nil"); return }
        let stepID = await seedGenerationStep(taskID: taskID, status: .failed, isError: true)

        let verbs: [(RoleVerb, String)] = [
            (.accept, "accept"),
            (.requestChanges(comment: "redo it"), "request_changes"),
            (.correct(comment: "fix it"), "correct"),
            (.finishAdvisory, "finish_advisory"),
        ]
        for (verb, wireName) in verbs {
            let result = await sut.performAutovisorAction(
                .manageRole(taskID: taskID, roleID: stepID, verb: verb))

            XCTAssertFalse(result.ok, "\(wireName) must be refused: \(result.message)")
            // The message names the verb back, which is what `autovisorVerbName` is for.
            XCTAssertTrue(result.message.contains(wireName), result.message)
            XCTAssertTrue(result.message.contains("team generation"), result.message)
            XCTAssertTrue(
                hasGenerationStep(taskID: taskID),
                "\(wireName) must not have touched the step")
            XCTAssertEqual(
                sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .failed,
                "\(wireName) must not have reset the step's status")
        }
    }

    /// `autovisorVerbName` had no test at all, and it is the only reason the refusal above
    /// can name the verb the manager actually sent.
    func testAutovisorVerbName_matchesTheWireSpellingForEveryVerb() {
        XCTAssertEqual(RoleVerb.restart(comment: nil).autovisorVerbName, "restart")
        XCTAssertEqual(RoleVerb.accept.autovisorVerbName, "accept")
        XCTAssertEqual(RoleVerb.requestChanges(comment: "x").autovisorVerbName, "request_changes")
        XCTAssertEqual(RoleVerb.correct(comment: "x").autovisorVerbName, "correct")
        XCTAssertEqual(RoleVerb.finishAdvisory.autovisorVerbName, "finish_advisory")
        // Every spelling must also be one `parse` accepts, or the manager is told to send
        // a verb the decode boundary rejects.
        for name in RoleVerb.actionNames {
            guard case .success = RoleVerb.parse(action: name, comment: "c") else {
                XCTFail("actionNames advertises '\(name)' but parse rejects it"); return
            }
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func seedGenerationStep(
        taskID: Int, status: StepStatus, isError: Bool
    ) async -> String {
        let stepID = "\(StepExecution.teamGenerationIDPrefix)SEEDED"
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(
                id: 0,
                steps: [
                    StepExecution(
                        id: stepID,
                        role: .supervisor,
                        title: "Generate Team",
                        status: status,
                        toolCalls: [
                            StepToolCall(
                                name: ToolNames.createTeam,
                                argumentsJSON: "{}",
                                resultJSON: isError
                                    ? #"{"ok":false,"error":{"message":"prior failure"}}"#
                                    : #"{"ok":true,"data":{"status":"created"}}"#,
                                isError: isError)
                        ])
                ],
                roleStatuses: [:])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return stepID
    }

    private func hasGenerationStep(taskID: Int) -> Bool {
        sut.loadedTask(taskID)?.runs.last?.steps.contains {
            $0.isTeamGenerationStep
        } ?? false
    }

    private func seedGeneratedTemplate() async {
        await sut.mutateWorkFolder { project in
            guard !project.teams.contains(where: { $0.templateID == "generated" }) else { return }
            project.teams.append(TeamTemplateFactory.generatedTeam())
        }
    }
}
