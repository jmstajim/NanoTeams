import XCTest
@testable import NanoTeams

/// F6 C1/C2 (2026-11-12): why the 8 November task 3 shipped `bash` to a task an external agent
/// created while the Autovisor was on, reproduced through the genuine path.
///
/// Two NanoTeams processes held the folder. The auto-off timer of one wrote
/// `autovisorEnabled = false` into `settings.json`; the other process's `create_managed_task`
/// passed its readiness gate, and its `createTask` — a writer of `tasks/` and `workfolder.json`,
/// not of `settings.json` — read `settings.json` back while building its context, and `apply`
/// took that disk copy into the snapshot. The resolver then saw no Autovisor, so a person was
/// present, so `bash` went into the schema under Manual. Here the "second process" is a separate
/// `NTMSRepository` writing the file directly, between the open and the create — the window the
/// folder lock (`WorkFolderInstanceLock`) now closes for real processes; this pins the other half,
/// that a write which does not own `settings.json` never replaces the settings in memory.
///
/// Both tool-calling modes: the schema is what the step hands the client in either, and the
/// investigation had to rule out a prompt-taught catalogue assembled past the gate.
@MainActor
final class ExternalAgentTaskForeignSettingsTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-4444444444c1")!,
        label: "Claude Code"
    )

    private var client: ScriptedToolCallClient!

    override func setUp() async throws {
        try await super.setUp()
        client = ScriptedToolCallClient(script: [.text("Done")])
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient,
            stepExecutionClient: client
        )
    }

    override func tearDown() async throws {
        client = nil
        try await super.tearDown()
    }

    // MARK: - C1: a foreign write between the open and the create

    func testForeignDiskDisable_betweenOpenAndCreate_withholdsBash_native() async throws {
        try await assertForeignDiskDisableWithholdsBash(preference: .native)
    }

    func testForeignDiskDisable_betweenOpenAndCreate_withholdsBash_promptTaught() async throws {
        try await assertForeignDiskDisableWithholdsBash(preference: .promptTaught)
    }

    /// The guard on the other side, so the fix is not W8's override in a new place: a person who
    /// turns the Autovisor off in THIS process approves the agent's task themselves, so under
    /// Manual `bash` is offered.
    func testPersonDisablesTheAutovisorHere_agentTaskOffersBash_native() async throws {
        try await assertPersonDisableOffersBash(preference: .native)
    }

    func testPersonDisablesTheAutovisorHere_agentTaskOffersBash_promptTaught() async throws {
        try await assertPersonDisableOffersBash(preference: .promptTaught)
    }

    // MARK: - C2: the Autovisor already on, on disk, when the folder opens

    /// The path the 8 November process took: the driver and the switch were saved before the
    /// folder was opened, not turned on after it. No `setAutovisorDriver` / `setAutovisorEnabled`
    /// in this process.
    func testAutovisorSavedOnDiskBeforeOpen_agentTaskWithholdsBash() async throws {
        _ = try NTMSRepository().openOrCreateWorkFolder(at: tempDir)
        try NTMSRepository().updateSettings(at: tempDir, activeTask: nil) {
            $0.autovisorDriver = .externalAgent
            $0.autovisorEnabled = true
        }
        sut.configuration.bashMode = .manual
        sut.configuration.toolCallingPreference = .native

        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .ready,
                       "anti-vacuum: the settings saved before the open make the folder ready")

        let tools = try await firstRequestTools(ofTaskCreatedBy: agent)
        XCTAssertFalse(tools.contains(ToolNames.bash), "tools: \(tools)")
        XCTAssertFalse(tools.contains(ToolNames.bashOutput), "tools: \(tools)")
    }

    // MARK: - The create asks readiness again before it starts

    /// The gate at the top of `create_managed_task` passes before the create's suspensions; the
    /// Autovisor going off inside them (here: in the create's own write, through the repository's
    /// deterministic seam) leaves a task that must not start with nobody but a person to approve it.
    func testAutovisorOffDuringTheCreate_taskIsCreatedButNotStarted() async throws {
        try await openReadyFolder(preference: .native)
        let orchestrator = try XCTUnwrap(sut)
        NTMSRepository._testCreateTaskBeforeSummaryAppend = {
            MainActor.assumeIsolated { orchestrator.snapshot?.projection.settings.autovisorEnabled = false }
        }
        defer { NTMSRepository._testCreateTaskBeforeSummaryAppend = nil }

        let folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID, "title": "Late off", "brief": "b", "team_id": try startupTeam().id],
            agent: agent
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        let data = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])?["data"]
                as? [String: Any])
        XCTAssertEqual(data["status"] as? String, "created_not_started")
        let message = try XCTUnwrap(data["message"] as? String)
        XCTAssertTrue(message.contains(ExternalAutovisorReadiness.Refusal.autovisorDisabled.message), message)
        let taskID = try XCTUnwrap(data["task_id"] as? Int)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.isEmpty, true, "no run was started")
        XCTAssertEqual(client.callCount, 0, "no step sent a request")
    }

    /// The other side: readiness unchanged through the create, the task starts as before.
    func testAutovisorOnThroughTheCreate_taskStarts() async throws {
        try await openReadyFolder(preference: .native)
        _ = try await firstRequestTools(ofTaskCreatedBy: agent)
        XCTAssertEqual(client.callCount >= 1, true)
    }

    // MARK: - The seam: no writer that does not own settings.json replaces them

    /// Every orchestrator path whose repository writer reads `settings.json` back without writing
    /// it. A foreign write lands before each, and after each the settings in memory are still this
    /// process's — the pin a new writer has to pass (`AppliedSettings.keepInMemory`).
    func testEveryNarrowWriter_keepsTheSettingsInMemory() async throws {
        try await openReadyFolder(preference: .native)
        await sut.mutateWorkFolder { $0.settings.context = "this process" }
        let created = await sut.createTask(title: "First", supervisorTask: "b")
        let first = try XCTUnwrap(created)

        let writes: [(String, () async -> Void)] = [
            ("createTask", { _ = await self.sut.createTask(title: "Second", supervisorTask: "b") }),
            ("createTask (agent, not active)", {
                _ = await self.sut.createTask(
                    title: "Agent", supervisorTask: "b", makeActive: false, origin: .externalAgent(self.agent))
            }),
            ("createDelegatedTask", {
                _ = await self.sut.createDelegatedTask(
                    parentTaskID: first, parentRoleID: "software_engineer", title: "Child",
                    supervisorTask: "b", preferredTeamID: nil, depth: 1)
            }),
            // The slow path — the one that reads the folder back (`taskService.switchTask`). The
            // target is evicted first: loaded, the switch is a promotion in memory that reads
            // nothing, and the row would pin nothing (D-M18 R10).
            ("switchTask (slow path)", {
                self.sut.evictLoadedTask(first)
                XCTAssertNil(self.sut.loadedTask(first), "premise: the switch has to read the task")
                await self.sut.switchTask(to: first)
                XCTAssertEqual(self.sut.activeTaskID, first)
            }),
            // The two settings writers of a single field (D-M18 R9): they write settings.json, so
            // what they wrote is memory's — the field they set, and nothing else of the file.
            ("updateWorkFolderContext", { await self.sut.updateWorkFolderContext("this process") }),
            ("updateSelectedScheme", { await self.sut.updateSelectedScheme("Scheme") }),
            ("mutateWorkFolder, workfolder.json only", {
                let other = self.sut.snapshot?.workFolder.teams.last { !$0.isHiddenFromPickers }?.id
                await self.sut.mutateWorkFolder { $0.setActiveTeam(other ?? $0.teams[0].id) }
            }),
            ("mutateWorkFolder, teams.json only", {
                await self.sut.mutateWorkFolder { $0.teams[0].name += " renamed" }
            }),
            ("saveToolDefinitions", { await self.sut.saveToolDefinitions(self.sut.toolDefinitions) }),
            ("removeTask", { await self.sut.removeTask(first) }),
        ]
        for (name, write) in writes {
            // Each writer on its own: memory back to this process's settings first, so one
            // writer's substitution cannot stand in for the next one's.
            await sut.mutateWorkFolder {
                $0.settings.autovisorEnabled = true
                $0.settings.context = "this process"
            }
            try NTMSRepository().updateSettings(at: tempDir, activeTask: nil) {
                $0.autovisorEnabled = false
                $0.context = "the other process"
            }
            let errorsBefore = sut.errorSurfaceCount
            await write()
            XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "\(name) failed: \(sut.lastSurfacedError ?? "")")
            XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true, name)
            XCTAssertEqual(sut.snapshot?.workFolder.settings.context, "this process", name)
            XCTAssertEqual(sut.externalAutovisorReadiness.state, .ready, name)
        }
    }

    /// A settings write is the other side: what it wrote is what memory holds.
    func testSettingsWriter_adoptsWhatItWrote() async throws {
        try await openReadyFolder(preference: .native)
        await sut.mutateWorkFolder { $0.settings.context = "written here" }
        XCTAssertEqual(sut.snapshot?.workFolder.settings.context, "written here")
        let onDisk = try NTMSRepository().openOrCreateWorkFolder(at: tempDir).projection.settings.context
        XCTAssertEqual(onDisk, "written here")
    }

    /// The one same-folder path that does take the file's Autovisor fields — the re-read after a
    /// write failed partway — goes through the seam a switch takes: the agent's waits wake with
    /// `autovisor_disabled` and the sleep timer is cleared.
    func testResyncAfterAFailedWrite_adoptsTheFileThroughTheAutovisorSeam() async throws {
        let repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient, stepExecutionClient: client)
        try await openReadyFolder(preference: .native)
        await sut.updateAutovisorActivation(AutovisorActivation(
            autoDisableEnabled: true, autoDisableAfterSeconds: 3600))
        XCTAssertNotNil(sut.autovisorAutoDisableAt, "anti-vacuum: the sleep timer is armed")

        try NTMSRepository().updateSettings(at: tempDir, activeTask: nil) { $0.autovisorEnabled = false }
        var wakes: [ExternalAutovisorWakeReason] = []
        let feedHandler = sut.externalAutovisorReadinessSignal.onWakeAll
        sut.externalAutovisorReadinessSignal.onWakeAll = { wakes.append($0); feedHandler?($0) }

        repo.failUpdateTeams = true
        await sut.mutateWorkFolder { $0.teams[0].name += " renamed" }

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .autovisorDisabled)
        XCTAssertEqual(wakes, [.autovisorDisabled], "the agent's waits hear that the Autovisor is off")
        XCTAssertNil(sut.autovisorAutoDisableAt, "the timer of an Autovisor that is off is cleared")
    }

    /// The driver read back from the file is the other field the seam owns: the agent's waits
    /// wake with `driver_changed` — and with nothing about the enabled flag, which did not move.
    func testResyncThatChangesTheDriver_wakesTheWaitsWithDriverChanged() async throws {
        let repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient, stepExecutionClient: client)
        try await openReadyFolder(preference: .native)

        try NTMSRepository().updateSettings(at: tempDir, activeTask: nil) { $0.autovisorDriver = .builtInModel }
        var wakes: [ExternalAutovisorWakeReason] = []
        let feedHandler = sut.externalAutovisorReadinessSignal.onWakeAll
        sut.externalAutovisorReadinessSignal.onWakeAll = { wakes.append($0); feedHandler?($0) }

        repo.failUpdateTeams = true
        await sut.mutateWorkFolder { $0.teams[0].name += " renamed" }

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorDriver, .builtInModel)
        XCTAssertEqual(wakes, [.driverChanged])
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .builtInDriver,
                       "the external agent no longer drives this folder")
    }

    /// The seam with nothing to say: a re-read that changes no Autovisor field wakes no wait.
    func testResyncThatChangesNoAutovisorField_wakesNothing() async throws {
        let repo = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(
            repository: repo, embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient, stepExecutionClient: client)
        try await openReadyFolder(preference: .native)
        var wakes: [ExternalAutovisorWakeReason] = []
        let feedHandler = sut.externalAutovisorReadinessSignal.onWakeAll
        sut.externalAutovisorReadinessSignal.onWakeAll = { wakes.append($0); feedHandler?($0) }

        repo.failUpdateTeams = true
        await sut.mutateWorkFolder { $0.teams[0].name += " renamed" }

        XCTAssertNotNil(sut.lastSurfacedError, "anti-vacuum: the write failed and the folder was re-read")
        XCTAssertEqual(wakes, [])
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .ready)
    }

    // MARK: - Scenarios

    private func assertForeignDiskDisableWithholdsBash(
        preference: ToolCallingPreference, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await openReadyFolder(preference: preference)

        // The other process: its own repository, its own write, nothing of this orchestrator.
        try NTMSRepository().updateSettings(at: tempDir, activeTask: nil) {
            $0.autovisorEnabled = false
        }
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .ready,
                       "anti-vacuum: this process has not heard of the foreign write", file: file, line: line)

        let tools = try await firstRequestTools(ofTaskCreatedBy: agent)
        XCTAssertTrue(tools.contains(ToolNames.readFile),
                      "anti-vacuum: the request carried the role's tools", file: file, line: line)
        XCTAssertFalse(tools.contains(ToolNames.bash),
                       "a disk copy of settings.json replaced the settings in memory; tools: \(tools)",
                       file: file, line: line)
        XCTAssertFalse(tools.contains(ToolNames.bashOutput), file: file, line: line)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, true,
                       "the create did not own settings.json", file: file, line: line)
    }

    private func assertPersonDisableOffersBash(
        preference: ToolCallingPreference, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await openReadyFolder(preference: preference)
        let team = try startupTeam()
        let created = await sut.createTask(
            title: "Agent task", supervisorTask: "Implement linecount",
            preferredTeamID: team.id, makeActive: false, origin: .externalAgent(agent)
        )
        let taskID = try XCTUnwrap(created, file: file, line: line)

        await sut.setAutovisorEnabled(false)
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .autovisorDisabled, file: file, line: line)

        await sut.startRun(taskID: taskID)
        let tools = try await awaitFirstRequestTools()
        XCTAssertTrue(tools.contains(ToolNames.bash),
                      "the Autovisor is off here, so the person approves; tools: \(tools)",
                      file: file, line: line)
    }

    // MARK: - Helpers

    private func openReadyFolder(preference: ToolCallingPreference) async throws {
        sut.configuration.bashMode = .manual
        sut.configuration.toolCallingPreference = preference
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        XCTAssertEqual(sut.externalAutovisorReadiness.state, .ready)
        let team = try startupTeam()
        let role = try XCTUnwrap(team.nonSupervisorRoles.first)
        XCTAssertTrue(role.toolIDs.contains(ToolNames.bash), "anti-vacuum: the role holds bash")
    }

    private func startupTeam() throws -> Team {
        try XCTUnwrap(sut.snapshot?.workFolder.teams.first { $0.templateID == "startup" })
    }

    /// Creates the task through the agent's own tool — readiness gate, create, start — and returns
    /// the tool names the first request of its step advertised.
    private func firstRequestTools(ofTaskCreatedBy agent: AgentIdentity) async throws -> [String] {
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: [
                "folder_id": folderID,
                "title": "Startup agent task",
                "brief": "Implement linecount",
                "team_id": try startupTeam().id
            ],
            agent: agent
        )
        XCTAssertFalse(result.isError, result.outputJSON)
        return try await awaitFirstRequestTools()
    }

    private func awaitFirstRequestTools() async throws -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while client.toolNamesPerRequest.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(client.toolNamesPerRequest.first, "the step sent no request")
    }
}
