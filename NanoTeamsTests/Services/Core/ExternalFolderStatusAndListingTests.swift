import XCTest
@testable import NanoTeams

/// F6 wave D2 (2026-11-12):
/// - C12: `work_folder_context.stale` read `false` — "fresh" — while the search index had not
///   been built yet, or the context carried no `contextUpdatedAt`; with nothing to compare it is
///   absent, as plan F4 §5.5 said;
/// - C16: the cases plan F4 named and no test held — `run_once_at` without an offset is local
///   time; `list_tasks` over several closed tasks loads none and writes nothing; `list_teams` under
///   no vision model and Manual bash, on a team of two roles, lists neither tool.
@MainActor
final class ExternalFolderStatusAndListingTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "eeeeeeee-5555-2222-3333-444444444441")!,
        label: "Claude Code"
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

    private func call(_ tool: String, _ args: [String: Any] = [:]) async -> ToolExecutionResult {
        var args = args
        if args["folder_id"] == nil, tool != ExternalAutovisorToolNames.folderStatus { args["folder_id"] = folderID }
        return await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agent)
    }

    private func data(_ result: ToolExecutionResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertFalse(result.isError, result.outputJSON, file: file, line: line)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any], file: file, line: line)
        return try XCTUnwrap(object["data"] as? [String: Any], file: file, line: line)
    }

    private func context() async throws -> [String: Any] {
        let status = await call(ExternalAutovisorToolNames.folderStatus)
        return try XCTUnwrap(try data(status)["work_folder_context"] as? [String: Any])
    }

    private func installIndex() -> SearchIndexCoordinator {
        let coordinator = SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: tempDir.appendingPathComponent(".nanoteams/internal"),
            fileManager: FileManager.default,
            makeWatcher: FakeWatcherFactory.inert)
        sut.searchIndexCoordinator = coordinator
        return coordinator
    }

    // MARK: - C12

    /// RED before D2: `stale: false` before the first index build.
    func testStale_isAbsentWhileTheIndexHasNotBeenBuilt() async throws {
        try await openExternalFolder()
        let coordinator = installIndex()
        XCTAssertNil(coordinator.maxProjectFileMTime, "premise: nothing indexed yet")
        await sut.mutateWorkFolder {
            $0.settings.context = "Ship nothing without a migration note."
            $0.settings.contextUpdatedAt = Date()
        }

        let ctx = try await context()
        XCTAssertNil(ctx["stale"], "nothing to compare: not 'fresh'")
    }

    /// RED before D2: `stale: false` for a context written before the field existed.
    func testStale_isAbsentForAContextWithNoUpdateTime() async throws {
        try await openExternalFolder()
        let coordinator = installIndex()
        try "func f() {}".write(to: tempDir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        await coordinator.rebuild()
        XCTAssertNotNil(coordinator.maxProjectFileMTime, "premise: the index is built")
        await sut.mutateWorkFolder {
            $0.settings.context = "Ship nothing without a migration note."
            $0.settings.contextUpdatedAt = nil
        }

        let ctx = try await context()
        XCTAssertNil(ctx["stale"])
    }

    // MARK: - C16

    /// `run_once_at` without an offset is the Mac's local time, as its property says.
    func testRunOnceAt_withoutAnOffset_isLocalTime() async throws {
        try await openExternalFolder()
        let created = try data(await call(ExternalAutovisorToolNames.createManagedTask,
                                          ["title": "Later", "brief": "b"]))
        let taskID = try XCTUnwrap(created["task_id"] as? Int)

        let year = Calendar.current.component(.year, from: Date()) + 1
        _ = try data(await call(ExternalAutovisorToolNames.scheduleTask,
                                ["task_id": taskID, "run_once_at": "\(year)-03-04T01:30:00"]))

        guard case .once(let date)? = sut.loadedTask(taskID)?.recurrence?.rule else {
            return XCTFail("a one-shot rule: \(String(describing: sut.loadedTask(taskID)?.recurrence))")
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(parts, DateComponents(year: year, month: 3, day: 4, hour: 1, minute: 30))
    }

    /// `list_tasks` over several closed tasks hydrates none of them and writes nothing.
    func testListTasks_overSeveralClosedTasks_loadsNoneAndWritesNothing() async throws {
        try await openExternalFolder()
        var ids: [Int] = []
        for title in ["One", "Two", "Three"] {
            let created = try data(await call(ExternalAutovisorToolNames.createManagedTask, [
                "title": title, "brief": "b",
                "run_once_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600)),
            ]))
            let id = try XCTUnwrap(created["task_id"] as? Int)
            _ = try data(await call(ExternalAutovisorToolNames.controlTask, ["task_id": id, "action": "close"]))
            ids.append(id)
        }
        for id in ids { sut.evictLoadedTask(id) }
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let watched = [paths.tasksIndexJSON] + ids.map { paths.taskJSON(taskID: $0) }
        func stamps() -> [Date?] {
            watched.map { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        }
        let before = stamps()
        XCTAssertFalse(before.contains { $0 == nil }, "premise: every file exists")

        let read8 = await call(ExternalAutovisorToolNames.listTasks)
        let rows = try XCTUnwrap(try data(read8)["tasks"] as? [[String: Any]])

        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? Int }).intersection(ids).count, ids.count)
        for id in ids {
            XCTAssertNil(sut.loadedTask(id), "task \(id) was loaded to be listed")
            XCTAssertEqual(rows.first { $0["id"] as? Int == id }?["status"] as? String, "closed")
        }
        XCTAssertEqual(stamps(), before, "listing wrote a file")
    }

    /// With no vision model and bash under Manual (nobody to approve under the External
    /// Autovisor), a role that holds both tools lists neither — on each role of a two-role team.
    func testListTeams_withoutVisionAndUnderManualBash_listsNeitherToolOnEitherRole() async throws {
        try await openExternalFolder()
        sut.configuration.bashMode = .manual
        sut.configuration.visionEnabled = false
        XCTAssertNil(sut.visionLLMConfig, "premise: no vision model")
        let base = try XCTUnwrap(sut.snapshot?.workFolder.teams.first {
            !$0.isChatMode && !$0.isHiddenFromPickers && $0.nonSupervisorRoles.count >= 2
        })
        var pair = base
        pair.id = "two_role_fixture"
        pair.name = "Two Roles"
        pair.templateID = nil
        let kept = Set(base.nonSupervisorRoles.prefix(2).map(\.id))
        pair.roles = base.roles.filter { $0.isSupervisor || kept.contains($0.id) }.map { role in
            var role = role
            if !role.isSupervisor {
                role.toolIDs = Array(Set(role.toolIDs + [ToolNames.analyzeImage, ToolNames.bash]))
            }
            return role
        }
        await sut.mutateWorkFolder { $0.teams.append(pair) }

        let read9 = await call(ExternalAutovisorToolNames.listTeams)
        let teams = try XCTUnwrap(try data(read9)["teams"] as? [[String: Any]])
        let listed = try XCTUnwrap(teams.first { $0["id"] as? String == pair.id }, "the fixture team is selectable")
        let roles = try XCTUnwrap(listed["roles"] as? [[String: Any]])
        XCTAssertEqual(roles.count, 2)
        for role in roles {
            let tools = role["tools"] as? [String] ?? []
            XCTAssertFalse(tools.contains(ToolNames.analyzeImage), "\(role["id"] ?? "?"): \(tools)")
            XCTAssertFalse(tools.contains(ToolNames.bash), "\(role["id"] ?? "?"): \(tools)")
            XCTAssertFalse(tools.isEmpty, "anti-vacuum: the role still lists its other tools")
        }
    }
}
