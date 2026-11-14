import XCTest
@testable import NanoTeams

/// Byte-for-byte golden pin for every envelope returned by the 10 mandatory built-in
/// Autovisor tools (`AutovisorConstants.managerMandatoryToolIDs`) and their key failure
/// branches, evaluated against a deterministic fixture with an injected clock (`now:`).
///
/// Guards Ш10 (`AutovisorCommandExecutor` extraction): moving the execution path onto
/// the shared command layer must not shift a single byte seen by the local model.
@MainActor
final class InAppAutovisorWireCompatibilityTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let fixedBaseDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var fixedNow: Date { fixedBaseDate.addingTimeInterval(42) }

    func testAllTenBuiltInAutovisorTools_produceExactGoldenWireEnvelopes() async throws {
        await sut.openWorkFolder(tempDir)
        let rawMgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)
        let mgrID = try XCTUnwrap(rawMgrID)
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = mgrID }
        let startupTeam = try XCTUnwrap(
            sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })
        )

        let service = sut.llmExecutionService

        // Seed a deterministic task (#1) with a known updatedAt, run, step, and pending question.
        let rawTaskID = await sut.createTask(
            title: "Seeded Task",
            supervisorTask: "Implement feature X",
            preferredTeamID: startupTeam.id,
            makeActive: false
        )
        let taskID = try XCTUnwrap(rawTaskID)
        await sut.ensureTaskLoaded(taskID)
        let roleID = try XCTUnwrap(startupTeam.nonSupervisorRoles.first?.id)
        let stepCreatedAt = fixedBaseDate
        await sut.mutateTask(taskID: taskID) { task in
            task.createdAt = self.fixedBaseDate
            task.updatedAt = self.fixedBaseDate
            let askCall = StepToolCall(
                createdAt: stepCreatedAt,
                name: ToolNames.askSupervisor,
                argumentsJSON: #"{"question":"Which endpoint should we target?"}"#,
                resultJSON: #"{"data":{"question":"Which endpoint should we target?","status":"pending"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#,
                isError: false
            )
            let step = StepExecution(
                id: roleID,
                role: .softwareEngineer,
                title: "Engineer",
                status: .needsSupervisorInput,
                createdAt: stepCreatedAt,
                updatedAt: stepCreatedAt,
                toolCalls: [askCall],
                supervisorQuestion: "Which endpoint should we target?"
            )
            let run = Run(
                id: 0,
                createdAt: stepCreatedAt,
                updatedAt: stepCreatedAt,
                steps: [step],
                roleStatuses: [roleID: .working],
                teamID: startupTeam.id
            )
            task.runs = [run]
        }
        // Mirror fixed updatedAt into the tasksIndex summary row.
        if var snap = sut.snapshot,
           let idx = snap.tasksIndex.tasks.firstIndex(where: { $0.id == taskID }) {
            snap.tasksIndex.tasks[idx].updatedAt = fixedBaseDate
            sut.apply(snap, settings: .adopt)
        }

        // 1. list_tasks (with injected clock: 42 seconds elapsed since fixedBaseDate)
        let listTasksEnvelope = await service.handleListTasks(now: fixedNow)
        XCTAssertEqual(
            listTasksEnvelope,
            #"{"data":{"tasks":[{"chat_mode":false,"id":\#(taskID),"pending_question_count":1,"status":"needsSupervisorInput","title":"Seeded Task","updated_seconds_ago":42,"waiting_for_supervisor":true}]},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )

        // 2. task_status (success + not-found error)
        let taskStatusEnvelope = await service.handleTaskStatus(taskID: taskID, now: fixedNow)
        XCTAssertEqual(
            taskStatusEnvelope,
            #"{"data":{"artifacts":[],"chat_mode":false,"elapsed_seconds":42,"pending_question":"Which endpoint should we target?","pending_questions":[{"question":"Which endpoint should we target?","role_id":"\#(roleID)"}],"status":"needsSupervisorInput","steps":[{"elapsed_seconds":42,"message_count":0,"role_id":"\#(roleID)","role_kind":"producing","status":"needsSupervisorInput","tool_call_count":1}],"task_id":\#(taskID),"timed_out":false,"title":"Seeded Task"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )
        let taskStatusMissingEnvelope = await service.handleTaskStatus(taskID: 9999, now: fixedNow)
        XCTAssertEqual(
            taskStatusMissingEnvelope,
            #"{"error":{"code":"COMMAND_FAILED","message":"Task #9999 not found."},"meta":{"truncated":false,"warnings":[]},"ok":false}"#
        )

        _ = sut.engineState.beginRunStart(taskID)
        defer { sut.engineState.endRunStart(taskID) }

        // 3. answer_task_question (success on waiting task + noPendingQuestion once answered)
        let answeredEnvelope = await service.handleAnswerTaskQuestion(taskID: taskID, answer: "Use v2")
        XCTAssertEqual(
            answeredEnvelope,
            #"{"data":{"message":"Answered task #\#(taskID).","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )
        let noQuestionEnvelope = await service.handleAnswerTaskQuestion(taskID: taskID, answer: "Use v2")
        XCTAssertEqual(
            noQuestionEnvelope,
            #"{"error":{"code":"COMMAND_FAILED","message":"Task #\#(taskID) is not waiting for supervisor input."},"meta":{"truncated":false,"warnings":[]},"ok":false}"#
        )

        // 4. message_task (empty message error + queued message)
        let emptyMessageEnvelope = await service.handleMessageTask(taskID: taskID, text: " ", roleID: nil)
        XCTAssertEqual(
            emptyMessageEnvelope,
            #"{"error":{"code":"COMMAND_FAILED","message":"Could not queue message for task #\#(taskID)."},"meta":{"truncated":false,"warnings":[]},"ok":false}"#
        )
        let queuedMessageEnvelope = await service.handleMessageTask(
            taskID: taskID,
            text: "Keep responses concise",
            roleID: roleID
        )
        XCTAssertEqual(
            queuedMessageEnvelope,
            #"{"data":{"message":"Queued message for paused task #\#(taskID) and resumed the current run to deliver it.","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )

        // 5. schedule_task (set schedule + clear schedule)
        let scheduleSetEnvelope = await service.handleScheduleTask(taskID: taskID, intervalMinutes: 15)
        XCTAssertEqual(
            scheduleSetEnvelope,
            #"{"data":{"message":"Task #\#(taskID) will now run every 15 min.","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )
        let scheduleClearEnvelope = await service.handleScheduleTask(taskID: taskID, intervalMinutes: 0)
        XCTAssertEqual(
            scheduleClearEnvelope,
            #"{"data":{"message":"Cleared schedule for task #\#(taskID).","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )

        // 6. set_work_folder_context
        let setContextEnvelope = await service.handleSetWorkFolderContext(content: "Repo uses Swift 6.")
        XCTAssertEqual(
            setContextEnvelope,
            #"{"data":{"message":"Updated the Work Folder Context.","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )

        // 7. manage_role (unknown role error + accept role at gate)
        let unknownRoleEnvelope = await service.handleManageRole(
            taskID: taskID,
            roleID: "nonexistent-role",
            verb: .accept
        )
        XCTAssertEqual(
            unknownRoleEnvelope,
            #"{"error":{"code":"COMMAND_FAILED","message":"Task #\#(taskID) has no role 'nonexistent-role' — call task_status for valid role_ids."},"meta":{"truncated":false,"warnings":[]},"ok":false}"#
        )

        // Transition step to .done + .needsAcceptance and accept it via manage_role.
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].status = .done
            task.runs[0].steps[0].supervisorQuestion = nil
            task.runs[0].roleStatuses[roleID] = .needsAcceptance
        }
        let acceptRoleEnvelope = await service.handleManageRole(
            taskID: taskID,
            roleID: roleID,
            verb: .accept
        )
        XCTAssertEqual(
            acceptRoleEnvelope,
            #"{"data":{"message":"Accepted role \#(roleID) on task #\#(taskID).","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )

        // 8. control_task (own-task error + rename + close + already-closed error)
        let ownTaskEnvelope = await service.handleControlTask(taskID: mgrID, verb: .pause)
        XCTAssertEqual(
            ownTaskEnvelope,
            #"{"error":{"code":"COMMAND_FAILED","message":"Refused: the manager cannot act on its own task (#\#(mgrID))."},"meta":{"truncated":false,"warnings":[]},"ok":false}"#
        )
        let renameEnvelope = await service.handleControlTask(
            taskID: taskID,
            verb: .rename(title: "Renamed Seed Task")
        )
        XCTAssertEqual(
            renameEnvelope,
            #"{"data":{"message":"Renamed task #\#(taskID) to \"Renamed Seed Task\".","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )
        let closeEnvelope = await service.handleControlTask(taskID: taskID, verb: .close)
        XCTAssertEqual(
            closeEnvelope,
            #"{"data":{"message":"Closed task #\#(taskID).","status":"ok"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )
        let alreadyClosedEnvelope = await service.handleControlTask(taskID: taskID, verb: .close)
        XCTAssertEqual(
            alreadyClosedEnvelope,
            #"{"error":{"code":"COMMAND_FAILED","message":"Task #\#(taskID) is already closed."},"meta":{"truncated":false,"warnings":[]},"ok":false}"#
        )

        // 9. create_managed_task (unknown team error + createdNotStarted when run start is held)
        let unknownTeamCreateEnvelope = await service.handleCreateManagedTask(
            title: "New Task",
            brief: "Brief",
            teamID: "no-such-team"
        )
        XCTAssertEqual(
            unknownTeamCreateEnvelope,
            #"{"error":{"code":"COMMAND_FAILED","message":"Unknown team_id 'no-such-team'. Instead, pick a team id from the catalog in create_managed_task's description, or use 'generated' to assemble a new team."},"meta":{"truncated":false,"warnings":[]},"ok":false}"#
        )

        let nextCreatedID = sut.snapshot?.tasksIndex.nextTaskID ?? 0
        _ = sut.engineState.beginRunStart(nextCreatedID)
        defer { sut.engineState.endRunStart(nextCreatedID) }
        let createSuccessEnvelope = await service.handleCreateManagedTask(
            title: "Created Task",
            brief: "Do work",
            teamID: startupTeam.id
        )
        XCTAssertEqual(
            createSuccessEnvelope,
            #"{"data":{"message":"Created task #\#(nextCreatedID): Created Task. It did NOT start (no run was created) — call control_task start on #\#(nextCreatedID).","status":"ok","task_id":\#(nextCreatedID)},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )

        // 10. wait_for_events (not-running error + live execution success)
        let waitNotRunningEnvelope = await service.handleWaitForEvents(stepID: "mgr-step", taskID: mgrID)
        XCTAssertEqual(
            waitNotRunningEnvelope,
            #"{"error":{"code":"COMMAND_FAILED","message":"Step is no longer running."},"meta":{"truncated":false,"warnings":[]},"ok":false}"#
        )

        let stepKey = TaskStepKey(taskID: mgrID, stepID: "mgr-step")
        service.executionStates[stepKey] = LLMExecutionService.StepExecutionState()
        defer { service.executionStates.removeValue(forKey: stepKey) }
        let waitSuccessEnvelope = await service.handleWaitForEvents(stepID: "mgr-step", taskID: mgrID)
        XCTAssertEqual(
            waitSuccessEnvelope,
            #"{"data":{"status":"idle — will resume on supervisor message or events"},"meta":{"truncated":false,"warnings":[]},"ok":true}"#
        )
        XCTAssertTrue(service.executionStates[stepKey]?.parkForEventsRequested == true)
    }
}
