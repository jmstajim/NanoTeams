import XCTest
@testable import NanoTeams

@MainActor
final class ExternalAutovisorActivityLogTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var agentA: AgentIdentity!
    private var folderID: String!

    override func setUp() async throws {
        try await super.setUp()
        agentA = AgentIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            label: "Claude Code"
        )
        await openReadyExternalFolder(at: tempDir)
        folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    override func tearDown() async throws {
        folderID = nil
        agentA = nil
        try await super.tearDown()
    }

    private func openReadyExternalFolder(at url: URL) async {
        await sut.openWorkFolder(url)
        if let nonChat = sut.snapshot?.workFolder.teams.first(where: { !$0.isChatMode && !$0.isHiddenFromPickers }) {
            await sut.mutateWorkFolder { $0.setActiveTeam(nonChat.id) }
        }
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
    }

    private func parseJSON(_ output: String) throws -> [String: Any] {
        let data = try XCTUnwrap(output.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 1. Path & 0o700 Permissions

    func testLogPathAndDirectoryPermissions_createsInternalAutovisorDirWith0700() async throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        XCTAssertTrue(paths.isInternalURL(paths.internalAutovisorDir))
        XCTAssertTrue(paths.isInternalURL(paths.externalActivityLogJSONL))
        XCTAssertTrue(paths.externalActivityLogJSONL.path.hasSuffix(".nanoteams/internal/autovisor/external_activity.jsonl"))

        let res = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.folderStatus,
            args: [:],
            agent: agentA
        )
        XCTAssertFalse(res.isError, res.outputJSON)
        sut.externalActivityLog.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.externalActivityLogJSONL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.internalAutovisorDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700)
    }

    // MARK: - 2. Summaries Only (Never Raw Bodies — D13)

    func testSummariesOnly_neverWritesBriefAnswerMessageCommentOrArtifactBodies() async throws {
        let briefMarker = "BRIEF_BODY_MARKER_DO_NOT_LOG_991122"
        let answerMarker = "ANSWER_BODY_MARKER_DO_NOT_LOG_334455"
        let messageMarker = "MESSAGE_BODY_MARKER_DO_NOT_LOG_667788"
        let commentMarker = "COMMENT_BODY_MARKER_DO_NOT_LOG_112233"
        let artifactBodyMarker = "ARTIFACT_CONTENT_MARKER_DO_NOT_LOG_445566"
        let stepLogMarker = "STEP_LOG_BODY_MARKER_DO_NOT_LOG_778899"

        // 1. create_managed_task with secret brief body
        let createRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: [
                "folder_id": folderID!,
                "title": "Build auth service",
                "brief": "Please implement auth. \(briefMarker)"
            ],
            agent: agentA
        )
        XCTAssertFalse(createRes.isError, createRes.outputJSON)
        let createEnv = try parseJSON(createRes.outputJSON)
        let taskID = try XCTUnwrap((createEnv["data"] as? [String: Any])?["task_id"] as? Int)

        // Stage a parked question, an artifact, and a step message on the created task
        await sut.ensureTaskLoaded(taskID)
        let team = sut.resolvedTeam(for: sut.loadedTask(taskID))
        let roleDef = try XCTUnwrap(team.nonSupervisorRoles.first)
        let roleID: String = roleDef.id
        let deliverableName: String = team.supervisorRequiredArtifacts.first ?? "Final Spec"

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let roleDir = paths.roleDir(taskID: taskID, runID: 0, roleID: roleID)
        try FileManager.default.createDirectory(at: roleDir, withIntermediateDirectories: true)
        let artURL = roleDir.appendingPathComponent("artifact_spec.md")
        try "Summary\n\(artifactBodyMarker)".write(to: artURL, atomically: true, encoding: .utf8)
        let relPath = paths.relativePathWithinNanoteams(for: artURL)

        let now = Date(timeIntervalSince1970: 1_700_000_100)
        _ = await sut.mutateTask(taskID: taskID) { task in
            var step = StepExecution.make(for: roleDef)
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Which OAuth flow?"
            step.toolCalls = [
                StepToolCall(
                    id: UUID(),
                    createdAt: now,
                    name: ToolNames.askSupervisor,
                    argumentsJSON: #"{"question":"Which OAuth flow?"}"#,
                    resultJSON: #"{"ok":true}"#
                )
            ]
            step.messages = [StepMessage(role: .assistant, content: "Log line \(stepLogMarker)")]
            step.artifacts = [Artifact(name: deliverableName, relativePath: relPath)]
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [roleID: .working], teamID: team.id)]
        }

        // 2. answer_task_question with answer body
        let answerRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.answerTaskQuestion,
            args: [
                "folder_id": folderID!,
                "task_id": taskID,
                "answer": "Use PKCE flow \(answerMarker)"
            ],
            agent: agentA
        )
        XCTAssertFalse(answerRes.isError, answerRes.outputJSON)

        // 3. message_task with message body
        let msgRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.messageTask,
            args: [
                "folder_id": folderID!,
                "task_id": taskID,
                "message": "Also check edge cases \(messageMarker)"
            ],
            agent: agentA
        )
        XCTAssertFalse(msgRes.isError, msgRes.outputJSON)

        // 4. task_result & read_artifact & task_log (before restart clears the step's artifacts/messages)
        let resultRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.taskResult,
            args: ["folder_id": folderID!, "task_id": taskID],
            agent: agentA
        )
        XCTAssertFalse(resultRes.isError, resultRes.outputJSON)

        let readArtRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.readArtifact,
            args: ["folder_id": folderID!, "task_id": taskID, "name": deliverableName],
            agent: agentA
        )
        XCTAssertFalse(readArtRes.isError, readArtRes.outputJSON)

        let logRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.taskLog,
            args: ["folder_id": folderID!, "task_id": taskID],
            agent: agentA
        )
        XCTAssertFalse(logRes.isError, logRes.outputJSON)

        // 5. manage_role restart with comment body
        let roleRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.manageRole,
            args: [
                "folder_id": folderID!,
                "task_id": taskID,
                "role_id": roleID,
                "action": "restart",
                "comment": "Focus on tests \(commentMarker)"
            ],
            agent: agentA
        )
        XCTAssertFalse(roleRes.isError, roleRes.outputJSON)

        sut.externalActivityLog.flush()

        let rawText = try String(contentsOf: paths.externalActivityLogJSONL, encoding: .utf8)
        XCTAssertFalse(rawText.isEmpty)
        XCTAssertFalse(rawText.contains(briefMarker))
        XCTAssertFalse(rawText.contains(answerMarker))
        XCTAssertFalse(rawText.contains(messageMarker))
        XCTAssertFalse(rawText.contains(commentMarker))
        XCTAssertFalse(rawText.contains(artifactBodyMarker))
        XCTAssertFalse(rawText.contains(stepLogMarker))

        let records = sut.externalActivityLog.tail(limit: 20)
        XCTAssertEqual(records.count, 7)

        let createRec = try XCTUnwrap(records.first(where: { $0.tool == ExternalAutovisorToolNames.createManagedTask }))
        XCTAssertEqual(createRec.taskID, taskID)
        XCTAssertTrue(createRec.ok)
        XCTAssertEqual(createRec.agentID, agentA.id)
        XCTAssertEqual(createRec.agentLabel, "Claude Code")
        XCTAssertEqual(createRec.taskTitle, "Build auth service")
        XCTAssertTrue(createRec.headline.contains("Claude Code"))
        XCTAssertTrue(createRec.headline.contains("#\(taskID)"))

        let answerRec = try XCTUnwrap(records.first(where: { $0.tool == ExternalAutovisorToolNames.answerTaskQuestion }))
        XCTAssertEqual(answerRec.roleID, roleID)
        XCTAssertTrue(answerRec.headline.contains(roleID))
        XCTAssertTrue(answerRec.headline.contains("Claude Code"))

        let resultRec = try XCTUnwrap(records.first(where: { $0.tool == ExternalAutovisorToolNames.taskResult }))
        XCTAssertEqual(resultRec.artifactNames, [deliverableName])
        XCTAssertGreaterThan(resultRec.resultBytes, 0)
    }

    // MARK: - 3. Token Redaction & Error Recording

    func testTokenRedactionAndErrorRecording_scrubsTokensAndRecordsErrorCode() async throws {
        let leakedNtmToken = "ntm_9f8e7d6c_secretTokenValue1234567890abcdef"
        let leakedBearer = "Bearer superSecretBearerValue9876543210"

        let failRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.readArtifact,
            args: [
                "folder_id": folderID!,
                "task_id": 999,
                "name": "missing_\(leakedNtmToken) \(leakedBearer)"
            ],
            agent: AgentIdentity(id: agentA.id, label: "Agent \(leakedNtmToken)")
        )
        XCTAssertTrue(failRes.isError)

        sut.externalActivityLog.flush()
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let rawText = try String(contentsOf: paths.externalActivityLogJSONL, encoding: .utf8)

        XCTAssertFalse(rawText.contains("secretTokenValue1234567890abcdef"))
        XCTAssertFalse(rawText.contains("superSecretBearerValue9876543210"))

        let lastRecord = try XCTUnwrap(sut.externalActivityLog.tail(limit: 1).first)
        XCTAssertFalse(lastRecord.ok)
        // The refusal's own code: task 999 does not exist (until 2026-11-09 every refusal here
        // was `COMMAND_FAILED`).
        XCTAssertEqual(lastRecord.errorCode, ToolErrorCode.taskNotFound.rawValue)
        XCTAssertGreaterThan(lastRecord.resultBytes, 0)
        XCTAssertTrue(lastRecord.headline.contains("failed"))
    }

    // MARK: - 4. Size Rotation & Tail Across Rotation

    func testSizeRotation_rotatesToDotOneAndPreservesTail() async throws {
        sut.externalActivityLog.setLimits(.init(maxFileBytes: 700, maxTailRecords: 10))

        for _ in 0..<6 {
            _ = await sut.executeExternalAutovisorTool(
                name: ExternalAutovisorToolNames.folderStatus,
                args: [:],
                agent: agentA
            )
        }
        sut.externalActivityLog.flush()

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let primaryURL = paths.externalActivityLogJSONL
        let backupURL = try XCTUnwrap(sut.externalActivityLog.backupLogURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let primaryAttrs = try FileManager.default.attributesOfItem(atPath: primaryURL.path)
        let primarySize = try XCTUnwrap((primaryAttrs[.size] as? NSNumber)?.intValue)
        XCTAssertLessThanOrEqual(primarySize, 700)

        let inMemoryTail = sut.externalActivityLog.tail(limit: 6)
        XCTAssertEqual(inMemoryTail.count, 6)

        // Re-activating the folder loads tail across backup (.1) + primary in order
        let freshLog = ExternalAutovisorActivityLog(limits: .init(maxFileBytes: 700, maxTailRecords: 10))
        freshLog.activateFolder(logURL: primaryURL)
        let reloaded = freshLog.tail(limit: 6)
        XCTAssertFalse(reloaded.isEmpty)
        XCTAssertEqual(reloaded.last?.id, inMemoryTail.last?.id)
    }

    // MARK: - 5. Live Updates & Folder Transition Isolation

    func testLiveUpdatesAndFolderTransition_notifiesObserverAndIsolatesFolders() async throws {
        var appendedIDs: [UUID] = []
        sut.externalActivityLog.onRecordAppended = { record in
            appendedIDs.append(record.id)
        }
        let revBefore = sut.externalActivityLog.revision

        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.listTeams,
            args: [:],
            agent: agentA
        )
        XCTAssertEqual(appendedIDs.count, 1)
        XCTAssertGreaterThan(sut.externalActivityLog.revision, revBefore)

        sut.externalActivityLog.flush()
        let firstFolderRecordID = try XCTUnwrap(sut.externalActivityLog.records.first?.id)

        // Switch to a second folder
        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMSActivitySecond-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondDir) }

        await openReadyExternalFolder(at: secondDir)
        XCTAssertTrue(sut.externalActivityLog.records.isEmpty)

        // Switch back to the first folder -> persisted tail reloads
        await openReadyExternalFolder(at: tempDir)
        XCTAssertEqual(sut.externalActivityLog.records.first?.id, firstFolderRecordID)
    }

    // MARK: - 6. Argument Summary Keys (team_id, after, schedule_task flat fields)

    func testArgumentSummaries_recordsTeamIDAfterCursorAndScheduleFields() async throws {
        // 1. Failed create_managed_task with explicit team_id records team= in argumentsSummary
        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: [
                "folder_id": folderID!,
                "title": "Uncreated Task",
                "brief": "Brief",
                "team_id": "nonexistent_team_slug"
            ],
            agent: agentA
        )
        let failedCreateRec = try XCTUnwrap(sut.externalActivityLog.tail(limit: 1).first)
        XCTAssertFalse(failedCreateRec.ok)
        XCTAssertEqual(failedCreateRec.teamName, "nonexistent_team_slug")
        XCTAssertTrue(failedCreateRec.argumentsSummary.contains("team=nonexistent_team_slug"), failedCreateRec.argumentsSummary)

        // 2. wait_for_events with `after` and `timeout_seconds` records `after=` and `timeout=`
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.waitForEvents,
            args: [
                "after": cursor,
                "timeout_seconds": 0
            ],
            agent: agentA
        )
        let waitRec = try XCTUnwrap(sut.externalActivityLog.tail(limit: 1).first)
        XCTAssertTrue(waitRec.ok)
        XCTAssertTrue(waitRec.argumentsSummary.contains("after="), waitRec.argumentsSummary)
        XCTAssertTrue(waitRec.argumentsSummary.contains("timeout=0s"), waitRec.argumentsSummary)

        // 3. schedule_task with repeat_every_minutes and clear=true
        let createRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: [
                "folder_id": folderID!,
                "title": "Scheduled Task",
                "brief": "Brief"
            ],
            agent: agentA
        )
        let createEnv = try parseJSON(createRes.outputJSON)
        let taskID = try XCTUnwrap((createEnv["data"] as? [String: Any])?["task_id"] as? Int)

        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.scheduleTask,
            args: [
                "folder_id": folderID!,
                "task_id": taskID,
                "repeat_every_minutes": 45
            ],
            agent: agentA
        )
        let schedRec = try XCTUnwrap(sut.externalActivityLog.tail(limit: 1).first)
        XCTAssertTrue(schedRec.ok)
        XCTAssertTrue(schedRec.argumentsSummary.contains("repeat_every_minutes=45"), schedRec.argumentsSummary)

        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.scheduleTask,
            args: [
                "folder_id": folderID!,
                "task_id": taskID,
                "clear": true
            ],
            agent: agentA
        )
        let clearRec = try XCTUnwrap(sut.externalActivityLog.tail(limit: 1).first)
        XCTAssertTrue(clearRec.ok)
        XCTAssertTrue(clearRec.argumentsSummary.contains("clear=true"), clearRec.argumentsSummary)

        // Additional schedule fields: repeat_daily_at, repeat_monthly_day, run_once_at
        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.scheduleTask,
            args: [
                "folder_id": folderID!,
                "task_id": taskID,
                "repeat_daily_at": "09:30"
            ],
            agent: agentA
        )
        XCTAssertTrue(sut.externalActivityLog.tail(limit: 1).first?.argumentsSummary.contains("repeat_daily_at=09:30") == true)

        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.scheduleTask,
            args: [
                "folder_id": folderID!,
                "task_id": taskID,
                "repeat_monthly_day": 15,
                "repeat_daily_at": "10:00"
            ],
            agent: agentA
        )
        let monthlyRec = try XCTUnwrap(sut.externalActivityLog.tail(limit: 1).first)
        XCTAssertTrue(monthlyRec.ok, monthlyRec.argumentsSummary)
        XCTAssertTrue(monthlyRec.argumentsSummary.contains("repeat_monthly_day=15"), monthlyRec.argumentsSummary)

        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.scheduleTask,
            args: [
                "folder_id": folderID!,
                "task_id": taskID,
                "run_once_at": "2030-01-01T01:00:00Z"
            ],
            agent: agentA
        )
        XCTAssertTrue(sut.externalActivityLog.tail(limit: 1).first?.argumentsSummary.contains("run_once_at=2030-01-01T01:00:00Z") == true)
    }

    func testHeadlinesAndLimitsTruncation_coversAllToolHeadlineVariants() async throws {
        let id = agentA.id
        let cases: [(ExternalAutovisorActivityRecord, String)] = [
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.folderStatus, ok: false, errorCode: nil, resultBytes: 10), "Claude: folder_status failed (ERROR)"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.createManagedTask, taskID: 1, teamName: nil, taskTitle: "Spec", ok: true, resultBytes: 10), "Claude created task #1 'Spec'"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.answerTaskQuestion, taskID: 1, roleID: nil, ok: true, resultBytes: 10), "Claude answered question in task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.createManagedTask, taskID: 1, taskTitle: nil, ok: true, resultBytes: 10), "Claude created task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.manageRole, taskID: 1, roleID: "eng", action: "accept", ok: true, resultBytes: 10), "Claude: accept role eng in task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.manageRole, taskID: 1, roleID: nil, action: nil, ok: true, resultBytes: 10), "Claude: updated role role in task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.controlTask, taskID: 1, action: "pause", ok: true, resultBytes: 10), "Claude: pause task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.controlTask, taskID: 1, action: nil, ok: true, resultBytes: 10), "Claude: controlled task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.messageTask, taskID: 1, roleID: "eng", ok: true, resultBytes: 10), "Claude messaged role eng in task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.messageTask, taskID: 1, roleID: nil, ok: true, resultBytes: 10), "Claude messaged task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.scheduleTask, taskID: 1, ok: true, resultBytes: 10), "Claude updated schedule for task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.waitForEvents, ok: true, resultBytes: 10, eventCount: 3), "Claude received 3 event(s)"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.waitForEvents, ok: true, resultBytes: 10, eventCount: 0), "Claude waited for events"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.taskResult, taskID: 1, ok: true, resultBytes: 10, artifactNames: ["Spec"]), "Claude read result of task #1 (Spec)"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.taskResult, taskID: 1, ok: true, resultBytes: 10, artifactNames: []), "Claude read result of task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.readArtifact, taskID: 1, ok: true, resultBytes: 10, artifactNames: ["Spec"]), "Claude read artifact 'Spec' of task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.readArtifact, taskID: 1, ok: true, resultBytes: 10, artifactNames: []), "Claude read artifact 'artifact' of task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.taskLog, taskID: 1, ok: true, resultBytes: 10), "Claude read log of task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.taskStatus, taskID: 1, ok: true, resultBytes: 10), "Claude checked status of task #1"),
            (ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.listTeams, ok: true, resultBytes: 10), "Claude called list_teams")
        ]
        for (rec, expected) in cases {
            XCTAssertEqual(rec.headline, expected)
            sut.externalActivityLog.record(rec)
        }
        XCTAssertEqual(sut.externalActivityLog.entries.count, sut.externalActivityLog.records.count)
        XCTAssertEqual(sut.externalActivityLog.tail(limit: 2).count, 2)
        sut.externalActivityLog.setLimits(.init(maxFileBytes: 4096, maxTailRecords: 2))
        XCTAssertEqual(sut.externalActivityLog.records.count, 2)
        // Appending after lowering maxTailRecords triggers in-memory trim on record(_:) (L232-233)
        let extraRec = ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: ExternalAutovisorToolNames.listTeams, ok: true, resultBytes: 10)
        sut.externalActivityLog.record(extraRec)
        XCTAssertEqual(sut.externalActivityLog.records.count, 2)

        // Disk reload when file has > maxTailRecords records (L306)
        let capLogURL = tempDir.appendingPathComponent("capped.jsonl")
        let capLog = ExternalAutovisorActivityLog(limits: .init(maxFileBytes: 8192, maxTailRecords: 2))
        capLog.activateFolder(logURL: capLogURL)
        for i in 0..<4 {
            capLog.record(ExternalAutovisorActivityRecord(agentID: id, agentLabel: "Claude", tool: "t\(i)", ok: true, resultBytes: 5))
        }
        capLog.flush()
        let reloadedCapLog = ExternalAutovisorActivityLog(limits: .init(maxFileBytes: 8192, maxTailRecords: 2))
        reloadedCapLog.activateFolder(logURL: capLogURL)
        XCTAssertEqual(reloadedCapLog.records.count, 2)

        // Error result without error.message covers summarizeExternalOutcome return code (L522)
        await sut.openWorkFolder(tempDir.appendingPathComponent("err-proj", isDirectory: true))
        let errNoMsgResult = ToolExecutionResult(
            toolName: ExternalAutovisorToolNames.listTasks,
            argumentsJSON: "{}",
            outputJSON: #"{"ok":false,"error":{"code":"ERR_CODE_ONLY"}}"#,
            isError: true
        )
        sut.recordExternalAutovisorActivity(
            tool: ExternalAutovisorToolNames.listTasks,
            args: [:],
            agent: AgentIdentity(id: id, label: "Claude"),
            preCallRoleID: nil,
            result: errNoMsgResult,
            durationMs: 1.0,
            now: Date(),
            within: sut.currentFolderLifecycle
        )
        XCTAssertEqual(sut.externalActivityLog.records.last?.outcomeSummary, "ERR_CODE_ONLY")
    }

    // MARK: - 8. Full calls beside the summary (2026-11-08)

    private var callsDir: URL {
        ExternalAutovisorActivityLog.callsDirectoryURL(for: NTMSPaths(workFolderRoot: tempDir).externalActivityLogJSONL)
    }

    private func filesOnDisk(_ dir: URL) -> Set<UUID> {
        ExternalAutovisorFullCallStore.storedIDs(in: dir, fileManager: .default)
    }

    private func record(tool: String = "t", taskID: Int? = nil) -> ExternalAutovisorActivityRecord {
        ExternalAutovisorActivityRecord(agentID: agentA.id, agentLabel: "Claude Code", tool: tool, taskID: taskID, ok: true, resultBytes: 2)
    }

    private func call(_ marker: String) -> ExternalAutovisorFullCall {
        ExternalAutovisorFullCall(id: UUID(), arguments: #"{"m":"\#(marker)"}"#, response: #"{"ok":true}"#)
    }

    /// The summary stays a summary; the call in full sits beside it and reads back exactly.
    func testFullCall_keepsTheWholeRequestAndResponseBesideTheSummary() async throws {
        let briefMarker = "BRIEF_IN_FULL_CALL_5521"
        let res = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID!, "title": "Calc", "brief": "Build a calculator at /tmp/calc \(briefMarker)"],
            agent: agentA
        )
        XCTAssertFalse(res.isError, res.outputJSON)
        let entry = try XCTUnwrap(sut.externalActivityLog.records.last)
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.contains(entry.id))

        let loaded = await sut.externalActivityLog.fullCall(id: entry.id)
        let full = try XCTUnwrap(loaded)
        XCTAssertEqual(full.id, entry.id)
        XCTAssertEqual(full.response, res.outputJSON, "exactly what the agent received")
        let arguments = try parseJSON(full.arguments)
        XCTAssertEqual(arguments["brief"] as? String, "Build a calculator at /tmp/calc \(briefMarker)")
        XCTAssertFalse(full.arguments.contains(#"\/"#), "slashes stay slashes")

        sut.externalActivityLog.flush()
        let summary = try String(contentsOf: NTMSPaths(workFolderRoot: tempDir).externalActivityLogJSONL, encoding: .utf8)
        XCTAssertFalse(summary.contains(briefMarker), "the summary line still keeps no body (Ш14)")
        XCTAssertEqual(filesOnDisk(callsDir), [entry.id])
        let attrs = try FileManager.default.attributesOfItem(atPath: callsDir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// No byte cap anywhere on the way: a half-megabyte response reaches the file whole.
    func testFullCall_aHalfMegabyteResponseIsKeptWhole() async throws {
        let body = #"{"ok":true,"data":{"content":""# + String(repeating: "x", count: 512 * 1024) + #""}}"#
        sut.recordExternalAutovisorActivity(
            tool: ExternalAutovisorToolNames.readArtifact,
            args: ["folder_id": folderID!, "task_id": 0, "name": "Engineering Notes"],
            agent: agentA,
            preCallRoleID: nil,
            result: ToolExecutionResult(toolName: ExternalAutovisorToolNames.readArtifact, argumentsJSON: "{}", outputJSON: body, isError: false),
            durationMs: 1,
            now: Date(),
            within: sut.currentFolderLifecycle
        )
        let entry = try XCTUnwrap(sut.externalActivityLog.records.last)
        let loaded = await sut.externalActivityLog.fullCall(id: entry.id)
        let full = try XCTUnwrap(loaded)
        XCTAssertEqual(full.response, body)
    }

    /// The agent's own token never reaches the disk; the rest of what it wrote does, verbatim.
    func testFullCall_scrubsTheAgentTokenAndNothingElse() async throws {
        let token = "ntm_0a1b2c3d_" + String(repeating: "Zq7-_", count: 8) + "abc"
        let res = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID!, "title": "Streaming",
                   "brief": "a basic implementation of token streaming; my token: \(token)"],
            agent: agentA
        )
        XCTAssertFalse(res.isError, res.outputJSON)
        let entry = try XCTUnwrap(sut.externalActivityLog.records.last)
        sut.externalActivityLog.flush()

        let raw = try String(contentsOf: ExternalAutovisorFullCallStore.fileURL(for: entry.id, in: callsDir), encoding: .utf8)
        XCTAssertFalse(raw.contains(token))
        let loaded = await sut.externalActivityLog.fullCall(id: entry.id)
        let full = try XCTUnwrap(loaded)
        let brief = try parseJSON(full.arguments)["brief"] as? String
        XCTAssertEqual(brief, "a basic implementation of token streaming; my token: \(MCPRedaction.placeholder)")
    }

    /// Bodies are kept for exactly the rows of the tail: a record that leaves it takes its file
    /// along — through `record` and through a lowered limit alike.
    func testFullCall_retentionFollowsTheTail() async throws {
        sut.externalActivityLog.setLimits(.init(maxFileBytes: 512 * 1024, maxTailRecords: 3))
        for _ in 0..<5 {
            _ = await sut.executeExternalAutovisorTool(name: ExternalAutovisorToolNames.folderStatus, args: [:], agent: agentA)
        }
        sut.externalActivityLog.flush()
        let tail = Set(sut.externalActivityLog.records.map(\.id))
        XCTAssertEqual(tail.count, 3)
        XCTAssertEqual(sut.externalActivityLog.fullCallIDs, tail)
        XCTAssertEqual(filesOnDisk(callsDir), tail, "the two evicted rows' files are gone")

        sut.externalActivityLog.setLimits(.init(maxFileBytes: 512 * 1024, maxTailRecords: 1))
        sut.externalActivityLog.flush()
        let last = try XCTUnwrap(sut.externalActivityLog.records.last?.id)
        XCTAssertEqual(sut.externalActivityLog.fullCallIDs, [last])
        XCTAssertEqual(filesOnDisk(callsDir), [last])
        for evicted in tail.subtracting([last]) {
            let gone = await sut.externalActivityLog.fullCall(id: evicted)
            XCTAssertNil(gone)
        }
    }

    /// Activation: the tail's files become the openable set, orphans go, a row recorded before
    /// calls were kept stays unopenable, and a stray file is not mistaken for a call.
    func testFullCall_activationRestoresTheSetAndPrunesOrphans() async throws {
        let logURL = tempDir.appendingPathComponent("act/external_activity.jsonl")
        let dir = ExternalAutovisorActivityLog.callsDirectoryURL(for: logURL)
        let writer = ExternalAutovisorActivityLog()
        writer.activateFolder(logURL: logURL)
        let legacy = record()
        writer.record(legacy)                         // a row from before full calls
        let kept = record()
        writer.record(kept, fullCall: call("kept"))
        writer.flush()
        let orphan = ExternalAutovisorFullCall(id: UUID(), arguments: "{}", response: "{}")
        XCTAssertTrue(ExternalAutovisorFullCallStore.write(orphan, in: dir, fileManager: .default))
        try Data("x".utf8).write(to: dir.appendingPathComponent("README.txt"))

        let reader = ExternalAutovisorActivityLog()
        reader.activateFolder(logURL: logURL)
        reader.flush()
        XCTAssertEqual(reader.fullCallIDs, [kept.id])
        XCTAssertEqual(filesOnDisk(dir), [kept.id], "the orphan went")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.txt").path),
                      "a file that is not a call is not ours to delete")
    }

    /// A log that exists and reads as nothing is a failed read, not an empty log: no body goes.
    func testFullCall_anUnreadableLogDeletesNoBody() async throws {
        let logURL = tempDir.appendingPathComponent("garbage/external_activity.jsonl")
        let dir = ExternalAutovisorActivityLog.callsDirectoryURL(for: logURL)
        let writer = ExternalAutovisorActivityLog()
        writer.activateFolder(logURL: logURL)
        let kept = record()
        writer.record(kept, fullCall: call("kept"))
        writer.flush()
        try Data("{ this is not a record\nnor this\n".utf8).write(to: logURL)

        let reader = ExternalAutovisorActivityLog()
        reader.activateFolder(logURL: logURL)
        reader.flush()
        XCTAssertTrue(reader.records.isEmpty)
        XCTAssertTrue(reader.fullCallIDs.isEmpty)
        XCTAssertEqual(filesOnDisk(dir), [kept.id], "kept for the read that succeeds")

        // No log at all, on the other hand, is a log with no rows: its bodies are orphans.
        try FileManager.default.removeItem(at: logURL)
        let fresh = ExternalAutovisorActivityLog()
        fresh.activateFolder(logURL: logURL)
        fresh.flush()
        XCTAssertTrue(filesOnDisk(dir).isEmpty)
    }

    /// A read issued right behind its own write sees it: one serial queue orders both.
    func testFullCall_aReadQueuedBehindItsWriteSeesIt() async throws {
        let log = ExternalAutovisorActivityLog()
        log.activateFolder(logURL: tempDir.appendingPathComponent("rw/external_activity.jsonl"))
        let entry = record()
        let full = call("queued")
        log.record(entry, fullCall: full)
        let read = await log.fullCall(id: entry.id)
        XCTAssertEqual(read, ExternalAutovisorFullCall(id: entry.id, arguments: full.arguments, response: full.response))
    }

    /// The call is filed under the ROW's id, whatever id the caller put on it.
    func testFullCall_isFiledUnderTheRecordID() async throws {
        let log = ExternalAutovisorActivityLog()
        log.activateFolder(logURL: tempDir.appendingPathComponent("id/external_activity.jsonl"))
        let entry = record()
        log.record(entry, fullCall: call("mismatched id"))
        XCTAssertEqual(log.fullCallIDs, [entry.id])
        let read = await log.fullCall(id: entry.id)
        XCTAssertEqual(read?.id, entry.id)
    }

    /// No folder, no full call: nothing written, nothing claimed, nothing read.
    func testFullCall_withoutAFolderNothingIsKept() async throws {
        let log = ExternalAutovisorActivityLog()
        let entry = record()
        log.record(entry, fullCall: call("nowhere"))
        XCTAssertTrue(log.fullCallIDs.isEmpty)
        XCTAssertNil(log.callsDirectoryURL)
        let read = await log.fullCall(id: entry.id)
        XCTAssertNil(read)
        let unknown = await sut.externalActivityLog.fullCall(id: UUID())
        XCTAssertNil(unknown)
    }

    /// Folder A's call lands in A, never in B, and is openable again when A comes back. No flush
    /// here: B's activation reads its tail through the same serial queue, behind A's write.
    func testFullCall_followsItsFolderAcrossASwitch() async throws {
        _ = await sut.executeExternalAutovisorTool(name: ExternalAutovisorToolNames.folderStatus, args: [:], agent: agentA)
        let aID = try XCTUnwrap(sut.externalActivityLog.records.last?.id)
        let aDir = callsDir

        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMSFullCallSecond-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondDir) }
        await openReadyExternalFolder(at: secondDir)
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.isEmpty)
        let bDir = ExternalAutovisorActivityLog.callsDirectoryURL(for: NTMSPaths(workFolderRoot: secondDir).externalActivityLogJSONL)
        XCTAssertTrue(filesOnDisk(bDir).isEmpty, "nothing of A's lands in B")
        XCTAssertEqual(filesOnDisk(aDir), [aID], "A's write landed before the switch finished")
        let fromB = await sut.externalActivityLog.fullCall(id: aID)
        XCTAssertNil(fromB)

        await openReadyExternalFolder(at: tempDir)
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.contains(aID))
        let back = await sut.externalActivityLog.fullCall(id: aID)
        XCTAssertNotNil(back)
    }

    /// A deleted task takes its calls' bodies along; the rows stay, unopenable, and a call about
    /// nothing in particular is untouched.
    func testFullCall_deletingATaskForgetsItsCalls() async throws {
        let createRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID!, "title": "Doomed", "brief": "Will be deleted"],
            agent: agentA
        )
        XCTAssertFalse(createRes.isError, createRes.outputJSON)
        let taskID = try XCTUnwrap((try parseJSON(createRes.outputJSON)["data"] as? [String: Any])?["task_id"] as? Int)
        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.taskStatus, args: ["folder_id": folderID!, "task_id": taskID], agent: agentA)
        _ = await sut.executeExternalAutovisorTool(name: ExternalAutovisorToolNames.folderStatus, args: [:], agent: agentA)
        let taskRows = Set(sut.externalActivityLog.records.filter { $0.taskID == taskID }.map(\.id))
        XCTAssertEqual(taskRows.count, 2)
        let otherRow = try XCTUnwrap(sut.externalActivityLog.records.last?.id)
        let rowCount = sut.externalActivityLog.records.count

        await sut.removeTask(taskID)
        sut.externalActivityLog.flush()

        XCTAssertEqual(sut.externalActivityLog.records.count, rowCount, "the summaries stay")
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.isDisjoint(with: taskRows))
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.contains(otherRow))
        XCTAssertTrue(filesOnDisk(callsDir).isDisjoint(with: taskRows), "its brief is off the disk")
        XCTAssertTrue(filesOnDisk(callsDir).contains(otherRow))
        for id in taskRows {
            let gone = await sut.externalActivityLog.fullCall(id: id)
            XCTAssertNil(gone)
        }
    }

    /// A reset deletes `.nanoteams/`; a call queued before it must not rebuild the tree after.
    /// The queue is HELD while the call records, so its writes are still pending when the reset
    /// starts — a write lands in about a millisecond, and without the hold this passes with the
    /// transition's flush deleted.
    func testFullCall_aResetLeavesNoCallOfTheOldFolder() async throws {
        let release = DispatchSemaphore(value: 0)
        sut.externalActivityLog._testHoldIOQueue(atMost: 1.0, until: release)
        _ = await sut.executeExternalAutovisorTool(name: ExternalAutovisorToolNames.folderStatus, args: [:], agent: agentA)
        let oldID = try XCTUnwrap(sut.externalActivityLog.records.last?.id)

        await sut.resetWorkFolderSettings()
        release.signal()
        sut.externalActivityLog.flush()

        XCTAssertFalse(sut.externalActivityLog.fullCallIDs.contains(oldID))
        XCTAssertFalse(filesOnDisk(callsDir).contains(oldID))
        let summary = (try? String(contentsOf: NTMSPaths(workFolderRoot: tempDir).externalActivityLogJSONL, encoding: .utf8)) ?? ""
        XCTAssertFalse(summary.contains(oldID.uuidString), "nor its summary line")
    }

    /// A deleted task takes along every call whose RESPONSE named it — the event that carried its
    /// question, the list that carried its title — not only the calls that targeted it. A call
    /// naming only other tasks stays.
    func testFullCall_deletingATaskForgetsEveryCallThatNamesIt() async throws {
        let createRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID!, "title": "Doomed title", "brief": "Will be deleted"],
            agent: agentA
        )
        XCTAssertFalse(createRes.isError, createRes.outputJSON)
        let taskID = try XCTUnwrap((try parseJSON(createRes.outputJSON)["data"] as? [String: Any])?["task_id"] as? Int)

        let listRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.listTasks, args: ["folder_id": folderID!], agent: agentA)
        XCTAssertTrue(listRes.outputJSON.contains("Doomed title"), listRes.outputJSON)
        let listRow = try XCTUnwrap(sut.externalActivityLog.records.last)
        XCTAssertNil(listRow.taskID)
        XCTAssertEqual(listRow.namedTaskIDs, [taskID])

        let questionRow = recordWait(naming: [taskID, 4242])
        let otherRow = recordWait(naming: [4242])
        XCTAssertEqual(questionRow.namedTaskIDs, [taskID, 4242])

        await sut.removeTask(taskID)
        sut.externalActivityLog.flush()

        let gone: Set<UUID> = [listRow.id, questionRow.id]
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.isDisjoint(with: gone))
        XCTAssertTrue(filesOnDisk(callsDir).isDisjoint(with: gone), "its title and question are off the disk")
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.contains(otherRow.id))
        XCTAssertTrue(filesOnDisk(callsDir).contains(otherRow.id))
    }

    /// A call about a task that completes after the task was deleted — it was in flight — keeps
    /// no body; its row is recorded all the same.
    func testFullCall_aCallInFlightWhenItsTaskIsDeletedKeepsNoBody() async throws {
        let createRes = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID!, "title": "Gone", "brief": "x"],
            agent: agentA
        )
        let taskID = try XCTUnwrap((try parseJSON(createRes.outputJSON)["data"] as? [String: Any])?["task_id"] as? Int)
        await sut.removeTask(taskID)

        let late = recordWait(naming: [taskID])
        let unrelated = recordWait(naming: [4242])
        sut.externalActivityLog.flush()
        XCTAssertTrue(sut.externalActivityLog.records.contains { $0.id == late.id }, "the row is recorded")
        XCTAssertFalse(sut.externalActivityLog.fullCallIDs.contains(late.id))
        XCTAssertFalse(filesOnDisk(callsDir).contains(late.id))
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.contains(unrelated.id))
    }

    /// The deleted ids live as long as the armed folder: a reset restarts task ids, and a new
    /// task holding an old number keeps its calls.
    func testFullCall_deletedTaskIDsDoNotOutliveTheFolder() async throws {
        let logURL = tempDir.appendingPathComponent("tomb/external_activity.jsonl")
        let log = ExternalAutovisorActivityLog()
        log.activateFolder(logURL: logURL)
        log.forgetFullCalls(forTaskID: 7)
        let during = record(taskID: 7)
        log.record(during, fullCall: call("during"))
        XCTAssertFalse(log.fullCallIDs.contains(during.id))

        log.disarmForFolderTransition()
        log.activateFolder(logURL: logURL)
        let after = record(taskID: 7)
        log.record(after, fullCall: call("after"))
        XCTAssertTrue(log.fullCallIDs.contains(after.id))
        log.flush()
    }

    /// Every place a response names a task: an event, a list row, a delegated child, a `next`
    /// hint. An `id` outside `tasks`, a null, a string are not task ids.
    func testNamedTaskIDs_readsEveryPlaceAResponseNamesATask() async throws {
        let response = try parseJSON(#"""
        {"ok":true,
         "data":{"events":[{"seq":1,"task_id":3,"kind":"question"},{"seq":2,"task_id":4}],
                 "tasks":[{"id":5,"title":"a"},{"id":6}],
                 "steps":[{"role_id":"r","delegated_task_id":7},{"delegated_task_id":null}],
                 "teams":[{"id":99}],
                 "folder_id":"f","task_id":"8"},
         "next":{"tool":"control_task","arguments":{"task_id":9}}}
        """#)
        XCTAssertEqual(NTMSOrchestrator.namedTaskIDs(inResponse: response), [3, 4, 5, 6, 7, 9])
        XCTAssertTrue(NTMSOrchestrator.namedTaskIDs(inResponse: try parseJSON(#"{"ok":false,"error":{"code":"X"}}"#)).isEmpty)
    }

    /// A torn line costs that line, not the file; a title holding U+2028 is one line, not two.
    func testActivation_aTornLineCostsThatLineNotTheFile() async throws {
        let logURL = tempDir.appendingPathComponent("torn/external_activity.jsonl")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var first = record(tool: "first")
        first.taskTitle = "Отчёт\u{2028}за неделю"
        let second = record(tool: "second")
        let encoder = JSONCoderFactory.makeJSONLEncoder()
        var bytes = try encoder.encode(first) + Data([0x0A]) + encoder.encode(second) + Data([0x0A])
        bytes += Data(#"{"id":"Отч"#.utf8).dropLast(1)            // a crash mid-character
        try bytes.write(to: logURL)

        let reader = ExternalAutovisorActivityLog()
        reader.activateFolder(logURL: logURL)
        XCTAssertEqual(reader.records.map(\.tool), ["first", "second"])
        XCTAssertEqual(reader.records.first?.taskTitle, "Отчёт\u{2028}за неделю")
    }

    /// A newest file that reads as nothing is a failed read even when the backup reads: the rows
    /// it held keep their bodies for the read that succeeds.
    func testFullCall_aBrokenNewestFileWithAReadableBackupDeletesNoBody() async throws {
        let logURL = tempDir.appendingPathComponent("halfbroken/external_activity.jsonl")
        let dir = ExternalAutovisorActivityLog.callsDirectoryURL(for: logURL)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let inBackup = record()
        let inNewest = record()
        try (JSONCoderFactory.makeJSONLEncoder().encode(inBackup) + Data([0x0A]))
            .write(to: URL(fileURLWithPath: logURL.path + ".1"))
        try Data("not a record\n".utf8).write(to: logURL)
        XCTAssertTrue(ExternalAutovisorFullCallStore.write(
            ExternalAutovisorFullCall(id: inBackup.id, arguments: "{}", response: "{}"), in: dir, fileManager: .default))
        XCTAssertTrue(ExternalAutovisorFullCallStore.write(
            ExternalAutovisorFullCall(id: inNewest.id, arguments: "{}", response: "{}"), in: dir, fileManager: .default))

        let reader = ExternalAutovisorActivityLog()
        reader.activateFolder(logURL: logURL)
        reader.flush()
        XCTAssertEqual(reader.records.map(\.id), [inBackup.id])
        XCTAssertEqual(reader.fullCallIDs, [inBackup.id])
        XCTAssertEqual(filesOnDisk(dir), [inBackup.id, inNewest.id])
    }

    /// Records a `wait_for_events` whose events name `taskIDs`, as the recorder would.
    @discardableResult
    private func recordWait(naming taskIDs: [Int]) -> ExternalAutovisorActivityRecord {
        let events = taskIDs.enumerated()
            .map { #"{"seq":\#($0.offset),"task_id":\#($0.element),"kind":"question","title":"T","question":"Q?"}"# }
            .joined(separator: ",")
        let body = #"{"ok":true,"data":{"folder_id":"f","events":[\#(events)]}}"#
        sut.recordExternalAutovisorActivity(
            tool: ExternalAutovisorToolNames.waitForEvents,
            args: ["folder_id": folderID!],
            agent: agentA,
            preCallRoleID: nil,
            result: ToolExecutionResult(toolName: ExternalAutovisorToolNames.waitForEvents, argumentsJSON: "{}", outputJSON: body, isError: false),
            durationMs: 1,
            now: Date(),
            within: sut.currentFolderLifecycle
        )
        return sut.externalActivityLog.records.last!
    }

    /// Disarming forgets the set; the files stay for the folder's next open.
    func testFullCall_disarmForgetsTheSet() async throws {
        _ = await sut.executeExternalAutovisorTool(name: ExternalAutovisorToolNames.folderStatus, args: [:], agent: agentA)
        let id = try XCTUnwrap(sut.externalActivityLog.records.last?.id)
        sut.externalActivityLog.disarmForFolderTransition()
        sut.externalActivityLog.flush()
        XCTAssertTrue(sut.externalActivityLog.fullCallIDs.isEmpty)
        let read = await sut.externalActivityLog.fullCall(id: id)
        XCTAssertNil(read)
        XCTAssertEqual(filesOnDisk(callsDir), [id])
    }

    // MARK: - What a wait row shows (2026-11-09)

    /// A row shows the part of the cursor that tells two waits apart — epoch, position, filter —
    /// not the folder id every cursor of the folder starts with, which was all a 40-character
    /// excerpt left.
    func testWaitRow_showsTheCursorPastItsFolderID() async throws {
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        _ = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.waitForEvents,
            args: ["folder_id": folderID!, "after": cursor, "timeout_seconds": 0],
            agent: agentA)
        let row = try XCTUnwrap(sut.externalActivityLog.tail(limit: 1).first)
        let tail = String(cursor.dropFirst(folderID.count + 1))
        XCTAssertTrue(row.argumentsSummary.contains("after=\(tail)"), row.argumentsSummary)
        XCTAssertFalse(row.argumentsSummary.contains(folderID), row.argumentsSummary)

        XCTAssertEqual(NTMSOrchestrator.cursorTail("\(folderID!):abc.2:7:1,2"), "abc.2:7:1,2")
        XCTAssertEqual(NTMSOrchestrator.cursorTail("not-a-cursor"), "not-a-cursor")
        XCTAssertEqual(NTMSOrchestrator.cursorTail("a:b:c"), "a:b:c", "no folder id, shown as it came")
    }

    /// A wait the agent withdrew got no answer: its row says so instead of "no events".
    func testCancelledWait_readsCancelled_andAnAnsweredOneDoesNot() {
        let empty = #"{"ok":true,"data":{"folder_id":"f","events":[],"timed_out":false}}"#
        func record(cancelled: Bool) -> ExternalAutovisorActivityRecord {
            sut.recordExternalAutovisorActivity(
                tool: ExternalAutovisorToolNames.waitForEvents,
                args: ["folder_id": folderID!],
                agent: agentA,
                preCallRoleID: nil,
                result: ToolExecutionResult(
                    toolName: ExternalAutovisorToolNames.waitForEvents, argumentsJSON: "{}", outputJSON: empty, isError: false),
                durationMs: 1,
                now: Date(),
                cancelled: cancelled,
                within: sut.currentFolderLifecycle
            )
            return sut.externalActivityLog.records.last!
        }
        XCTAssertEqual(record(cancelled: true).outcomeSummary, "cancelled")
        XCTAssertEqual(record(cancelled: false).outcomeSummary, "no events")
    }
}
