import XCTest
@testable import NanoTeams

/// `folder_id` on the external surface, as an agent meets it — found in a live External Autovisor
/// session on 2026-11-08 and verified against the code by two reviewers:
///
/// 1. a missing `folder_id` came back as a bare "Missing required parameter: folder_id" with no
///    next call, and nothing said where the value comes from;
/// 2. an id from another folder answered "The work folder changed while this action was
///    running…" — a race that had not happened;
/// 3. the server's own `next` hints carried no `folder_id` and a string `task_id`, so the agent
///    that followed one verbatim, as the instructions tell it to, was refused.
@MainActor
final class ExternalAutovisorFolderIDTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "eeeeeeee-1111-2222-3333-444444444445")!,
        label: "Claude Code"
    )
    private let foreignFolderID = "BBBBBBBB-9999-8888-7777-666666666666"

    private func openReadyExternalFolder() async throws -> String {
        await sut.openWorkFolder(tempDir)
        if let nonChat = sut.snapshot?.workFolder.teams.first(where: { !$0.isChatMode && !$0.isHiddenFromPickers }) {
            await sut.mutateWorkFolder { $0.setActiveTeam(nonChat.id) }
        }
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        return try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    private struct Reply {
        let isError: Bool
        let json: String
        let envelope: [String: Any]
        var code: String? { (envelope["error"] as? [String: Any])?["code"] as? String }
        var message: String { (envelope["error"] as? [String: Any])?["message"] as? String ?? "" }
        var next: [String: Any]? { envelope["next"] as? [String: Any] }
        var nextArgs: [String: Any]? { next?["suggested_args"] as? [String: Any] }
    }

    private func call(_ tool: String, _ args: [String: Any]) async throws -> Reply {
        let result = await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agent)
        let data = try XCTUnwrap(result.outputJSON.data(using: .utf8))
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Reply(isError: result.isError, json: result.outputJSON, envelope: envelope)
    }

    /// The `next` hint's arguments exactly as an agent's client would send them back: through the
    /// wire's own JSON values and the tool host's conversion.
    private func argumentsAsSent(from reply: Reply) throws -> [String: Any] {
        let envelope = try XCTUnwrap(JSONValue(json: reply.json))
        let args = try XCTUnwrap(envelope["next"]?["suggested_args"]?.objectValue, reply.json)
        return HostedMCPToolHost.toNativeArguments(args)
    }

    /// The Startup team and one step — `r` — whose role status is `roleStatus`, owned by the agent.
    private func createAgentTask(roleStatus: RoleExecutionStatus, extraWorkingRole: Bool = false) async throws -> Int {
        let startupID = try XCTUnwrap(sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" })?.id)
        let created = await sut.createTask(
            title: "Build X", supervisorTask: "do X", preferredTeamID: startupID,
            makeActive: false, origin: .externalAgent(agent))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        await sut.mutateTask(taskID: taskID) { task in
            var steps = [StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .done)]
            var statuses: [String: RoleExecutionStatus] = ["r": roleStatus]
            if extraWorkingRole {
                steps.append(StepExecution(id: "s", role: .codeReviewer, title: "Reviewer", status: .running))
                statuses["s"] = .working
            }
            task.runs = [Run(id: 0, steps: steps, roleStatuses: statuses)]
        }
        return taskID
    }

    private func assertPointsAtFolderStatus(_ reply: Reply, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reply.next?["suggested_cmd"] as? String, ExternalAutovisorToolNames.folderStatus,
                       reply.json, file: file, line: line)
    }

    // MARK: - 1. Missing folder_id

    func testAWriteWithoutFolderID_isInvalidArgsNamingWhereItComesFrom_andPointsAtFolderStatus() async throws {
        _ = try await openReadyExternalFolder()
        let tasksBefore = sut.snapshot?.tasksIndex.tasks.count

        let reply = try await call(ExternalAutovisorToolNames.createManagedTask, ["brief": "Write a script"])

        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.code, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(reply.message, ExternalFolderRefusal.missingFolderID.message)
        XCTAssertTrue(reply.message.contains("folder_status"), reply.message)
        assertPointsAtFolderStatus(reply)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, tasksBefore, "nothing was created")
    }

    func testAReadWithoutFolderID_getsTheSameRefusal() async throws {
        _ = try await openReadyExternalFolder()

        for tool in [ExternalAutovisorToolNames.taskStatus, ExternalAutovisorToolNames.taskResult] {
            let reply = try await call(tool, ["task_id": 0])
            XCTAssertEqual(reply.code, ToolErrorCode.invalidArgs.rawValue, tool)
            XCTAssertEqual(reply.message, ExternalFolderRefusal.missingFolderID.message, tool)
            assertPointsAtFolderStatus(reply)
        }
    }

    // MARK: - 2. An id that is not the open folder

    func testAFolderIDFromAnotherFolder_isRefusedForWhatItIs_notAsARace() async throws {
        _ = try await openReadyExternalFolder()
        let taskID = try await createAgentTask(roleStatus: .done)

        let write = try await call(
            ExternalAutovisorToolNames.controlTask,
            ["folder_id": foreignFolderID, "task_id": taskID, "action": "rename", "arg": "Renamed"])
        let read = try await call(ExternalAutovisorToolNames.taskStatus, ["folder_id": foreignFolderID, "task_id": taskID])
        let optional = try await call(ExternalAutovisorToolNames.listTasks, ["folder_id": foreignFolderID])

        for reply in [write, read, optional] {
            XCTAssertTrue(reply.isError, reply.json)
            XCTAssertEqual(reply.code, ToolErrorCode.invalidArgs.rawValue, reply.json)
            XCTAssertEqual(reply.message, ExternalFolderRefusal.notTheOpenFolder.message)
            XCTAssertFalse(reply.message.contains("changed while"), "no race happened: \(reply.message)")
            assertPointsAtFolderStatus(reply)
        }
        XCTAssertEqual(sut.loadedTask(taskID)?.title, "Build X", "the refused write touched nothing")
    }

    /// The open folder's id is accepted in any letter case, and an omitted optional one is fine.
    func testTheOpenFolderIsAcceptedInAnyCase_andAnOptionalOneMayBeOmitted() async throws {
        let folderID = try await openReadyExternalFolder()

        let lowercased = try await call(ExternalAutovisorToolNames.listTasks, ["folder_id": folderID.lowercased()])
        let omittedTasks = try await call(ExternalAutovisorToolNames.listTasks, [:])
        let omittedTeams = try await call(ExternalAutovisorToolNames.listTeams, [:])
        for reply in [lowercased, omittedTasks, omittedTeams] {
            XCTAssertFalse(reply.isError, reply.json)
        }
    }

    // MARK: - No folder open, and a real change during the call

    func testAReadWithNoFolderOpen_saysNoFolderIsOpen_notThatOneChanged() async throws {
        XCTAssertFalse(sut.hasRealWorkFolder, "precondition: nothing opened")

        let status = try await call(ExternalAutovisorToolNames.taskStatus, ["folder_id": foreignFolderID, "task_id": 0])
        let teams = try await call(ExternalAutovisorToolNames.listTeams, [:])

        for reply in [status, teams] {
            XCTAssertEqual(reply.code, ToolErrorCode.commandFailed.rawValue, reply.json)
            XCTAssertEqual(reply.message, ExternalFolderRefusal.noWorkFolder.message)
            XCTAssertNotEqual(reply.message, DeferredCallReplies.folderChanged)
        }
    }

    /// The race wording is kept for the case it describes: the folder the call began in is no
    /// longer the one open.
    func testAValidationAfterTheFolderChanged_keepsTheRaceReply() async throws {
        _ = try await openReadyExternalFolder()
        let lifecycleOfTheCall = sut.currentFolderLifecycle

        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMSExtFolderID-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondDir) }
        await sut.openWorkFolder(secondDir)
        let openNow = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)

        switch sut.validateActiveFolderID(from: ["folder_id": openNow], required: true, within: lifecycleOfTheCall) {
        case .success:
            XCTFail("a call whose folder changed under it must not go on")
        case .failure(let refusal):
            XCTAssertEqual(refusal, .changedDuringCall)
        }
    }

    // MARK: - 3. The server's own hints, followed verbatim

    func testTaskStatusOnAReviewReadyTask_hintsTheCloseWithTheFolderAndAnIntegerTaskID() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask(roleStatus: .done)
        XCTAssertTrue(sut.loadedTask(taskID)?.isReadyForFinalAcceptance ?? false, "precondition: review-ready")

        let reply = try await call(ExternalAutovisorToolNames.taskStatus, ["folder_id": folderID, "task_id": taskID])

        XCTAssertFalse(reply.isError, reply.json)
        XCTAssertEqual(reply.next?["suggested_cmd"] as? String, ExternalAutovisorToolNames.controlTask)
        let args = try XCTUnwrap(reply.nextArgs, reply.json)
        XCTAssertEqual(args["folder_id"] as? String, folderID)
        XCTAssertEqual(args["action"] as? String, "close")
        XCTAssertTrue(args["task_id"] is NSNumber, "task_id is an integer in control_task's schema: \(reply.json)")
        XCTAssertEqual((args["task_id"] as? NSNumber)?.intValue, taskID)
    }

    /// `task_result` writes its own envelope with the path index first; the completed hint must
    /// not cost it that order.
    func testTaskResultCloseHint_isCompletedToo_andTheIndexStaysFirst() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask(roleStatus: .done)

        let reply = try await call(ExternalAutovisorToolNames.taskResult, ["folder_id": folderID, "task_id": taskID])

        XCTAssertFalse(reply.isError, reply.json)
        let args = try XCTUnwrap(reply.nextArgs, reply.json)
        XCTAssertEqual(args["folder_id"] as? String, folderID)
        XCTAssertEqual((args["task_id"] as? NSNumber)?.intValue, taskID)
        let dataStart = try XCTUnwrap(reply.json.range(of: #""data":{"#))
        let indexAt = try XCTUnwrap(reply.json.range(of: #""index":"#))
        let deliverablesAt = try XCTUnwrap(reply.json.range(of: #""deliverables":"#))
        XCTAssertLessThan(dataStart.lowerBound, indexAt.lowerBound)
        XCTAssertLessThan(indexAt.lowerBound, deliverablesAt.lowerBound, "the index must stay ahead of the contents")
    }

    /// The defect itself: the hint, sent back exactly as it came, does what it says.
    func testFollowingTheCloseHintVerbatim_closesTheTask() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask(roleStatus: .done)
        let status = try await call(ExternalAutovisorToolNames.taskStatus, ["folder_id": folderID, "task_id": taskID])
        let command = try XCTUnwrap(status.next?["suggested_cmd"] as? String, status.json)

        let followed = try await call(command, try argumentsAsSent(from: status))

        XCTAssertFalse(followed.isError, "the hint was refused: \(followed.json)")
        XCTAssertNotNil(sut.loadedTask(taskID)?.closedAt, "control_task close did not close the task")
    }

    /// A refused `manage_role accept` hands back the call to make instead; that one is followable
    /// too.
    func testARejectedAcceptHintsACallThatCanBeFollowedVerbatim() async throws {
        let folderID = try await openReadyExternalFolder()
        let taskID = try await createAgentTask(roleStatus: .done, extraWorkingRole: true)
        XCTAssertFalse(sut.loadedTask(taskID)?.isReadyForFinalAcceptance ?? true, "precondition: another role still works")

        let refused = try await call(
            ExternalAutovisorToolNames.manageRole,
            ["folder_id": folderID, "task_id": taskID, "role_id": "r", "action": "accept"])

        XCTAssertTrue(refused.isError, refused.json)
        XCTAssertEqual(refused.next?["suggested_cmd"] as? String, ExternalAutovisorToolNames.taskStatus)
        let args = try XCTUnwrap(refused.nextArgs, refused.json)
        XCTAssertEqual(args["folder_id"] as? String, folderID)
        XCTAssertEqual((args["task_id"] as? NSNumber)?.intValue, taskID)

        let followed = try await call(ExternalAutovisorToolNames.taskStatus, try argumentsAsSent(from: refused))
        XCTAssertFalse(followed.isError, followed.json)
    }

    /// A folder refusal's own hint names a tool that takes no `folder_id`, so nothing is filled —
    /// and a call that proved no folder could not have supplied one anyway.
    func testAFolderRefusalsHintIsLeftAsItIs() async throws {
        _ = try await openReadyExternalFolder()

        let reply = try await call(ExternalAutovisorToolNames.taskStatus, ["folder_id": foreignFolderID, "task_id": 0])

        XCTAssertNil(reply.nextArgs, reply.json)
    }
}
