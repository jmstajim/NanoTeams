import XCTest
@testable import NanoTeams

/// Every refusal an external agent gets names its cause as a code, with what it needs to act in
/// `details` and the call to make in `next` (2026-11-09, #387). Until then nearly all of them were
/// `COMMAND_FAILED` and the agent told a stale task id from a spent creation window by reading
/// prose:
/// - `TASK_NOT_FOUND` → `list_tasks`; `NOT_OWNER` → `task_status`, which answers for any task (F6 L1);
/// - `AUTOVISOR_OFF` carries the readiness state and sends to `folder_status`;
/// - `LIMIT_REACHED` names the limit, its value and, for the window, when it reopens;
/// - `TEAM_REFUSED` → `list_teams`; `ROLE_NOT_FOUND`; `NOT_WAITING` → `task_log`;
/// - `read_artifact` takes the file name and the slug, and a miss lists what there is;
/// - another agent's task in Review is not offered to this one to close.
@MainActor
final class ExternalAutovisorErrorCodeTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agentA = AgentIdentity(
        id: UUID(uuidString: "dddddddd-1111-2222-3333-444444444441")!,
        label: "Claude Code"
    )

    // MARK: - Fixtures

    private func openExternalFolder() async throws -> String {
        await sut.openWorkFolder(tempDir)
        if let nonChat = sut.snapshot?.workFolder.teams.first(where: { !$0.isChatMode && !$0.isHiddenFromPickers }) {
            await sut.mutateWorkFolder { $0.setActiveTeam(nonChat.id) }
        }
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        return try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    private func call(_ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
        let result = await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agentA)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(result.isError, envelope["ok"] as? Bool == false, result.outputJSON)
        return envelope
    }

    private struct Refusal {
        let code: String
        let message: String
        let details: [String: String]
        let nextCommand: String?
        let nextArgs: [String: Any]?
    }

    private func refusal(_ envelope: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> Refusal {
        XCTAssertEqual(envelope["ok"] as? Bool, false, "\(envelope)", file: file, line: line)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any], "\(envelope)", file: file, line: line)
        let next = envelope["next"] as? [String: Any]
        return Refusal(
            code: error["code"] as? String ?? "",
            message: error["message"] as? String ?? "",
            details: error["details"] as? [String: String] ?? [:],
            nextCommand: next?["suggested_cmd"] as? String,
            nextArgs: next?["suggested_args"] as? [String: Any])
    }

    /// An agent's task with one step running and nothing to answer.
    private func runningOwnTask() async throws -> Int {
        let created = await sut.createTask(
            title: "Own", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working]
            )]
        }
        return taskID
    }

    /// A task whose every role is done — Review, the one state `task_status` offers a close in.
    private func moveToReview(_ taskID: Int) async {
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .done)],
                roleStatuses: ["supervisor": .done, "eng": .done]
            )]
        }
    }

    // MARK: - TASK_NOT_FOUND / NOT_OWNER

    func testTaskStatus_unknownTask_isTaskNotFound_withListTasksNext() async throws {
        let folderID = try await openExternalFolder()
        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.taskStatus, ["folder_id": folderID, "task_id": 4242]))
        XCTAssertEqual(refused.code, "TASK_NOT_FOUND")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.listTasks)
    }

    func testWrite_unknownTask_isTaskNotFound_withListTasksNext() async throws {
        let folderID = try await openExternalFolder()
        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.controlTask,
            ["folder_id": folderID, "task_id": 4242, "action": "pause"]))
        XCTAssertEqual(refused.code, "TASK_NOT_FOUND")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.listTasks)
    }

    func testWrite_personsTask_isNotOwner_withTaskStatusNext() async throws {
        let folderID = try await openExternalFolder()
        let createdByPerson = await sut.createTask(
            title: "Mine, says the person", supervisorTask: "Brief", makeActive: false)
        let personsTask = try XCTUnwrap(createdByPerson)
        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.controlTask,
            ["folder_id": folderID, "task_id": personsTask, "action": "pause"]))
        XCTAssertEqual(refused.code, "NOT_OWNER")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskStatus, "it answers for another's task too")
    }

    // MARK: - AUTOVISOR_OFF

    func testWrite_autovisorSwitchedOff_isAutovisorOff_withReadiness_andFolderStatusNext() async throws {
        let folderID = try await openExternalFolder()
        _ = await sut.setAutovisorEnabled(false)
        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.createManagedTask,
            ["folder_id": folderID, "title": "Blocked", "brief": "Should not be created"]))
        XCTAssertEqual(refused.code, "AUTOVISOR_OFF")
        XCTAssertEqual(refused.details["readiness"], "autovisor_disabled")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.folderStatus)
    }

    /// Both "off" states are `AUTOVISOR_OFF`; a folder that is opening or absent is not the
    /// Autovisor being off and keeps the code `ExternalFolderRefusal` answers it with.
    func testReadinessRefusal_codesEachRefusingState() throws {
        for state in ExternalAutovisorReadiness.State.allCases {
            guard let refusalCase = state.refusal else {
                XCTAssertEqual(state, .ready)
                continue
            }
            let result = NTMSOrchestrator.readinessRefusalResult(
                state: state, refusal: refusalCase, toolName: "control_task", args: [:])
            let envelope = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
            let refused = try refusal(envelope)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(refused.message, refusalCase.message, "the sentence did not change: \(state)")
            switch state {
            case .autovisorDisabled, .builtInDriver:
                XCTAssertEqual(refused.code, "AUTOVISOR_OFF", "\(state)")
                XCTAssertEqual(refused.details["readiness"], state.rawValue)
                XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.folderStatus)
            case .folderTransition, .folderInUse, .noWorkFolder:
                XCTAssertEqual(refused.code, "COMMAND_FAILED", "\(state)")
                XCTAssertTrue(refused.details.isEmpty)
                XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.folderStatus, "\(state)")
            case .ready:
                XCTFail("ready refuses nothing")
            }
        }
    }

    // MARK: - LIMIT_REACHED

    func testCreate_windowSpent_isLimitReached_namingTheWindowAndWhenItReopens() async throws {
        let folderID = try await openExternalFolder()
        var tuning = AutovisorTuning.default
        tuning.maxConcurrentManagedTasks = 5
        tuning.maxOpenExternalTasks = 5
        tuning.maxExternalCreationsPerWindow = 1
        tuning.externalCreationWindowMinutes = 15
        await sut.updateAutovisorTuning(tuning)

        let before = Date()
        let first = try await call(
            ExternalAutovisorToolNames.createManagedTask,
            ["folder_id": folderID, "title": "One", "brief": "First"])
        XCTAssertEqual(first["ok"] as? Bool, true, "\(first)")

        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.createManagedTask,
            ["folder_id": folderID, "title": "Two", "brief": "Second"]))
        XCTAssertEqual(refused.code, "LIMIT_REACHED")
        XCTAssertEqual(refused.details["limit"], "window")
        XCTAssertEqual(refused.details["max"], "1")
        XCTAssertEqual(refused.details["window_minutes"], "15")
        let retryAt = try XCTUnwrap(
            refused.details["retry_at"].flatMap { JSONCoderFactory.iso8601Formatter.date(from: $0) },
            "\(refused.details)")
        XCTAssertGreaterThan(retryAt, before.addingTimeInterval(14 * 60), "the first creation ages out ~15 min on")
        XCTAssertLessThan(retryAt, Date().addingTimeInterval(15 * 60 + 5))
    }

    func testCreate_openTasksAtTheirCap_isLimitReached_namingCountAndMax() async throws {
        let folderID = try await openExternalFolder()
        var tuning = AutovisorTuning.default
        tuning.maxConcurrentManagedTasks = 5
        tuning.maxOpenExternalTasks = 1
        tuning.maxExternalCreationsPerWindow = 5
        await sut.updateAutovisorTuning(tuning)

        let first = try await call(
            ExternalAutovisorToolNames.createManagedTask,
            ["folder_id": folderID, "title": "One", "brief": "First"])
        XCTAssertEqual(first["ok"] as? Bool, true, "\(first)")

        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.createManagedTask,
            ["folder_id": folderID, "title": "Two", "brief": "Second"]))
        XCTAssertEqual(refused.code, "LIMIT_REACHED")
        XCTAssertEqual(refused.details["limit"], "open")
        XCTAssertEqual(refused.details["count"], "1")
        XCTAssertEqual(refused.details["max"], "1")
        XCTAssertNil(refused.details["retry_at"], "an open-task slot frees on a close, not at a time")
    }

    func testWindowReopensAt_isTheOldestCreationInTheWindowPlusTheWindow() throws {
        var ledger = AutovisorCreationLedger()
        var tuning = AutovisorTuning.default
        tuning.maxExternalCreationsPerWindow = 10
        tuning.maxOpenExternalTasks = 10
        tuning.maxConcurrentManagedTasks = 10
        let actor = AutovisorActor.externalAgent(agentA)
        let t0 = Date(timeIntervalSince1970: 1_799_971_200)

        XCTAssertNil(ledger.externalWindowReopensAt(for: agentA.id, windowMinutes: 15, now: t0),
                     "an empty window has nothing to wait for")

        for offset in [0.0, 300.0, 600.0] {
            let reserved = try ledger.tryReserveSlot(
                for: actor, tuning: tuning, runningCount: 0, openExternalCount: 0,
                now: t0.addingTimeInterval(offset)).get()
            ledger.commit(reserved, now: t0.addingTimeInterval(offset))
        }
        XCTAssertEqual(
            ledger.externalWindowReopensAt(for: agentA.id, windowMinutes: 15, now: t0.addingTimeInterval(700)),
            t0.addingTimeInterval(900))
        // The first creation has aged out: the next-oldest decides.
        XCTAssertEqual(
            ledger.externalWindowReopensAt(for: agentA.id, windowMinutes: 15, now: t0.addingTimeInterval(1000)),
            t0.addingTimeInterval(300 + 900))
        XCTAssertNil(
            ledger.externalWindowReopensAt(for: UUID(), windowMinutes: 15, now: t0.addingTimeInterval(700)),
            "another agent's creations are not this one's window")
        XCTAssertNil(
            ledger.externalWindowReopensAt(for: agentA.id, windowMinutes: 15, now: t0.addingTimeInterval(3600)),
            "every creation aged out")
    }

    // MARK: - TEAM_REFUSED

    func testCreate_unknownTeam_isTeamRefused_withListTeamsNext() async throws {
        let folderID = try await openExternalFolder()
        let tasksBefore = sut.snapshot?.tasksIndex.tasks.count
        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.createManagedTask,
            ["folder_id": folderID, "title": "Where", "brief": "Nowhere", "team_id": "no_such_team"]))
        XCTAssertEqual(refused.code, "TEAM_REFUSED")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.listTeams)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, tasksBefore, "nothing was created")
    }

    // MARK: - ROLE_NOT_FOUND / NOT_WAITING

    func testManageRole_unknownRole_isRoleNotFound() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.manageRole,
            ["folder_id": folderID, "task_id": taskID, "role_id": "ghost", "action": "accept"]))
        XCTAssertEqual(refused.code, "ROLE_NOT_FOUND")
    }

    func testAnswer_taskAskingNothing_isNotWaiting_withTaskLogNext() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.answerTaskQuestion,
            ["folder_id": folderID, "task_id": taskID, "answer": "Use SQLite."]))
        XCTAssertEqual(refused.code, "NOT_WAITING")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskLog)
        // The server completes a hint's arguments to the tool's schema: `task_id` is an integer.
        XCTAssertEqual(refused.nextArgs?["task_id"] as? Int, taskID)
        XCTAssertEqual(refused.nextArgs?["folder_id"] as? String, folderID)
    }

    func testAnswer_namedRoleAskingNothing_isNotWaiting() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let refused = try refusal(try await call(
            ExternalAutovisorToolNames.answerTaskQuestion,
            ["folder_id": folderID, "task_id": taskID, "role_id": "eng", "answer": "Use SQLite."]))
        XCTAssertEqual(refused.code, "NOT_WAITING")
    }

    /// Exhaustive by construction: a refusal the action layer names has its own code, and one it
    /// does not stays `COMMAND_FAILED`.
    func testExternalCode_andNext_forEveryFailure() {
        XCTAssertEqual(NTMSOrchestrator.externalCode(for: .taskNotFound), .taskNotFound)
        XCTAssertEqual(NTMSOrchestrator.externalCode(for: .roleNotFound), .roleNotFound)
        XCTAssertEqual(NTMSOrchestrator.externalCode(for: .notWaiting), .notWaiting)
        XCTAssertEqual(NTMSOrchestrator.externalCode(for: .limitReached), .limitReached)
        XCTAssertEqual(NTMSOrchestrator.externalCode(for: nil), .commandFailed)

        XCTAssertEqual(NTMSOrchestrator.externalNext(for: .notWaiting, taskID: 7).suggested_cmd,
                       ExternalAutovisorToolNames.taskLog)
        XCTAssertEqual(NTMSOrchestrator.externalNext(for: .taskNotFound, taskID: 7).suggested_cmd,
                       ExternalAutovisorToolNames.listTasks)
        XCTAssertEqual(NTMSOrchestrator.externalNext(for: .roleNotFound, taskID: 7).suggested_cmd,
                       ExternalAutovisorToolNames.taskStatus)
        XCTAssertEqual(NTMSOrchestrator.externalNext(for: .limitReached, taskID: 7).suggested_cmd,
                       ExternalAutovisorToolNames.listTasks)
        XCTAssertEqual(NTMSOrchestrator.externalNext(for: nil, taskID: 7).suggested_cmd,
                       ExternalAutovisorToolNames.taskStatus)
    }

    func testReplyFailureKind_mapsTheRepliesAnAgentBranchesOn() {
        XCTAssertEqual(AutovisorReply.taskNotFound(taskID: 1).failureKind, .taskNotFound)
        XCTAssertEqual(AutovisorReply.noSuchRole(taskID: 1, roleID: "x").failureKind, .roleNotFound)
        XCTAssertEqual(AutovisorReply.notWaitingForInput(taskID: 1).failureKind, .notWaiting)
        XCTAssertEqual(AutovisorReply.notWaitingForInputExternal(taskID: 1).failureKind, .notWaiting)
        XCTAssertEqual(AutovisorReply.roleNotWaiting(taskID: 1, roleID: "x", waitingRoleIDs: []).failureKind,
                       .notWaiting)
        XCTAssertEqual(AutovisorReply.tooManyRunning(count: 3).failureKind, .limitReached)
        XCTAssertEqual(AutovisorReply.openTaskLimitReached(count: 1, limit: 1).failureKind, .limitReached)
        XCTAssertEqual(AutovisorReply.creationWindowLimitReached(limit: 1, windowMinutes: 15).failureKind,
                       .limitReached)
        XCTAssertEqual(AutovisorReply.creationLimitReached(limit: 1).failureKind, .limitReached)
    }

    // MARK: - read_artifact

    private func ownTaskWithArtifacts() async throws -> Int {
        let taskID = try await runningOwnTask()
        let specRel = try sut.repository.persistStepArtifactFile(
            at: tempDir, taskID: taskID, runID: 0, roleID: "eng",
            artifactName: "Design Spec", content: "The spec")
        let notesRel = try sut.repository.persistStepArtifactFile(
            at: tempDir, taskID: taskID, runID: 0, roleID: "eng",
            artifactName: "Engineering Notes", content: "The notes")
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].artifacts = [
                Artifact(name: "Design Spec", relativePath: specRel),
                Artifact(name: "Engineering Notes", relativePath: notesRel),
            ]
        }
        return taskID
    }

    private func readArtifact(_ folderID: String, _ taskID: Int, _ name: String, roleID: String? = nil) async throws -> [String: Any] {
        var args: [String: Any] = ["folder_id": folderID, "task_id": taskID, "name": name]
        if let roleID { args["role_id"] = roleID }
        return try await call(ExternalAutovisorToolNames.readArtifact, args)
    }

    /// The file name is what `task_result` lists under `path`; until 2026-11-09 asking by it was
    /// answered "not found".
    func testReadArtifact_acceptsTheNameTheFileNameAndTheSlug() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownTaskWithArtifacts()
        for asked in ["Design Spec", "artifact_design_spec.md", "design_spec", "design spec", "DESIGN SPEC"] {
            let envelope = try await readArtifact(folderID, taskID, asked)
            XCTAssertEqual(envelope["ok"] as? Bool, true, "\(asked): \(envelope)")
            let data = try XCTUnwrap(envelope["data"] as? [String: Any])
            XCTAssertEqual(data["content"] as? String, "The spec", asked)
        }
    }

    func testReadArtifact_missingName_isArtifactNotFound_listingWhatThereIs() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownTaskWithArtifacts()
        let refused = try refusal(try await readArtifact(folderID, taskID, "Release Notes"))
        XCTAssertEqual(refused.code, "ARTIFACT_NOT_FOUND")
        XCTAssertEqual(refused.details["available"], "Design Spec, Engineering Notes")
    }

    func testReadArtifact_roleTheRunDoesNotHave_isRoleNotFound_namingTheRolesWithArtifacts() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownTaskWithArtifacts()
        let refused = try refusal(try await readArtifact(folderID, taskID, "Design Spec", roleID: "ghost"))
        XCTAssertEqual(refused.code, "ROLE_NOT_FOUND")
        XCTAssertEqual(refused.details["roles_with_artifacts"], "eng")

        let found = try await readArtifact(folderID, taskID, "Design Spec", roleID: "eng")
        XCTAssertEqual(found["ok"] as? Bool, true, "\(found)")
    }

    func testReadArtifact_taskThatNeverRan_isArtifactNotFound_withNoneAvailable() async throws {
        let folderID = try await openExternalFolder()
        let created = await sut.createTask(
            title: "Never ran", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA))
        let taskID = try XCTUnwrap(created)
        let refused = try refusal(try await readArtifact(folderID, taskID, "Design Spec"))
        XCTAssertEqual(refused.code, "ARTIFACT_NOT_FOUND")
        XCTAssertEqual(refused.details["available"], "(none)")
    }

    func testArtifactIsNamed_cornerCases() {
        let spec = Artifact(name: "Design Spec", relativePath: "tasks/1/runs/0/roles/eng/artifact_design_spec.md")
        XCTAssertTrue(NTMSOrchestrator.artifact(spec, isNamed: "Design Spec"))
        XCTAssertTrue(NTMSOrchestrator.artifact(spec, isNamed: "artifact_design_spec.md"))
        XCTAssertTrue(NTMSOrchestrator.artifact(spec, isNamed: "design_spec"))
        XCTAssertFalse(NTMSOrchestrator.artifact(spec, isNamed: "Design"))
        XCTAssertFalse(NTMSOrchestrator.artifact(spec, isNamed: "tasks/1/runs/0/roles/eng/artifact_design_spec.md"),
                       "a path is not a name")

        let unsaved = Artifact(name: "Design Spec", relativePath: nil)
        XCTAssertTrue(NTMSOrchestrator.artifact(unsaved, isNamed: "design spec"))
        XCTAssertFalse(NTMSOrchestrator.artifact(unsaved, isNamed: "artifact_design_spec.md"))

        let punctuation = Artifact(name: "???", relativePath: nil)
        XCTAssertTrue(NTMSOrchestrator.artifact(punctuation, isNamed: "???"), "the exact name still matches")
        XCTAssertFalse(NTMSOrchestrator.artifact(punctuation, isNamed: "!!!"), "two empty slugs are not a match")
    }

    func testUniqueInOrder_keepsTheFirstOccurrence() {
        XCTAssertEqual(NTMSOrchestrator.uniqueInOrder([]), [])
        XCTAssertEqual(NTMSOrchestrator.uniqueInOrder(["b", "a", "b", "c", "a"]), ["b", "a", "c"])
    }

    // MARK: - The close hint

    func testTaskStatus_inReview_offersCloseToTheOwnerOnly() async throws {
        let folderID = try await openExternalFolder()
        let ownTask = try await runningOwnTask()
        await moveToReview(ownTask)
        let createdByPerson = await sut.createTask(
            title: "The person's", supervisorTask: "Brief", makeActive: false)
        let personsTask = try XCTUnwrap(createdByPerson)
        await sut.ensureTaskLoaded(personsTask)
        await moveToReview(personsTask)

        let own = try await call(ExternalAutovisorToolNames.taskStatus, ["folder_id": folderID, "task_id": ownTask])
        XCTAssertEqual((own["next"] as? [String: Any])?["suggested_cmd"] as? String,
                       ExternalAutovisorToolNames.controlTask, "\(own)")

        let foreign = try await call(ExternalAutovisorToolNames.taskStatus, ["folder_id": folderID, "task_id": personsTask])
        XCTAssertEqual(foreign["ok"] as? Bool, true, "status is readable on any task")
        XCTAssertTrue(foreign["next"] == nil || foreign["next"] is NSNull,
                      "the close would be refused NOT_OWNER: \(foreign)")
    }
}
