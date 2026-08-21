import XCTest

@testable import NanoTeams

/// `restartRole` must refuse the synthetic `team_generation_*` step id.
///
/// That step belongs to no team roster and the engine cannot execute it, so restarting it
/// is not a no-op but destructive: `StepExecution.reset()` erases the `create_team` error
/// envelope (the only record of WHY generation failed), writes a phantom `roleStatuses`
/// entry for an id no roster contains, and clears the recovery latch. Worse, the method's
/// own post-mutation verification PASSES on the result (`roleStatuses[roleID] == .idle`,
/// step `.pending`), so it reported success. Observed in production 2026-08-07; the task
/// then derived `.running` forever with a dead engine, invisible to the Autovisor's
/// triage — which has no `running` bullet.
///
/// The Autovisor layer routes `manage_role restart` on this prefix to
/// `retryTeamGenerationReportingResult` before it reaches here
/// (`TeamGenerationRetryReportingTests` owns that), and the UI resolves `selectedRoleID`
/// from roster ids. This suite pins the structural backstop UNDER both, which is what
/// makes the primitive total for callers that don't exist yet.
@MainActor
final class RoleControlTeamGenerationGuardTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let generationStepID = "\(StepExecution.teamGenerationIDPrefix)ABC"

    func testRestartRole_onAGenerationStepID_refusesAndPreservesTheRecord() async {
        guard let taskID = await seedTaskWithGenerationStep() else { return }

        await sut.restartRole(taskID: taskID, roleID: generationStepID, comment: nil)

        guard let step = sut.loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.id == generationStepID })
        else { XCTFail("the generation step vanished"); return }

        XCTAssertEqual(step.status, .failed, "status untouched")
        XCTAssertEqual(step.toolCalls.count, 1, "the create_team record survives")
        XCTAssertEqual(
            step.toolCalls.first?.errorMessage, "AI returned invalid team configuration",
            "the diagnosis the manager needs is still readable")
        XCTAssertNil(
            sut.loadedTask(taskID)?.runs.last?.roleStatuses[generationStepID],
            "no phantom role entry was written")
    }

    func testRestartRole_onAGenerationStepID_surfacesAnActionableError() async {
        guard let taskID = await seedTaskWithGenerationStep() else { return }

        await sut.restartRole(taskID: taskID, roleID: generationStepID, comment: nil)

        let message = sut.lastErrorMessage ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("isn't a role"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("retry"), message)
    }

    /// The refusal is the FIRST statement, before `ensureTaskLoaded` and before any
    /// engine is woken — a restart that cannot happen must not leave an engine behind.
    func testRestartRole_onAGenerationStepID_doesNotWakeAnEngine() async {
        guard let taskID = await seedTaskWithGenerationStep() else { return }

        await sut.restartRole(taskID: taskID, roleID: generationStepID, comment: nil)

        XCTAssertNil(sut.taskEngineStates[taskID])
    }

    /// Non-regression: an ordinary role still restarts.
    func testRestartRole_onARealRole_stillResetsTheStep() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }
        let roleID = "software_engineer"
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0)
            run.steps = [
                StepExecution(
                    id: roleID, role: .softwareEngineer, title: "Engineer", status: .done,
                    toolCalls: [StepToolCall(name: ToolNames.readFile, argumentsJSON: "{}")])
            ]
            run.roleStatuses = [roleID: .done]
            task.runs = [run]
        }

        await sut.restartRole(taskID: taskID, roleID: roleID, comment: "again please")

        let step = sut.loadedTask(taskID)?.runs.last?.steps.first(where: { $0.id == roleID })
        XCTAssertEqual(step?.status, .pending, "a real role is still reset")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses[roleID], .idle)
    }

    // MARK: - Helpers

    private func seedTaskWithGenerationStep() async -> Int? {
        await sut.openWorkFolder(tempDir)
        await sut.mutateWorkFolder { project in
            guard !project.teams.contains(where: { $0.isGeneratedPlaceholder }) else { return }
            project.teams.append(TeamTemplateFactory.generatedTeam())
        }
        guard let template = sut.workFolder?.teams.first(where: { $0.isGeneratedPlaceholder }),
              let taskID = await sut.createTask(
                  title: "Gen", supervisorTask: "build it", preferredTeamID: template.id)
        else { XCTFail("setup failed"); return nil }

        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: template.id)
            run.steps = [
                StepExecution(
                    id: self.generationStepID, role: .supervisor, title: "Generate Team",
                    status: .failed,
                    toolCalls: [
                        StepToolCall(
                            name: ToolNames.createTeam, argumentsJSON: "{}",
                            resultJSON:
                            #"{"ok":false,"error":{"code":"GENERATION_FAILED","message":"AI returned invalid team configuration"}}"#,
                            isError: true)
                    ])
            ]
            run.roleStatuses = ["supervisor": .done]
            task.runs = [run]
        }
        return taskID
    }
}
