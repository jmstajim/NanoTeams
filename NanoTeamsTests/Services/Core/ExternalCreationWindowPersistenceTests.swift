import XCTest
@testable import NanoTeams

/// F6 wave D2 (2026-11-12), live finding L4: the sliding window that limits how many tasks one
/// external agent may create (`AutovisorTuning.maxExternalCreationsPerWindow` per
/// `externalCreationWindowMinutes`) lived only in the process's memory — after a relaunch
/// `folder_status.limits.created_in_window` read 0 with two creations a quarter of an hour old,
/// and the agent could create a full window again. The window counts CREATIONS, so a task the
/// person deleted since still counts: closing or deleting never refills it (the instructions
/// say so).
@MainActor
final class ExternalCreationWindowPersistenceTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "eeeeeeee-3333-2222-3333-444444444441")!,
        label: "Claude Code"
    )
    private let otherAgent = AgentIdentity(
        id: UUID(uuidString: "eeeeeeee-3333-2222-3333-444444444442")!,
        label: "Codex"
    )

    private var folderID: String!

    override func tearDown() async throws {
        folderID = nil
        try await super.tearDown()
    }

    private func openExternalFolder() async throws {
        await sut.openWorkFolder(tempDir)
        if let pipeline = sut.snapshot?.workFolder.teams.first(where: { !$0.isChatMode && !$0.isHiddenFromPickers }) {
            await sut.mutateWorkFolder { $0.setActiveTeam(pipeline.id) }
        }
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    /// The process exits and a new one opens the same folder.
    private func relaunch() async throws {
        await sut.drainRunStartLaunches()
        sut.stopAllEngines()
        sut.releaseWorkFolderInstanceLock()
        sut = TestOrchestrator.make(embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient)
        await sut.openWorkFolder(tempDir)
        XCTAssertEqual(sut.snapshot?.projection.id.uuidString, folderID, "premise: the same folder")
    }

    private func call(_ tool: String, _ args: [String: Any], as who: AgentIdentity? = nil) async -> ToolExecutionResult {
        var args = args
        if args["folder_id"] == nil, tool != ExternalAutovisorToolNames.folderStatus { args["folder_id"] = folderID }
        return await sut.executeExternalAutovisorTool(name: tool, args: args, agent: who ?? agent)
    }

    private func data(_ result: ToolExecutionResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertFalse(result.isError, result.outputJSON, file: file, line: line)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any], file: file, line: line)
        return try XCTUnwrap(object["data"] as? [String: Any], file: file, line: line)
    }

    /// Creates a task that waits for a time an hour away, so no run starts.
    private func create(_ title: String, as who: AgentIdentity? = nil) async throws -> Int {
        let created = try data(await call(ExternalAutovisorToolNames.createManagedTask, [
            "title": title, "brief": "Later",
            "run_once_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600)),
        ], as: who))
        return try XCTUnwrap(created["task_id"] as? Int)
    }

    private func createdInWindow(as who: AgentIdentity? = nil) async throws -> Int? {
        let status = try data(await call(ExternalAutovisorToolNames.folderStatus, [:], as: who))
        return (status["limits"] as? [String: Any])?["created_in_window"] as? Int
    }

    /// RED before D2: 0 after the relaunch.
    func testTheCreationWindow_survivesARelaunch() async throws {
        try await openExternalFolder()
        _ = try await create("One")
        _ = try await create("Two")
        let read1 = try await createdInWindow()
        XCTAssertEqual(read1, 2, "premise")

        try await relaunch()

        let read2 = try await createdInWindow()
        XCTAssertEqual(read2, 2)
    }

    /// The window is per agent on the far side of the relaunch too.
    func testTheCreationWindow_staysPerAgentAcrossARelaunch() async throws {
        try await openExternalFolder()
        _ = try await create("Mine")
        _ = try await create("Theirs", as: otherAgent)
        _ = try await create("Theirs too", as: otherAgent)

        try await relaunch()

        let read3 = try await createdInWindow()
        XCTAssertEqual(read3, 1)
        let read4 = try await createdInWindow(as: otherAgent)
        XCTAssertEqual(read4, 2)
    }

    /// A creation counts whatever became of the task: deleting it does not refill the window,
    /// before or after the relaunch.
    func testADeletedTask_stillCountsAgainstTheWindowAfterARelaunch() async throws {
        try await openExternalFolder()
        let first = try await create("One")
        _ = try await create("Two")
        _ = try data(await call(ExternalAutovisorToolNames.controlTask, ["task_id": first, "action": "delete"]))
        let read5 = try await createdInWindow()
        XCTAssertEqual(read5, 2, "premise: deleting refills nothing")

        try await relaunch()

        let read6 = try await createdInWindow()
        XCTAssertEqual(read6, 2)
    }

    /// The window still refuses once full — after the relaunch, without any new creation in it.
    func testAFullWindow_stillRefusesAfterARelaunch() async throws {
        try await openExternalFolder()
        await sut.mutateWorkFolder { $0.settings.autovisorTuning.maxExternalCreationsPerWindow = 2 }
        _ = try await create("One")
        _ = try await create("Two")

        try await relaunch()

        let refused = await call(ExternalAutovisorToolNames.createManagedTask, [
            "title": "Three", "brief": "Later",
            "run_once_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600)),
        ])
        XCTAssertTrue(refused.isError, refused.outputJSON)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(refused.outputJSON.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "LIMIT_REACHED")
        XCTAssertEqual((error["details"] as? [String: Any])?["limit"] as? String, "window")
        XCTAssertNotNil((error["details"] as? [String: Any])?["retry_at"], "the window says when it reopens")
    }
}
