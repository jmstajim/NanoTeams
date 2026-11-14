import XCTest
@testable import NanoTeams

@MainActor
final class AutovisorCommandLayerTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - 1. JSONSchema minimum / maximum & allSchemas byte pin

    func testJSONSchema_minimumAndMaximum_encodeOnlyWhenPresent_andEnforceViolations() throws {
        // Every built-in schema in `ToolHandlerRegistry.allSchemas` has nil minimum/maximum
        // and must encode without `"minimum"` or `"maximum"` keys.
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let encodedAll = try encoder.encode(ToolHandlerRegistry.allSchemas)
        let encodedAllString = try XCTUnwrap(String(data: encodedAll, encoding: .utf8))
        XCTAssertFalse(encodedAllString.contains("\"minimum\""))
        XCTAssertFalse(encodedAllString.contains("\"maximum\""))

        // When minimum / maximum ARE set, they encode and round-trip, and `argumentTypeViolations`
        // enforces them on integer arguments.
        let boundedSchema = JSONSchema.object(
            properties: [
                "timeout_seconds": JSONSchema.integer("Wait timeout.", minimum: 0, maximum: 3600),
                "interval_minutes": JSONSchema.integer("Interval.", minimum: 0),
                "limit": JSONSchema.integer("Max rows.", minimum: nil, maximum: 200),
            ],
            required: []
        )
        let boundedData = try encoder.encode(boundedSchema)
        let boundedJSON = try XCTUnwrap(String(data: boundedData, encoding: .utf8))
        XCTAssertTrue(boundedJSON.contains("\"minimum\" : 0") || boundedJSON.contains("\"minimum\":0"))
        XCTAssertTrue(boundedJSON.contains("\"maximum\" : 3600") || boundedJSON.contains("\"maximum\":3600"))

        let decodedSchema = try JSONDecoder().decode(JSONSchema.self, from: boundedData)
        XCTAssertEqual(decodedSchema, boundedSchema)

        XCTAssertEqual(
            argumentTypeViolations(
                args: ["timeout_seconds": 50, "interval_minutes": 0, "limit": 200],
                schema: boundedSchema
            ),
            []
        )

        let violations = argumentTypeViolations(
            args: ["timeout_seconds": 3601, "interval_minutes": -1, "limit": 201],
            schema: boundedSchema
        )
        XCTAssertEqual(violations.count, 3, "got: \(violations)")
        guard violations.count == 3 else { return }
        XCTAssertTrue(violations[0].contains("`interval_minutes`") && violations[0].contains("0"), violations[0])
        XCTAssertTrue(violations[1].contains("`limit`") && violations[1].contains("200"), violations[1])
        XCTAssertTrue(violations[2].contains("`timeout_seconds`") && violations[2].contains("0") && violations[2].contains("3600"), violations[2])
    }

    // MARK: - 2. AutovisorCommand <-> ToolSignal bijection

    /// The three reads are answered by renderers, not by `performAutovisorAction`, so they map to
    /// no action — and every write does. `AutovisorCommandExecutor` relies on both halves.
    func testAutovisorCommand_readsMapToNoAction_andEveryWriteToOne() {
        XCTAssertNil(AutovisorCommand.listTasks.autovisorAction)
        XCTAssertNil(AutovisorCommand.taskStatus(taskID: 4).autovisorAction)
        XCTAssertNil(AutovisorCommand.waitForEvents.autovisorAction)

        let writes: [AutovisorCommand] = [
            .createManagedTask(title: "T", brief: "B", teamID: nil),
            .controlTask(taskID: 4, verb: .pause),
            .manageRole(taskID: 4, roleID: "eng", verb: .accept),
            .answerTaskQuestion(taskID: 4, answer: "Yes", roleID: nil),
            .messageTask(taskID: 4, text: "Hello", roleID: nil),
            .scheduleTask(taskID: 4, intervalMinutes: 30),
            .setWorkFolderContext(content: "Context"),
        ]
        for write in writes {
            XCTAssertNotNil(write.autovisorAction, "\(write)")
        }
    }

    func testAutovisorCommand_roundTripsAllTenAutovisorSignals_andRejectsNonAutovisorSignals() {
        let allTenSignals: [(ToolSignal, AutovisorCommand)] = [
            (.listTasks, .listTasks),
            (.taskStatus(taskID: 7), .taskStatus(taskID: 7)),
            (.createManagedTask(title: "Title", brief: "Brief", teamID: "faang"),
             .createManagedTask(title: "Title", brief: "Brief", teamID: "faang")),
            (.controlTask(taskID: 3, verb: .pause), .controlTask(taskID: 3, verb: .pause)),
            (.manageRole(taskID: 3, roleID: "swe", verb: .accept),
             .manageRole(taskID: 3, roleID: "swe", verb: .accept)),
            (.answerTaskQuestion(taskID: 4, answer: "Yes"),
             .answerTaskQuestion(taskID: 4, answer: "Yes", roleID: nil)),
            (.messageTask(taskID: 5, text: "Hurry", roleID: "pm"),
             .messageTask(taskID: 5, text: "Hurry", roleID: "pm")),
            (.scheduleTask(taskID: 6, intervalMinutes: 15),
             .scheduleTask(taskID: 6, intervalMinutes: 15)),
            (.setWorkFolderContext(content: "Swift 6 macOS app."),
             .setWorkFolderContext(content: "Swift 6 macOS app.")),
            (.waitForEvents, .waitForEvents),
        ]

        for (signal, expectedCommand) in allTenSignals {
            let decoded = AutovisorCommand(signal: signal)
            XCTAssertEqual(decoded, expectedCommand)
            XCTAssertEqual(decoded?.toolSignal, signal)
            XCTAssertTrue(LLMExecutionService.isAutovisorSignal(signal))
        }

        XCTAssertNil(AutovisorCommand(signal: nil))
        XCTAssertNil(AutovisorCommand(signal: .supervisorQuestion("Why?")))
        XCTAssertFalse(LLMExecutionService.isAutovisorSignal(.supervisorQuestion("Why?")))
    }

    // MARK: - 3. Parity between .inApp and .externalMCP decoding across the shared tools

    func testAutovisorToolDecoding_sharedTools_haveParityAcrossInAppAndExternalSurfaces() {
        let validCases: [(tool: String, rawJSON: String, expected: AutovisorCommand)] = [
            (ToolNames.listTasks, #"{"":""}"#, .listTasks),
            (ToolNames.taskStatus, #"{"task_id": "12"}"#, .taskStatus(taskID: 12)),
            (ToolNames.createManagedTask,
             #"{"title": null, "brief": "Implement OAuth token refresh\nDetails here", "team_id": "faang"}"#,
             .createManagedTask(
                 title: "Implement OAuth token refresh",
                 brief: "Implement OAuth token refresh\nDetails here",
                 teamID: "faang")),
            (ToolNames.controlTask,
             #"{"task_id": 4, "action": "SET_TIMEOUT", "timeout_seconds": 120}"#,
             .controlTask(taskID: 4, verb: .setTimeout(seconds: 120))),
            (ToolNames.manageRole,
             #"{"task_id": 4, "role_id": " swe ", "action": "request_changes", "comment": "Fix tests"}"#,
             .manageRole(taskID: 4, roleID: "swe", verb: .requestChanges(comment: "Fix tests"))),
            (ToolNames.answerTaskQuestion,
             #"{"task_id": 8, "answer": "  Use SQLite  "}"#,
             .answerTaskQuestion(taskID: 8, answer: "Use SQLite", roleID: nil)),
            (ToolNames.messageTask,
             #"{"task_id": 9, "message": "Check edge case", "role_id": "qa"}"#,
             .messageTask(taskID: 9, text: "Check edge case", roleID: "qa")),
            (ToolNames.scheduleTask,
             #"{"task_id": 10, "interval_minutes": 30}"#,
             .scheduleTask(taskID: 10, intervalMinutes: 30)),
            (ToolNames.setWorkFolderContext,
             #"{"content": "  A Swift 6 macOS app.\n"}"#,
             .setWorkFolderContext(content: "  A Swift 6 macOS app.\n")),
            (ToolNames.waitForEvents, #"{}"#, .waitForEvents),
        ]

        for c in validCases {
            let inApp = AutovisorToolDecoding.decode(tool: c.tool, rawArgs: c.rawJSON, surface: .inApp)
            let external = AutovisorToolDecoding.decode(tool: c.tool, rawArgs: c.rawJSON, surface: .externalMCP)
            XCTAssertEqual(inApp, .success(c.expected), "inApp failed for \(c.tool)")
            XCTAssertEqual(external, .success(c.expected), "externalMCP failed for \(c.tool)")
        }

        // Invalid-argument cases: both surfaces must produce byte-identical INVALID_ARGS envelopes.
        let invalidCases: [(tool: String, rawJSON: String)] = [
            (ToolNames.taskStatus, #"{}"#),
            (ToolNames.taskStatus, #"{"task_id": "abc"}"#),
            (ToolNames.createManagedTask, #"{"title": "T", "brief": "   "}"#),
            (ToolNames.controlTask, #"{"task_id": 3, "action": "rename"}"#),
            (ToolNames.controlTask, #"{"task_id": 3, "action": "launch"}"#),
            (ToolNames.manageRole, #"{"task_id": 3, "role_id": "swe", "action": "request_changes"}"#),
            (ToolNames.answerTaskQuestion, #"{"task_id": 3, "answer": "   "}"#),
            (ToolNames.messageTask, #"{"task_id": 3, "message": ""}"#),
            (ToolNames.scheduleTask, #"{"task_id": 3, "interval_minutes": -5}"#),
            (ToolNames.setWorkFolderContext, #"{"content": " \n "}"#),
        ]

        for c in invalidCases {
            let inApp = AutovisorToolDecoding.decode(tool: c.tool, rawArgs: c.rawJSON, surface: .inApp)
            let external = AutovisorToolDecoding.decode(tool: c.tool, rawArgs: c.rawJSON, surface: .externalMCP)
            guard case .failure(let inAppErr) = inApp,
                  case .failure(let extErr) = external else {
                XCTFail("Expected both surfaces to fail for \(c.tool) \(c.rawJSON)")
                continue
            }
            XCTAssertTrue(inAppErr.isError)
            XCTAssertTrue(inAppErr.outputJSON.contains(ToolErrorCode.invalidArgs.rawValue))
            XCTAssertEqual(inAppErr.outputJSON, extErr.outputJSON, "Envelope mismatch for \(c.tool)")
        }

        // Surface-specific differences:
        // 1) `answer_task_question` on `.externalMCP` extracts optional `role_id`.
        let extTargetedAnswer = AutovisorToolDecoding.decode(
            tool: ToolNames.answerTaskQuestion,
            rawArgs: #"{"task_id": 8, "answer": "Proceed", "role_id": "architect"}"#,
            surface: .externalMCP
        )
        XCTAssertEqual(
            extTargetedAnswer,
            .success(.answerTaskQuestion(taskID: 8, answer: "Proceed", roleID: "architect"))
        )

        // 2) `set_work_folder_context` decodes on both since 2026-11-13 (A3 revised): whether an
        //    external agent may replace the context is its handler's question, not the decoder's.
        XCTAssertNotNil(AutovisorToolDecoding.schema(for: ToolNames.setWorkFolderContext))
    }

    // MARK: - 4. AutovisorTeamPolicy surface-specific refusal hints

    func testAutovisorTeamPolicy_failureMessage_adaptsRemedyToSurface() {
        let eng = TeamTemplateFactory.empty(name: "Engineering")
        let policy = AutovisorTeamPolicy(allowGeneration: false)

        let inAppMsg = policy.failureMessage(
            for: .unknown("bad-id"),
            allTeams: [eng],
            omitPathIsViable: false,
            surface: .inApp
        )
        let extMsg = policy.failureMessage(
            for: .unknown("bad-id"),
            allTeams: [eng],
            omitPathIsViable: false,
            surface: .externalMCP
        )

        XCTAssertEqual(
            inAppMsg,
            "Unknown team_id 'bad-id'. Instead, pick a team id from the catalog in create_managed_task's description."
        )
        XCTAssertEqual(
            extMsg,
            "Unknown team_id 'bad-id'. Instead, pick a team id returned by list_teams."
        )

        let emptyInApp = policy.failureMessage(
            for: .generationDisabled,
            allTeams: [],
            omitPathIsViable: false,
            surface: .inApp
        )
        let emptyExt = policy.failureMessage(
            for: .generationDisabled,
            allTeams: [],
            omitPathIsViable: false,
            surface: .externalMCP
        )
        XCTAssertTrue(emptyInApp?.contains("report that to your Supervisor") == true)
        XCTAssertTrue(emptyExt?.contains("ask the user") == true)
    }

    // MARK: - 4b. Every tool with a schema decodes to its own command

    /// The tool a decoded command belongs to, by the compiler: a new command does not build here
    /// until it is named.
    private func toolName(of command: AutovisorCommand) -> String {
        switch command {
        case .listTasks: ToolNames.listTasks
        case .taskStatus: ToolNames.taskStatus
        case .createManagedTask: ToolNames.createManagedTask
        case .controlTask: ToolNames.controlTask
        case .manageRole: ToolNames.manageRole
        case .answerTaskQuestion: ToolNames.answerTaskQuestion
        case .messageTask: ToolNames.messageTask
        case .scheduleTask: ToolNames.scheduleTask
        case .setWorkFolderContext: ToolNames.setWorkFolderContext
        case .waitForEvents: ToolNames.waitForEvents
        }
    }

    /// The property the decoder's failing default defends: every tool `schema(for:)` admits
    /// decodes, on that surface, to the command of THAT tool, and every other name is refused. A
    /// tool given a schema but no decode case would reach the default instead — an assertion in
    /// DEBUG, a refusal in release. No seam reaches the default while the two lists agree, so this
    /// census over every tool name the app knows is its pin.
    func testAutovisorToolDecoding_everyToolWithASchemaDecodesToItsOwnCommand() {
        let validArguments: [String: [String: Any]] = [
            ToolNames.listTasks: [:],
            ToolNames.taskStatus: ["task_id": 1],
            ToolNames.createManagedTask: ["title": "Title", "brief": "Brief"],
            ToolNames.controlTask: ["task_id": 1, "action": "pause"],
            ToolNames.manageRole: ["task_id": 1, "role_id": "swe", "action": "accept"],
            ToolNames.answerTaskQuestion: ["task_id": 1, "answer": "Yes"],
            ToolNames.messageTask: ["task_id": 1, "message": "Hello"],
            ToolNames.scheduleTask: ["task_id": 1, "interval_minutes": 5],
            ToolNames.setWorkFolderContext: ["content": "Swift 6 app."],
            ToolNames.waitForEvents: [:],
        ]
        let candidates = ToolNames.allNames
            .union(ExternalAutovisorToolNames.all)
            .union(["not_a_tool"])
            .sorted()
        var admitted: [AutovisorSurface: Set<String>] = [:]
        for surface in AutovisorSurface.allCases {
            for tool in candidates {
                guard AutovisorToolDecoding.schema(for: tool) != nil else {
                    guard case .failure(let refusal) = AutovisorToolDecoding.decode(
                        tool: tool, args: [:], surface: surface)
                    else {
                        XCTFail("\(tool) has no schema on \(surface) yet decoded")
                        continue
                    }
                    XCTAssertTrue(refusal.isError)
                    XCTAssertTrue(
                        refusal.outputJSON.contains("is not available on this surface"),
                        "\(tool) on \(surface): \(refusal.outputJSON)")
                    continue
                }
                admitted[surface, default: []].insert(tool)
                guard let args = validArguments[tool] else {
                    XCTFail("\(tool) gained a schema on \(surface): give it valid arguments in this census")
                    continue
                }
                switch AutovisorToolDecoding.decode(tool: tool, args: args, surface: surface) {
                case .success(let command):
                    XCTAssertEqual(toolName(of: command), tool, "\(tool) on \(surface) decoded as another tool's command")
                case .failure(let failure):
                    XCTFail("\(tool) on \(surface) refused valid arguments: \(failure.outputJSON)")
                }
            }
        }
        XCTAssertEqual(
            admitted[.inApp], Set(AutovisorConstants.managerMandatoryToolIDs),
            "the in-app surface decodes the manager's tools, and only those")
        XCTAssertEqual(
            admitted[.externalMCP], Set(AutovisorConstants.managerMandatoryToolIDs),
            "every shared tool decodes on the external surface too — set_work_folder_context since 2026-11-13")
    }

    /// The decoder's two refusals that do not come from an argument's value: a name it has no
    /// schema for, and arguments that are not a JSON object.
    func testAutovisorToolDecoding_refusesAnUnknownToolAndNonObjectArguments() throws {
        XCTAssertNil(AutovisorToolDecoding.schema(for: "unknown_tool"))
        guard case .failure(let unknown) = AutovisorToolDecoding.decode(tool: "unknown_tool", args: [:]) else {
            return XCTFail("an unknown tool must be refused")
        }
        let unknownError = try errorObject(of: unknown.outputJSON)
        XCTAssertEqual(unknownError["code"] as? String, ToolErrorCode.invalidArgs.rawValue)
        XCTAssertEqual(
            unknownError["message"] as? String,
            "Tool 'unknown_tool' is not available on this surface. Check the tool list and retry.")

        guard case .failure(let nonObject) = AutovisorToolDecoding.decode(
            tool: ToolNames.listTasks, rawArgs: "[1, 2]")
        else {
            return XCTFail("non-object arguments must be refused")
        }
        let nonObjectError = try errorObject(of: nonObject.outputJSON)
        XCTAssertEqual(
            nonObjectError["message"] as? String,
            ToolRuntimeError.argumentsNotObject.errorDescription)
    }

    // MARK: - 5. AutovisorCommandExecutor routes each command to its own handler

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], json)
    }

    private func successData(of json: String) throws -> [String: Any] {
        let envelope = try jsonObject(json)
        XCTAssertEqual(envelope["ok"] as? Bool, true, json)
        return try XCTUnwrap(envelope["data"] as? [String: Any], json)
    }

    private func errorObject(of json: String) throws -> [String: Any] {
        let envelope = try jsonObject(json)
        XCTAssertEqual(envelope["ok"] as? Bool, false, json)
        return try XCTUnwrap(envelope["error"] as? [String: Any], json)
    }

    /// Each command lands on its own handler, and the envelope says which: the roster is
    /// `list_tasks`'s alone, one task's record is `task_status`'s, the park is `wait_for_events`'s
    /// — on the step the executor was handed — and an action is applied. An executor that routed
    /// by falling through would hand any of them to `list_tasks`, which these keys tell apart.
    func testAutovisorCommandExecutor_routesEachCommandToItsOwnHandler_andHonorsCapturedLifecycle() async throws {
        await sut.openWorkFolder(tempDir)
        let folderB = tempDir.deletingLastPathComponent()
            .appendingPathComponent("NanoTeams-folderB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        let rawTaskID = await sut.createTask(title: "Sample Task", supervisorTask: "Brief", makeActive: false)
        let taskID = try XCTUnwrap(rawTaskID)
        let service = sut.llmExecutionService
        let executor = AutovisorCommandExecutor(executionService: service, delegate: sut)
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_100)

        let listEnvelope = await executor.execute(.listTasks, now: fixedNow)
        let list = try successData(of: listEnvelope)
        let rows = try XCTUnwrap(list["tasks"] as? [[String: Any]], listEnvelope)
        XCTAssertEqual(rows.compactMap { $0["title"] as? String }, ["Sample Task"])
        XCTAssertNil(list["task_id"], "a roster is not one task's record")

        let statusEnvelope = await executor.execute(.taskStatus(taskID: taskID), now: fixedNow)
        let status = try successData(of: statusEnvelope)
        XCTAssertEqual(status["task_id"] as? Int, taskID)
        XCTAssertEqual(status["title"] as? String, "Sample Task")
        XCTAssertNil(status["tasks"], "one task's record is not a roster")

        let stepKey = TaskStepKey(taskID: taskID, stepID: "mgr-step")
        service.executionStates[stepKey] = LLMExecutionService.StepExecutionState()
        defer { service.executionStates.removeValue(forKey: stepKey) }
        let parkEnvelope = await executor.execute(.waitForEvents, stepID: "mgr-step", taskID: taskID, now: fixedNow)
        let park = try successData(of: parkEnvelope)
        XCTAssertEqual(park["status"] as? String, "idle — will resume on supervisor message or events")
        XCTAssertNil(park["tasks"])
        XCTAssertEqual(
            service.executionStates[stepKey]?.parkForEventsRequested, true,
            "the park is requested on the step the executor was handed")

        let contextEnvelope = await executor.execute(.setWorkFolderContext(content: "Swift 6 app."), now: fixedNow)
        let context = try successData(of: contextEnvelope)
        XCTAssertEqual(context["message"] as? String, AutovisorReply.workFolderContextUpdated.text)
        XCTAssertNil(context["tasks"])
        XCTAssertEqual(sut.snapshot?.workFolder.settings.context, "Swift 6 app.")

        // A write executed against a lifecycle captured before a folder switch is answered as the
        // folder change, and lands in neither folder.
        let capturedLifecycle = sut.currentFolderLifecycle
        await sut.openWorkFolder(folderB)
        let renameEnvelope = await executor.execute(
            .controlTask(taskID: taskID, verb: .rename(title: "Should Not Land")),
            within: capturedLifecycle,
            now: fixedNow
        )
        XCTAssertEqual(try errorObject(of: renameEnvelope)["message"] as? String, DeferredCallReplies.folderChanged)
        await sut.openWorkFolder(tempDir)
        await sut.ensureTaskLoaded(taskID)
        XCTAssertEqual(sut.loadedTask(taskID)?.title, "Sample Task")

        let nilExec = AutovisorCommandExecutor(executionService: nil)
        let nilEnvelope = await nilExec.execute(.listTasks, now: fixedNow)
        let nilError = try errorObject(of: nilEnvelope)
        XCTAssertEqual(nilError["code"] as? String, ToolErrorCode.commandFailed.rawValue)
        XCTAssertEqual(nilError["message"] as? String, LLMExecutionService.autovisorUnavailableMessage)

        let sig = ExternalAutovisorReadinessSignal()
        let sigTask = Task { @MainActor in await sig.wait() }
        await Task.yield()
        sigTask.cancel()
        let sigReason = await sigTask.value
        XCTAssertEqual(sigReason, .shuttingDown)
    }

    // MARK: - 6. Value helpers render what they document

    func testValueHelpers_renderWhatTheyDocument() async throws {
        // JSONValue's numeric views.
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertNil(JSONValue.double(3.5).intValue)
        XCTAssertEqual(JSONValue.int(5).doubleValue, 5.0)
        XCTAssertEqual(JSONValue.double(2.5).doubleValue, 2.5)
        XCTAssertNil(JSONValue.string("x").doubleValue)

        // The feed label of an attributed answer names its author.
        let msgWithAuthor = LLMMessage(
            role: .user,
            content: "Answer",
            sourceContext: .supervisorAnswer,
            authorLabel: "Claude Code"
        )
        XCTAssertEqual(msgWithAuthor.sourceContextDisplayLabel, "supervisor answer · Claude Code")
        let consultMsg = LLMMessage(
            role: .user,
            content: "Consult",
            sourceContext: .consultation
        )
        XCTAssertEqual(consultMsg.sourceContextDisplayLabel, "consultation")

        // Timeline summaries of an external agent's decisions.
        let evRole = SupervisorTimelineEvent(
            kind: .roleAccepted,
            authorLabel: "Claude Code",
            roleID: "swe"
        )
        XCTAssertEqual(evRole.summaryText(roleName: "Software Engineer"), "Claude Code accepted Software Engineer")
        XCTAssertEqual(evRole.summaryText(roleName: nil), "Claude Code accepted")
        let evClosed = SupervisorTimelineEvent(
            kind: .taskClosed,
            authorLabel: "Claude Code"
        )
        XCTAssertEqual(evClosed.summaryText(), "Claude Code closed task")

        // A delivery holding two authors' messages gives each its own turn (DEBTS D-M15) — until
        // 2026-11-07 it merged them into one turn that claimed neither. The wire is one section.
        let q1 = NTMSOrchestrator.QueuedDeliveryEntry(
            kind: .supervisorSpeech,
            body: "First",
            isRedelivery: false,
            authorLabel: "Claude Code"
        )
        let q2 = NTMSOrchestrator.QueuedDeliveryEntry(
            kind: .supervisorSpeech,
            body: "Second",
            isRedelivery: false,
            authorLabel: "Supervisor"
        )
        let composed = NTMSOrchestrator.composeQueuedDelivery([q1, q2])
        XCTAssertEqual(composed.displayTurns.map(\.authorLabel), ["Claude Code", "Supervisor"])
        XCTAssertEqual(composed.wirePrompt, MessageSourceContext.supervisorMessagePrefix + "First\nSecond")

        // A repetitive-failure warning with no error code.
        let sig = LLMExecutionService.loopWarningSignature(
            .repetitiveFailure(tool: "read_file", count: 3, errorCode: nil),
            epoch: 1
        )
        XCTAssertEqual(sig, "failing:read_file:-@1")
        let warn = LLMExecutionService.loopWarningMessage(
            loopDetection: .repetitiveFailure(tool: "read_file", count: 3, errorCode: nil),
            allowedToolNames: ["read_file"]
        )
        XCTAssertTrue(warn.contains("read_file"))

        // TaskOrigin's predicates.
        XCTAssertFalse(TaskOrigin.externalAgent(AgentIdentity(id: UUID(), label: "A")).isBuiltInAutovisor)
        XCTAssertFalse(TaskOrigin.builtInAutovisor.isExternalAgent)
        XCTAssertFalse(TaskOrigin.builtInAutovisor.matchesExternalAgent(UUID()))
        XCTAssertNil(TaskOrigin.builtInAutovisor.externalAgentIdentity)

        // An origin kind this build does not know: `TaskOrigin` refuses it as corrupted data — the
        // unknown-kind branch, not a missing `kind` key — and a task row that carries one still
        // decodes, with no origin, rather than failing whole.
        XCTAssertThrowsError(
            try JSONDecoder().decode(TaskOrigin.self, from: Data(#"{"kind":"unknown_origin"}"#.utf8))
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("an unknown kind must be refused as corrupted data, not as \(error)")
            }
        }
        let row = try JSONDecoder().decode(
            TaskSummary.self,
            from: Data(#"{"id":7,"title":"Fix login","origin":{"kind":"unknown_origin"}}"#.utf8))
        XCTAssertEqual(row.id, 7)
        XCTAssertEqual(row.title, "Fix login")
        XCTAssertNil(row.origin)

        XCTAssertFalse(BashSecurityWarning.sandboxDisabled(externalAgentActive: false).message.isEmpty)
        XCTAssertFalse(BashSecurityWarning.unsandboxedFallbackEnabled(externalAgentActive: false).message.isEmpty)
        XCTAssertEqual(HostedMCPCatalog.toolDescription(for: "unknown"), "External Autovisor tool.")

        // JSONValue refuses a property-list type JSON cannot carry, and a literal's later
        // duplicate key wins.
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["date": Date()],
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(try PropertyListDecoder().decode([String: JSONValue].self, from: plistData))
        let dupDict: JSONValue = ["dup": "first", "dup": "second"]
        XCTAssertEqual(dupDict["dup"]?.stringValue, "second")

        XCTAssertEqual(
            HostedMCPEnvironment.resolveServerPort(environment: [:], configuredPort: 80),
            HostedMCPConstants.defaultPort
        )
    }

    // MARK: - 7. External Agents settings

    func testStoreConfiguration_externalAgentsPort_clampsAndSurvivesAReload() async {
        let memStorage = InMemoryConfigurationStorage()
        let cfg = StoreConfiguration(storage: memStorage)
        XCTAssertFalse(cfg.externalAgentsEnabled)
        cfg.externalAgentsEnabled = true
        XCTAssertTrue(cfg.externalAgentsEnabled)
        cfg.externalAgentsPort = 80
        XCTAssertEqual(cfg.externalAgentsPort, 1024)
        cfg.externalAgentsPort = 48000
        XCTAssertEqual(cfg.externalAgentsPort, 48000)
        // A configuration read back from the same storage keeps the port that was stored.
        let cfgReloaded = StoreConfiguration(storage: memStorage)
        XCTAssertEqual(cfgReloaded.externalAgentsPort, 48000)
        MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort)
        XCTAssertTrue(MCPEndpointPolicy.allows("https://example.com/mcp", hostedServerPort: 47321))
    }

    func testSkillBodies_withNoRoleSkillsCatalogue_areEmpty() async {
        sut.roleSkills = nil
        let emptySkills = await sut.skillBodies(forIDs: ["any"])
        XCTAssertTrue(emptySkills.isEmpty)
    }

    // MARK: - 8. manage_role accept reports the outcome of each attempt

    /// Each accept is answered with what happened to it: a role the run does not have, a role not
    /// yet at its gate, an external agent's acceptance on its own task — attributed to it on the
    /// timeline — and the same agent's attempt on a person's task, which its tool seam refuses
    /// before the command layer runs (the action seam refuses it as well — 8b).
    func testManageRoleAccept_reportsTheOutcomeOfEachAttempt() async throws {
        await sut.openWorkFolder(tempDir)
        let agent = AgentIdentity(id: UUID(), label: "Claude Code")
        let team = try XCTUnwrap(sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" }))
        let role = try XCTUnwrap(team.nonSupervisorRoles.first)
        let rawHumanTaskID = await sut.createTask(
            title: "Person's task", supervisorTask: "Brief", preferredTeamID: team.id, makeActive: false)
        let humanTaskID = try XCTUnwrap(rawHumanTaskID)
        await sut.ensureTaskLoaded(humanTaskID)
        let lifecycle = sut.currentFolderLifecycle

        await sut.mutateTask(taskID: humanTaskID) { $0.runs = [] }
        let noRun = await sut.performAutovisorAction(
            .manageRole(taskID: humanTaskID, roleID: role.id, verb: .accept), within: lifecycle)
        XCTAssertFalse(noRun.ok)
        XCTAssertEqual(noRun.message, AutovisorReply.noSuchRole(taskID: humanTaskID, roleID: role.id).text)

        await sut.mutateTask(taskID: humanTaskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution.make(for: role)],
                roleStatuses: [role.id: .working],
                teamID: team.id
            )]
        }
        let unknownRole = await sut.performAutovisorAction(
            .manageRole(taskID: humanTaskID, roleID: "unknown_role_id", verb: .accept), within: lifecycle)
        XCTAssertFalse(unknownRole.ok)
        XCTAssertEqual(unknownRole.message, AutovisorReply.noSuchRole(taskID: humanTaskID, roleID: "unknown_role_id").text)

        let notAtGate = await sut.performAutovisorAction(
            .manageRole(taskID: humanTaskID, roleID: role.id, verb: .accept), within: lifecycle)
        XCTAssertFalse(notAtGate.ok)
        let notAtGateFact = try XCTUnwrap(
            AcceptanceService.validateAcceptance(roleID: role.id, roleStatuses: [role.id: .working]))
        XCTAssertTrue(notAtGate.message.hasPrefix(notAtGateFact), notAtGate.message)
        XCTAssertEqual(sut.loadedTask(humanTaskID)?.runs.last?.roleStatuses[role.id], .working)

        let rawAgentTaskID = await sut.createTask(
            title: "Agent's task", supervisorTask: "Brief", preferredTeamID: team.id, makeActive: false,
            origin: .externalAgent(agent))
        let agentTaskID = try XCTUnwrap(rawAgentTaskID)
        await sut.ensureTaskLoaded(agentTaskID)
        await sut.mutateTask(taskID: agentTaskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution.make(for: role)],
                roleStatuses: [role.id: .needsAcceptance],
                teamID: team.id
            )]
        }
        let accepted = await sut.performAutovisorAction(
            .manageRole(taskID: agentTaskID, roleID: role.id, verb: .accept),
            as: .externalAgent(agent, session: nil),
            within: lifecycle)
        XCTAssertTrue(accepted.ok, accepted.message)
        XCTAssertEqual(accepted.message, AutovisorReply.accepted(taskID: agentTaskID, roleID: role.id).text)
        let acceptedRun = try XCTUnwrap(sut.loadedTask(agentTaskID)?.runs.last)
        XCTAssertEqual(acceptedRun.roleStatuses[role.id], .accepted)
        let acceptance = try XCTUnwrap(acceptedRun.supervisorEvents.last { $0.kind == .roleAccepted })
        XCTAssertEqual(acceptance.authorLabel, "Claude Code")
        XCTAssertEqual(acceptance.roleID, role.id)

        await sut.mutateTask(taskID: humanTaskID) { $0.runs[0].roleStatuses[role.id] = .needsAcceptance }
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
        let foreign = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.manageRole,
            args: ["folder_id": folderID, "task_id": humanTaskID, "role_id": role.id, "action": "accept"],
            agent: agent
        )
        XCTAssertTrue(foreign.isError)
        XCTAssertEqual(
            try errorObject(of: foreign.outputJSON)["message"] as? String,
            NTMSOrchestrator.foreignTaskRefusalMessage(taskID: humanTaskID))
        let untouchedRun = try XCTUnwrap(sut.loadedTask(humanTaskID)?.runs.last)
        XCTAssertEqual(untouchedRun.roleStatuses[role.id], .needsAcceptance, "a refused accept changes nothing")
        XCTAssertFalse(untouchedRun.supervisorEvents.contains { $0.kind == .roleAccepted })
    }

    // MARK: - 8b. An external actor acts only on its own tasks, wherever it enters

    /// The agent supervises the tasks it created and nothing else (A3). The tool seam refuses a
    /// foreign task first (`loadAndVerifyOwnedTask`); the action seam every external write lands
    /// in refuses it too, so a caller that skips the tool seam cannot reach a person's task or
    /// another agent's.
    ///
    /// RED before 2026-11-07: `performAutovisorAction(as: .externalAgent)` asked nothing about
    /// ownership, and a direct call accepted a role on the person's task.
    func testExternalActorOnATaskItDidNotCreate_isRefusedAtTheActionSeam() async throws {
        await sut.openWorkFolder(tempDir)
        let agent = AgentIdentity(id: UUID(), label: "Claude Code")
        let otherAgent = AgentIdentity(id: UUID(), label: "Codex")
        let team = try XCTUnwrap(sut.snapshot?.workFolder.teams.first(where: { $0.templateID == "startup" }))
        let role = try XCTUnwrap(team.nonSupervisorRoles.first)
        var foreignTaskIDs: [Int] = []
        for origin in [TaskOrigin?.none, .externalAgent(otherAgent), .builtInAutovisor] {
            let created = await sut.createTask(
                title: "Not this agent's", supervisorTask: "Brief", preferredTeamID: team.id, makeActive: false,
                origin: origin)
            let taskID = try XCTUnwrap(created)
            await sut.ensureTaskLoaded(taskID)
            await sut.mutateTask(taskID: taskID) { task in
                task.runs = [Run(
                    id: 0,
                    steps: [StepExecution.make(for: role)],
                    roleStatuses: [role.id: .needsAcceptance],
                    teamID: team.id
                )]
            }
            XCTAssertEqual(sut.loadedTask(taskID)?.origin, origin, "premise: the task carries the origin it was created with")
            foreignTaskIDs.append(taskID)
        }
        let lifecycle = sut.currentFolderLifecycle

        for taskID in foreignTaskIDs {
            let accept = await sut.performAutovisorAction(
                .manageRole(taskID: taskID, roleID: role.id, verb: .accept),
                as: .externalAgent(agent, session: nil),
                within: lifecycle)
            XCTAssertFalse(accept.ok, "task #\(taskID): \(accept.message)")
            XCTAssertEqual(accept.message, NTMSOrchestrator.foreignTaskRefusalMessage(taskID: taskID))

            let close = await sut.performAutovisorAction(
                .controlTask(taskID: taskID, verb: .close),
                as: .externalAgent(agent, session: nil),
                within: lifecycle)
            XCTAssertFalse(close.ok, "task #\(taskID): \(close.message)")
            XCTAssertEqual(close.message, NTMSOrchestrator.foreignTaskRefusalMessage(taskID: taskID))

            let task = try XCTUnwrap(sut.loadedTask(taskID))
            XCTAssertEqual(task.runs.last?.roleStatuses[role.id], .needsAcceptance, "task #\(taskID): nothing changed")
            XCTAssertNil(task.closedAt, "task #\(taskID): a refused close leaves the task open")
            XCTAssertFalse(task.runs.last?.supervisorEvents.contains { $0.kind == .roleAccepted } ?? true)
        }
    }

    // MARK: - 9. Revoking an agent off the main thread

    /// `revokeAgent` may run on any thread; its invalidation then reaches the main actor through a
    /// task of its own. Awaiting the agent's open wait is the synchronisation point: it returns
    /// because the revoke cancelled it, not because it timed out.
    func testRevokingAnAgentOffTheMainThread_cancelsItsWaitAndBumpsTheRevision() async throws {
        await sut.openWorkFolder(tempDir)
        let agentStore = sut.hostedMCPAgentStore
        let issued = try agentStore.createAgent(label: "BG-Agent")
        let agentID = issued.record.id
        let feed = sut.autovisorEventFeed
        let cursor = try XCTUnwrap(feed.currentCursor)

        let wait = Task { @MainActor in
            await feed.waitForEvents(agentID: agentID, after: cursor, timeoutSeconds: 30)
        }
        var spins = 0
        while !sut.hasActiveHostedMCPWait(forAgent: agentID), spins < 1_000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertTrue(sut.hasActiveHostedMCPWait(forAgent: agentID), "the wait never registered")
        let revisionBefore = sut.hostedMCPAgentsRevision

        let revoked = await Task.detached { () -> Bool in
            (try? agentStore.revokeAgent(agentID: agentID)) != nil
        }.value
        XCTAssertTrue(revoked)
        let result = await wait.value

        XCTAssertFalse(result.timedOut, "the revoke ended the wait, not its timeout")
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertFalse(result.superseded)
        XCTAssertFalse(sut.hasActiveHostedMCPWait(forAgent: agentID))
        XCTAssertGreaterThan(sut.hostedMCPAgentsRevision, revisionBefore)
        XCTAssertNil(agentStore.agent(id: agentID))
    }

    // MARK: - 10. The hosted server's lifecycle

    func testToolHost_whoseOrchestratorIsGone_refusesTheCall() async {
        var ephemeralOrch: NTMSOrchestrator? = TestOrchestrator.make()
        let deadHost = HostedMCPToolHost(orchestrator: ephemeralOrch!)
        ephemeralOrch = nil
        let deadRes = await deadHost.executeTool(
            name: ExternalAutovisorToolNames.folderStatus,
            arguments: [:],
            agent: AgentIdentity(id: UUID(), label: "Gone"),
            sessionID: nil,
            isCancelled: { false }
        )
        XCTAssertTrue(deadRes.isError)
        XCTAssertTrue(deadRes.outputJSON.contains(ToolErrorCode.commandFailed.rawValue), deadRes.outputJSON)
    }

    /// Starting on the port already held keeps the listener; External Agents blocks that port for
    /// `bash` — on, and since 2026-11-08 off too (#375); a second orchestrator cannot take a held port; and an orchestrator
    /// built with External Agents on starts its server at launch, on the port its environment
    /// names.
    func testHostedMCPServer_lifecycleAcrossPortsOrchestratorsAndLaunch() async throws {
        let bound1 = try await sut.startHostedMCPServer(port: 0)
        let boundSame = try await sut.startHostedMCPServer(port: bound1)
        XCTAssertEqual(boundSame, bound1)
        XCTAssertEqual(sut.activeHostedMCPServerPort, bound1)
        sut.configuration.externalAgentsPort = Int(bound1)
        sut.configuration.externalAgentsEnabled = true
        XCTAssertEqual(sut.seatbeltHostedMCPPort, bound1)
        sut.configuration.externalAgentsEnabled = false
        await sut.pendingHostedMCPLifecycleTask?.value
        sut.pendingHostedMCPLifecycleTask = nil
        XCTAssertNil(sut.activeHostedMCPServerPort, "turning External Agents off stops the server")
        XCTAssertEqual(sut.seatbeltHostedMCPPort, bound1,
                       "switched off, the configured port stays guarded: a role listening there would get the clients' bearer (#375)")
        let restarted = try await sut.startHostedMCPServer(port: 0)
        XCTAssertEqual(sut.seatbeltHostedMCPPort, restarted, "a running server's port stays blocked")
        let bound2 = try await sut.startHostedMCPServer(port: 0)
        let rivalOrch = TestOrchestrator.make()
        do {
            _ = try await rivalOrch.startHostedMCPServer(port: bound2)
            XCTFail("Expected portInUse error")
        } catch {
            XCTAssertNotNil(rivalOrch.hostedMCPLastErrorMessage)
            XCTAssertNil(rivalOrch.activeHostedMCPServerPort)
        }
        await sut.stopHostedMCPServer()
        MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort)

        // Launch with External Agents on. The startup bootstrap reopens the last work folder, so a
        // temporary one is recorded first: without it the bootstrap opens the app's default
        // storage in Application Support.
        let autoStartFolder = tempDir.appendingPathComponent("autostart-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: autoStartFolder, withIntermediateDirectories: true)
        let autoStartCfg = StoreConfiguration(storage: InMemoryConfigurationStorage())
        autoStartCfg.lastOpenedWorkFolderPath = autoStartFolder.path
        autoStartCfg.externalAgentsEnabled = true
        let autoStartDir = tempDir.appendingPathComponent("autostart-mcp", isDirectory: true)
        let autoStartEnv = HostedMCPEnvironment(
            directoryURL: { autoStartDir },
            secretStorage: { InMemorySecureTokenStorage() },
            processEnvironment: { [HostedMCPConstants.portEnvironmentVariable: "\(bound2)"] },
            allowAutoStart: true,
            now: { Date() }
        )
        let autoStartOrch = TestOrchestrator.make(
            configuration: autoStartCfg,
            hostedMCPEnvironment: autoStartEnv
        )
        await autoStartOrch.bootstrapDefaultStorageIfNeeded()
        await autoStartOrch.pendingHostedMCPLifecycleTask?.value
        XCTAssertEqual(autoStartOrch.activeHostedMCPServerPort, bound2, "the server started at launch")
        XCTAssertEqual(
            autoStartOrch.workFolderURL?.standardizedFileURL.path,
            autoStartFolder.standardizedFileURL.path,
            "the bootstrap reopened the recorded folder")
        await autoStartOrch.stopHostedMCPServer()
        MCPEndpointPolicy.setConfiguredHostedServerPort(HostedMCPConstants.defaultPort)
    }
}
