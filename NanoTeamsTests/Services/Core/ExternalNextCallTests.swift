import XCTest
@testable import NanoTeams

/// Every refusal an external agent gets carries the call to make next (F6 L1/T2, 2026-11-12).
///
/// The server's instructions say "Refused calls and errors carry a next suggestion; follow it."
/// Until 2026-11-12 the live check found refusals with none: `NOT_OWNER` (by design — "nothing this
/// agent can do"), `FOLDER_CHANGED`, the folder states, `schedule_task`'s four `INVALID_ARGS`,
/// `set_timeout` at or below the run's age, `LIMIT_REACHED` on create and every argument refusal
/// the shared decoder writes. These tests drive each one through `executeExternalAutovisorTool`,
/// the surface the agent reads, and name the call they expect.
@MainActor
final class ExternalNextCallTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agentA = AgentIdentity(
        id: UUID(uuidString: "dddddddd-1111-2222-3333-4444444444e1")!,
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

    private struct Refusal {
        let code: String
        let nextCommand: String?
        let nextArgs: [String: Any]
        let nextReason: String?
    }

    private func refusal(
        _ tool: String, _ args: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Refusal {
        let result = await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agentA)
        XCTAssertTrue(result.isError, result.outputJSON, file: file, line: line)
        return try Self.refusal(of: result.outputJSON, file: file, line: line)
    }

    private static func refusal(
        of json: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Refusal {
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], file: file, line: line)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any], json, file: file, line: line)
        let next = envelope["next"] as? [String: Any]
        return Refusal(
            code: error["code"] as? String ?? "",
            nextCommand: next?["suggested_cmd"] as? String,
            nextArgs: next?["suggested_args"] as? [String: Any] ?? [:],
            nextReason: next?["reason"] as? String)
    }

    private func ownRunningTask(startedSecondsAgo: TimeInterval = 0) async throws -> Int {
        let created = await sut.createTask(
            title: "Own", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                createdAt: MonotonicClock.shared.now().addingTimeInterval(-startedSecondsAgo),
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working]
            )]
        }
        return taskID
    }

    // MARK: - NOT_OWNER: task_status answers for any task

    func testNotOwner_pointsAtTaskStatusForTheSameTask() async throws {
        let folderID = try await openExternalFolder()
        let created = await sut.createTask(title: "The person's", supervisorTask: "Brief", makeActive: false)
        let personsTask = try XCTUnwrap(created)

        for tool in [ExternalAutovisorToolNames.taskLog, ExternalAutovisorToolNames.taskResult] {
            let refused = try await refusal(tool, ["folder_id": folderID, "task_id": personsTask])
            XCTAssertEqual(refused.code, "NOT_OWNER", tool)
            XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskStatus, tool)
            XCTAssertEqual(refused.nextArgs["task_id"] as? Int, personsTask, "the task the call named, as a number")
            XCTAssertEqual(refused.nextArgs["folder_id"] as? String, folderID, "the folder this call proved")
        }
        let write = try await refusal(
            ExternalAutovisorToolNames.controlTask,
            ["folder_id": folderID, "task_id": personsTask, "action": "pause"])
        XCTAssertEqual(write.code, "NOT_OWNER")
        XCTAssertEqual(write.nextCommand, ExternalAutovisorToolNames.taskStatus)
    }

    // MARK: - FOLDER_CHANGED and the folder states

    func testFolderChanged_pointsAtFolderStatus() throws {
        XCTAssertEqual(ExternalAutovisorError.folderChanged.next?.suggested_cmd, ExternalAutovisorToolNames.folderStatus)
        XCTAssertEqual(ExternalFolderRefusal.changedDuringCall.next.suggested_cmd, ExternalAutovisorToolNames.folderStatus)
        let reply = try Self.refusal(of: NTMSOrchestrator.folderChangedReply(toolName: "task_log", args: [:]).outputJSON)
        XCTAssertEqual(reply.code, "FOLDER_CHANGED")
        XCTAssertEqual(reply.nextCommand, ExternalAutovisorToolNames.folderStatus)
    }

    func testEveryFolderRefusal_carriesANextCall() {
        for refusal in ExternalFolderRefusal.allCases {
            XCTAssertEqual(refusal.next.suggested_cmd, ExternalAutovisorToolNames.folderStatus, "\(refusal)")
        }
    }

    func testReadinessRefusal_ofEveryRefusingState_carriesANextCall() throws {
        for state in ExternalAutovisorReadiness.State.allCases {
            guard let refusal = state.refusal else { continue }
            let result = NTMSOrchestrator.readinessRefusalResult(
                state: state, refusal: refusal, toolName: "create_managed_task", args: [:])
            XCTAssertEqual(
                try Self.refusal(of: result.outputJSON).nextCommand, ExternalAutovisorToolNames.folderStatus,
                "\(state)")
        }
    }

    // MARK: - schedule_task INVALID_ARGS

    func testScheduleTask_refusedSchedules_pointAtTaskStatusForTheTask() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let past = JSONCoderFactory.iso8601Formatter.string(from: Date().addingTimeInterval(-3_600))
        let refusedSchedules: [[String: Any]] = [
            ["repeat_weekdays": [1, 2]],                                        // days without a time
            ["run_once_at": past],                                              // in the past
            ["repeat_every_minutes": 0],                                        // interval 0
            ["repeat_every_minutes": 30, "repeat_daily_at": "09:00"],           // two kinds
            [:],                                                                // none at all
        ]
        for schedule in refusedSchedules {
            var args: [String: Any] = ["folder_id": folderID, "task_id": taskID]
            args.merge(schedule) { $1 }
            let refused = try await refusal(ExternalAutovisorToolNames.scheduleTask, args)
            XCTAssertEqual(refused.code, "INVALID_ARGS", "\(schedule)")
            XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskStatus, "\(schedule)")
            XCTAssertEqual(refused.nextArgs["task_id"] as? Int, taskID, "\(schedule)")
        }
    }

    // MARK: - set_timeout at or below the run's age

    func testSetTimeout_atOrBelowElapsed_pointsAtTaskStatus() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask(startedSecondsAgo: 600)
        let refused = try await refusal(
            ExternalAutovisorToolNames.controlTask,
            ["folder_id": folderID, "task_id": taskID, "action": "set_timeout", "timeout_seconds": 60])
        XCTAssertEqual(refused.code, "INVALID_ARGS")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskStatus)
        XCTAssertEqual(refused.nextArgs["task_id"] as? Int, taskID)
    }

    // MARK: - LIMIT_REACHED on create

    func testCreate_limitReached_pointsAtListTasks() async throws {
        let folderID = try await openExternalFolder()
        var tuning = AutovisorTuning.default
        tuning.maxConcurrentManagedTasks = 5
        tuning.maxOpenExternalTasks = 1
        tuning.maxExternalCreationsPerWindow = 5
        await sut.updateAutovisorTuning(tuning)
        let first = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID, "title": "One", "brief": "First"], agent: agentA)
        XCTAssertFalse(first.isError, first.outputJSON)

        let refused = try await refusal(
            ExternalAutovisorToolNames.createManagedTask,
            ["folder_id": folderID, "title": "Two", "brief": "Second"])
        XCTAssertEqual(refused.code, "LIMIT_REACHED")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.listTasks)
    }

    // MARK: - Refusals the shared decoder writes

    /// The decoder is shared with the in-app manager and names no next call; the external surface
    /// adds one on the way out.
    func testSharedDecoderRefusal_carriesANextCall() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let refused = try await refusal(
            ExternalAutovisorToolNames.controlTask,
            ["folder_id": folderID, "task_id": taskID, "action": "explode"])
        XCTAssertEqual(refused.code, "INVALID_ARGS")
        XCTAssertNotNil(refused.nextCommand, "an argument refusal from the shared decoder")
        XCTAssertFalse(refused.nextReason?.isEmpty ?? true)
    }

    // MARK: - The exit seam

    private static func bareRefusal(_ code: ToolErrorCode, details: [String: String]? = nil) -> ToolExecutionResult {
        makeErrorResult(
            toolName: "t", args: [:], code: code, message: "m", details: details,
            meta: ToolResultMeta(warnings: ["w"]))
    }

    /// Every code — the exhaustive switch says the same at compile time — leaves the seam with a
    /// next call that names a hosted tool and says why, with and without a task in the call.
    func testEveryCode_leavesTheSeamWithANextCallNamingAHostedTool() throws {
        for code in ToolErrorCode.allCases {
            for tool in ExternalAutovisorToolNames.all {
                for args in [[:], ["task_id": 7] as [String: Any]] {
                    let ensured = ExternalNextCall.ensuringNext(Self.bareRefusal(code), toolName: tool, args: args)
                    let refused = try Self.refusal(of: ensured.outputJSON)
                    let command = try XCTUnwrap(refused.nextCommand, "\(code) after \(tool)")
                    XCTAssertTrue(ExternalAutovisorToolNames.all.contains(command), "\(code) after \(tool): \(command)")
                    XCTAssertFalse(refused.nextReason?.isEmpty ?? true, "\(code) after \(tool)")
                    XCTAssertEqual(refused.code, code.rawValue, "the code is kept")
                }
            }
        }
    }

    func testEnsuringNext_leavesSuccessesAndNamedRefusalsByteForByte() {
        let success = makeSuccessResult(toolName: "t", args: [:], data: ["a": "b"])
        XCTAssertEqual(ExternalNextCall.ensuringNext(success, toolName: "t", args: [:]).outputJSON, success.outputJSON)

        let named = makeErrorResult(
            toolName: "t", args: [:], code: .invalidArgs, message: "m",
            next: NextHint(suggested_cmd: "list_teams", suggested_args: nil, reason: "r"))
        XCTAssertEqual(ExternalNextCall.ensuringNext(named, toolName: "t", args: [:]).outputJSON, named.outputJSON)

        // `isError` with text that is no envelope: nothing to add a member to.
        let opaque = ToolExecutionResult(toolName: "t", argumentsJSON: "{}", outputJSON: "not json", isError: true)
        XCTAssertEqual(ExternalNextCall.ensuringNext(opaque, toolName: "t", args: [:]).outputJSON, "not json")
    }

    /// The rewrite adds `next` and keeps the rest: code, message, details, meta, `ok`.
    func testEnsuringNext_keepsTheRestOfTheEnvelope() throws {
        let ensured = ExternalNextCall.ensuringNext(
            Self.bareRefusal(.notWaiting, details: ["k": "v"]),
            toolName: ExternalAutovisorToolNames.answerTaskQuestion, args: ["task_id": "12"])
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ensured.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "NOT_WAITING")
        XCTAssertEqual(error["message"] as? String, "m")
        XCTAssertEqual(error["details"] as? [String: String], ["k": "v"])
        XCTAssertEqual((envelope["meta"] as? [String: Any])?["warnings"] as? [String], ["w"])
        let next = try XCTUnwrap(envelope["next"] as? [String: Any])
        XCTAssertEqual(next["suggested_cmd"] as? String, ExternalAutovisorToolNames.taskLog)
        XCTAssertEqual(next["suggested_args"] as? [String: String], ["task_id": "12"], "a string task id is read too")
        XCTAssertTrue(ensured.isError)
    }

    /// `task_id` rides along only where the named tool takes one; the four that repeat the call
    /// name the refused tool.
    func testHint_carriesTheTaskOnlyWhereTheToolTakesIt() {
        XCTAssertNil(ExternalNextCall.taskIDs.hint(taskID: 3).suggested_args, "list_tasks takes no task_id")
        XCTAssertNil(ExternalNextCall.folderChanged.hint(taskID: 3).suggested_args)
        XCTAssertEqual(ExternalNextCall.foreignTask.hint(taskID: 3).suggested_args, ["task_id": "3"])
        XCTAssertNil(ExternalNextCall.foreignTask.hint().suggested_args, "no task, no argument")
        XCTAssertEqual(ExternalNextCall.firstPage.hint(taskID: 3).suggested_args, ["task_id": "3", "page": "1"])
        XCTAssertEqual(
            ExternalNextCall.waitTimeout.hint().suggested_args,
            ["timeout_seconds": "\(HostedMCPConstants.defaultWaitSeconds)"])
        for call in ExternalNextCall.allCases where call.command == nil {
            XCTAssertEqual(call.hint(after: ExternalAutovisorToolNames.scheduleTask, taskID: 3).suggested_cmd,
                           ExternalAutovisorToolNames.scheduleTask, "\(call)")
            XCTAssertEqual(call.hint(after: ExternalAutovisorToolNames.scheduleTask, taskID: 3).suggested_args,
                           ["task_id": "3"], "\(call)")
            XCTAssertNil(call.hint(after: ExternalAutovisorToolNames.listTeams, taskID: 3).suggested_args, "\(call)")
        }
    }

    /// `COMMAND_FAILED` reads the state of what the call named: the task, or the folder.
    func testFallback_commandFailed_readsTheTaskOrTheFolder() {
        XCTAssertEqual(ExternalNextCall.fallback(for: .commandFailed, taskID: 4), .taskState)
        XCTAssertEqual(ExternalNextCall.fallback(for: .commandFailed, taskID: nil), .folderState)
        XCTAssertEqual(ExternalNextCall.fallback(for: .notOwner, taskID: 4), .foreignTask)
        XCTAssertEqual(ExternalNextCall.fallback(for: .rateLimited, taskID: nil), .afterRateLimit)
    }

    /// Every reason is registered for the external fingerprint — the thirty that were inline
    /// literals until 2026-11-12 moved no version when reworded (F6 T4).
    func testEveryReasonIsRegistered() {
        let rows = Dictionary(
            RuntimePromptRegistry.entries.filter { $0.audience == .externalAgent }.map { ($0.name, $0.render()) },
            uniquingKeysWith: { first, _ in first })
        for call in ExternalNextCall.allCases {
            let row = rows["ExternalNextCall.reason/\(call.rawValue)"]
            XCTAssertNotNil(row, "\(call)")
            XCTAssertTrue(row?.contains(call.reason) == true, "\(call)")
        }
    }

    /// `executeExternalAutovisorTool` hands the agent one result: the one that went through the
    /// seam. A second `return` would be a refusal that skips it. Since 2026-11-13 the public entry
    /// only opens the call's banner scope (`suppressingBanners`) and delegates; the dispatch — and
    /// so the one exit — is `executeExternalAutovisorToolSuppressed`.
    func testTheToolCallHasOneExit_throughTheSeam() throws {
        let path = RatchetSourceScan.repoRoot.appendingPathComponent(
            "NanoTeams/Services/Core/ExternalAutovisorOperations.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        // The entry: nothing but the scope and the delegation, so no result leaves it unseamed.
        let entry = try XCTUnwrap(source.range(of: "func executeExternalAutovisorTool("))
        let entryBody = try XCTUnwrap(RatchetSourceScan.functionBody(
            after: ") async -> ToolExecutionResult", in: String(source[entry.lowerBound...])))
        let entryReturns = entryBody.components(separatedBy: "\n").filter { $0.hasPrefix("        return ") }
        XCTAssertEqual(entryReturns, ["        return await suppressingBanners {"])
        XCTAssertTrue(entryBody.contains("await executeExternalAutovisorToolSuppressed("), "the entry delegates")
        // From the dispatcher's declaration on, past the default argument's braces, to the body.
        let declaration = try XCTUnwrap(source.range(of: "func executeExternalAutovisorToolSuppressed("))
        let fromDeclaration = String(source[declaration.lowerBound...])
        let body = try XCTUnwrap(RatchetSourceScan.functionBody(after: ") async -> ToolExecutionResult", in: fromDeclaration))
        XCTAssertGreaterThan(body.count, 2_000, "anti-vacuum: the body dispatches every hosted tool")
        // A `return` of the function itself sits at its body's indentation; deeper ones are closures'.
        let returns = body.components(separatedBy: "\n").filter { $0.hasPrefix("        return ") }
        XCTAssertEqual(returns, ["        return delivered"])
        XCTAssertTrue(body.contains("deliveredToExternalAgent(result, toolName: name"), "the result goes through the seam")
    }

    /// A tool name the server does not publish: the next call is a published tool, never the name
    /// the agent got wrong (the code's own fallback would repeat it).
    func testUnknownTool_pointsAtFolderStatus_notAtTheNameItGotWrong() async throws {
        _ = try await openExternalFolder()
        let refused = try await refusal("no_such_tool", [:])
        XCTAssertEqual(refused.code, "INVALID_ARGS")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.folderStatus)
    }

    /// The refusals the Hosted MCP layer writes OUTSIDE `executeExternalAutovisorTool` — the
    /// dispatcher's rate limit and the host's lost orchestrator — never reach the exit seam, so
    /// each names its own next call. The catalog's undeclared-argument refusal is read here too:
    /// it is built in this layer and returned through the seam. `next: nil` is no next call.
    func testEveryRefusalBuiltInTheHostedMCPLayer_namesItsNextCall() throws {
        let root = RatchetSourceScan.repoRoot.appendingPathComponent("NanoTeams/Services/HostedMCP")
        var calls: [(file: String, arguments: String)] = []
        for url in RatchetSourceScan.swiftFiles(under: root) {
            let code = RatchetSourceScan.strippingLineComments(try String(contentsOf: url, encoding: .utf8))
            for arguments in RatchetSourceScan.argumentLists(after: "makeErrorResult(", in: code) {
                calls.append((url.lastPathComponent, arguments))
            }
        }
        XCTAssertGreaterThanOrEqual(calls.count, 3, "anti-vacuum: the rate limit, the lost orchestrator, the catalog")
        for call in calls {
            XCTAssertTrue(call.arguments.contains("next: "), "\(call.file): \(call.arguments)")
            XCTAssertFalse(call.arguments.contains("next: nil"), "\(call.file): \(call.arguments)")
        }
    }

    // MARK: - A hint keeps what the call sent (E1 review R1, R3–R5, R8)

    /// R1, RED before 2026-11-12: the reason said "Call it again without the arguments the message
    /// names" beside a message that offers the rename ("send the value under one of these"), and
    /// the hint carried none of the call's own place arguments — an agent that followed it sent
    /// `wait_for_events` with no cursor and was handed back what it had already handled.
    func testUndeclaredArgument_hintKeepsTheCursorAndTheTasks_andItsReasonOffersTheRename() async throws {
        _ = try await openExternalFolder()
        let refused = try await refusal(
            ExternalAutovisorToolNames.waitForEvents, ["after": "c42", "task_ids": [3, 4], "cursor": "c42"])
        XCTAssertEqual(refused.code, "INVALID_ARGS")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.waitForEvents)
        XCTAssertEqual(refused.nextArgs["after"] as? String, "c42", "the cursor the call sent")
        XCTAssertEqual(refused.nextArgs["task_ids"] as? [Int], [3, 4], "the tasks, as the array the schema types")
        XCTAssertNil(refused.nextArgs["cursor"], "never the undeclared key itself")
        let reason = try XCTUnwrap(refused.nextReason)
        XCTAssertTrue(reason.contains("under one of the arguments the message lists"), reason)
        XCTAssertFalse(reason.contains("without the arguments the message names"), reason)
    }

    /// The undeclared refusal of a task tool keeps the task and the folder the call proved; a key
    /// with no declared counterpart is simply not carried.
    func testUndeclaredArgument_onATaskTool_keepsTheTaskAndTheProvedFolder() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let refused = try await refusal(
            ExternalAutovisorToolNames.taskStatus, ["folder_id": folderID, "task_id": taskID, "verbose": true])
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskStatus)
        XCTAssertEqual(refused.nextArgs["task_id"] as? Int, taskID)
        XCTAssertEqual(refused.nextArgs["folder_id"] as? String, folderID)
        XCTAssertNil(refused.nextArgs["verbose"])
    }

    /// R3, RED before 2026-11-12: a write tool called without `task_id` got "the same call, the
    /// argument fixed" — the agent has no id to fix it with. The read tools, `schedule_task` and
    /// the code table send it to `list_tasks`; so does every task tool now.
    func testMissingTaskID_onEveryWriteTool_pointsAtListTasks() async throws {
        let folderID = try await openExternalFolder()
        let calls: [(String, [String: Any])] = [
            (ExternalAutovisorToolNames.controlTask, ["action": "pause"]),
            (ExternalAutovisorToolNames.manageRole, ["role_id": "eng", "action": "accept"]),
            (ExternalAutovisorToolNames.answerTaskQuestion, ["answer": "Yes"]),
            (ExternalAutovisorToolNames.messageTask, ["message": "Hello"]),
        ]
        for (tool, rest) in calls {
            var args = rest
            args["folder_id"] = folderID
            let refused = try await refusal(tool, args)
            XCTAssertEqual(refused.code, "INVALID_ARGS", tool)
            XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.listTasks, tool)
            XCTAssertNil(refused.nextArgs["task_id"], tool)
        }
        // A task id that is no integer names no task either.
        let unreadable = try await refusal(
            ExternalAutovisorToolNames.controlTask, ["folder_id": folderID, "task_id": "five", "action": "pause"])
        XCTAssertEqual(unreadable.nextCommand, ExternalAutovisorToolNames.listTasks)
    }

    /// With the task named, an argument refusal of the same tool is still the same call, fixed.
    func testWriteToolRefusal_withTheTaskNamed_isTheSameCallForThatTask() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let refused = try await refusal(
            ExternalAutovisorToolNames.controlTask, ["folder_id": folderID, "task_id": taskID, "action": "explode"])
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.controlTask)
        XCTAssertEqual(refused.nextArgs["task_id"] as? Int, taskID)
        XCTAssertEqual(refused.nextArgs["folder_id"] as? String, folderID)
    }

    /// R4, RED before 2026-11-12: the hint filled in `timeout_seconds` and dropped the cursor and
    /// the tasks, so following it was a session's first call again.
    func testWaitTimeoutOutOfRange_hintKeepsTheCursorAndTheTasks() async throws {
        _ = try await openExternalFolder()
        let refused = try await refusal(
            ExternalAutovisorToolNames.waitForEvents, ["after": "c42", "task_ids": [7], "timeout_seconds": 7_200])
        XCTAssertEqual(refused.code, "INVALID_ARGS")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.waitForEvents)
        XCTAssertEqual(refused.nextArgs["after"] as? String, "c42")
        XCTAssertEqual(refused.nextArgs["task_ids"] as? [Int], [7])
        XCTAssertEqual(refused.nextArgs["timeout_seconds"] as? Int, HostedMCPConstants.defaultWaitSeconds)
        // A first call with nothing else: the hint names nothing else.
        let bare = try await refusal(ExternalAutovisorToolNames.waitForEvents, ["timeout_seconds": -1])
        XCTAssertEqual(Set(bare.nextArgs.keys), ["timeout_seconds"])
    }

    /// A malformed `task_ids` is the argument to fix: the cursor rides along, the bad list does not.
    func testWaitWithMalformedTaskIDs_hintKeepsTheCursor_notTheList() async throws {
        _ = try await openExternalFolder()
        let refused = try await refusal(ExternalAutovisorToolNames.waitForEvents, ["after": "c42", "task_ids": "3"])
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.waitForEvents)
        XCTAssertEqual(refused.nextArgs["after"] as? String, "c42")
        XCTAssertNil(refused.nextArgs["task_ids"])
    }

    /// R5, RED before 2026-11-12: page 0 of round 1 pointed at page 1 of the CURRENT round.
    func testTaskChangesPageBelowOne_hintKeepsTheRoundTheCallAskedFor() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let refused = try await refusal(
            ExternalAutovisorToolNames.taskChanges, ["folder_id": folderID, "task_id": taskID, "round": 1, "page": 0])
        XCTAssertEqual(refused.code, "INVALID_ARGS")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskChanges)
        XCTAssertEqual(refused.nextArgs["round"] as? Int, 1)
        XCTAssertEqual(refused.nextArgs["page"] as? Int, 1)
        XCTAssertEqual(refused.nextArgs["task_id"] as? Int, taskID)
        XCTAssertEqual(refused.nextArgs["folder_id"] as? String, folderID)
        // No round asked for, none added: an omitted round is the run's current one.
        let noRound = try await refusal(
            ExternalAutovisorToolNames.taskChanges, ["folder_id": folderID, "task_id": taskID, "page": 0])
        XCTAssertNil(noRound.nextArgs["round"])
    }

    /// The one hint that drops a place argument on purpose still drops it: a bad `round` points at
    /// the current round, which is `task_changes` without one.
    func testTaskChangesBadRound_hintDropsTheRound() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let refused = try await refusal(
            ExternalAutovisorToolNames.taskChanges, ["folder_id": folderID, "task_id": taskID, "round": 0, "page": 2])
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskChanges)
        XCTAssertNil(refused.nextArgs["round"])
        XCTAssertEqual(refused.nextArgs["task_id"] as? Int, taskID)
    }

    /// `task_log`'s cursors are moments: a bad `limit` keeps the cursor the call sent, a bad cursor
    /// is not sent back.
    func testTaskLogRefusal_keepsTheCursorUnlessTheCursorIsTheFault() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let badLimit = try await refusal(
            ExternalAutovisorToolNames.taskLog, ["folder_id": folderID, "task_id": taskID, "after": 5, "limit": 0])
        XCTAssertEqual(badLimit.nextCommand, ExternalAutovisorToolNames.taskLog)
        XCTAssertEqual(badLimit.nextArgs["after"] as? Int, 5)
        XCTAssertNil(badLimit.nextArgs["limit"])
        let badCursor = try await refusal(
            ExternalAutovisorToolNames.taskLog, ["folder_id": folderID, "task_id": taskID, "before": 0])
        XCTAssertNil(badCursor.nextArgs["before"])
        XCTAssertEqual(badCursor.nextArgs["task_id"] as? Int, taskID)
    }

    /// A `file_path` refused for its shape: the round the call asked for rides along.
    func testTaskChangesBadFilePath_hintKeepsTheRound() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let refused = try await refusal(
            ExternalAutovisorToolNames.taskChanges,
            ["folder_id": folderID, "task_id": taskID, "round": 1, "file_path": "../secret"])
        XCTAssertEqual(refused.code, "INVALID_ARGS")
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskChanges)
        XCTAssertEqual(refused.nextArgs["round"] as? Int, 1)
        XCTAssertNil(refused.nextArgs["file_path"])
    }

    /// The exit seam carries the same: a refusal that named nothing keeps the place arguments the
    /// call sent to the tool it repeats.
    func testEnsuringNext_retry_keepsTheCallsPlaceAndItsFolder() throws {
        let ensured = ExternalNextCall.ensuringNext(
            Self.bareRefusal(.cancelled), toolName: ExternalAutovisorToolNames.taskLog,
            args: ["folder_id": "F", "task_id": 4, "after": 9, "limit": 10])
        let refused = try Self.refusal(of: ensured.outputJSON)
        XCTAssertEqual(refused.nextCommand, ExternalAutovisorToolNames.taskLog)
        XCTAssertEqual(refused.nextArgs as? [String: String], ["folder_id": "F", "task_id": "4", "after": "9"])
    }

    // MARK: - Texts (F6 T11)

    /// The note beside `changed_files` sends the agent to the snapshot of the pass, not to git.
    func testChangedFilesNote_pointsAtTaskChanges() {
        let note = NTMSOrchestrator.changedFilesBashNote
        XCTAssertTrue(note.contains("task_changes"), note)
        XCTAssertFalse(note.contains("git status"), note)
        XCTAssertFalse(note.contains("git diff"), note)
    }
}
