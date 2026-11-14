import XCTest
@testable import NanoTeams

@MainActor
final class AutovisorCreationBudgetOrchestratorTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func pinManager() async -> (mgrID: Int, startupTeamID: String) {
        await sut.openWorkFolder(tempDir)
        let mgrID = await sut.createTask(title: "Manager", supervisorTask: "oversee", makeActive: false)!
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = mgrID }
        let startupTeamID = sut.snapshot!.workFolder.teams.first(where: { $0.templateID == "startup" })!.id
        return (mgrID, startupTeamID)
    }

    func testCreateManagedTask_stampsTaskOriginPerActor_andHumanAndDelegatedChildDoNotConsumeRunningCap() async {
        let (_, startupTeamID) = await pinManager()
        var tuning = AutovisorTuning.default
        tuning.maxConcurrentManagedTasks = 1
        tuning.maxManagedTasksPerReview = 5
        tuning.maxOpenExternalTasks = 5
        tuning.maxExternalCreationsPerWindow = 5
        await sut.updateAutovisorTuning(tuning)

        // 1. Seed a running human task (origin == nil) and a running delegated child task (parentTaskID != nil).
        let humanID = await sut.createTask(
            title: "Human Task",
            supervisorTask: "Human brief",
            preferredTeamID: startupTeamID,
            makeActive: false
        )!
        sut.engineState[humanID] = .running

        let (_, childID) = try! sut.repository.createTask(
            at: tempDir,
            title: "Child Task",
            supervisorTask: "Child brief",
            preferredTeamID: startupTeamID,
            parentTaskID: humanID,
            parentRoleID: "swe",
            delegationDepth: 1,
            makeActive: false,
            origin: nil,
            requestKey: nil
        )
        sut.engineState[childID] = .running

        // 2. Neither the human task nor the delegated child task may consume the built-in manager's running slot.
        // Hold run start so createManagedTask creates the task without launching LM Studio.
        let baseID = sut.snapshot?.tasksIndex.nextTaskID ?? 0
        for offset in 0..<6 {
            _ = sut.engineState.beginRunStart(baseID + offset)
        }
        defer {
            for offset in 0..<6 {
                sut.engineState.endRunStart(baseID + offset)
            }
        }

        let builtInResult = await sut.performAutovisorAction(
            .createManagedTask(title: "BuiltIn Managed", brief: "Brief", teamID: startupTeamID),
            as: .builtInManager
        )
        XCTAssertTrue(builtInResult.ok, "human and child running tasks must not block built-in manager: \(builtInResult.message)")
        guard let builtInTaskID = builtInResult.createdTaskID else {
            sut.engineState[humanID] = nil
            sut.engineState[childID] = nil
            return XCTFail("Expected createdTaskID for built-in manager")
        }
        XCTAssertEqual(sut.loadedTask(builtInTaskID)?.origin, .builtInAutovisor)
        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == builtInTaskID })?.origin,
            .builtInAutovisor
        )

        // 3. Mark the built-in task as running -> a second built-in creation is blocked by maxConcurrentManagedTasks == 1.
        sut.engineState[builtInTaskID] = .running
        let secondBuiltIn = await sut.performAutovisorAction(
            .createManagedTask(title: "BuiltIn 2", brief: "Brief", teamID: startupTeamID),
            as: .builtInManager
        )
        XCTAssertFalse(secondBuiltIn.ok, "second built-in task must be blocked when 1 built-in task is running")
        XCTAssertTrue(secondBuiltIn.message.contains("already running"), "got: \(secondBuiltIn.message)")

        // 4. An external agent has its own independent running cap and stamps .externalAgent(agentA).
        let agentA = AgentIdentity(
            id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-444444444444")!,
            label: "claude-code"
        )

        let externalResult = await sut.performAutovisorAction(
            .createManagedTask(title: "External Managed", brief: "Brief", teamID: startupTeamID),
            as: .externalAgent(agentA, session: "sess-1")
        )
        XCTAssertTrue(externalResult.ok, "external agent has its own running slot: \(externalResult.message)")
        guard let extTaskID = externalResult.createdTaskID else {
            sut.engineState[humanID] = nil
            sut.engineState[childID] = nil
            sut.engineState[builtInTaskID] = nil
            return XCTFail("Expected createdTaskID for external agent")
        }
        XCTAssertEqual(sut.loadedTask(extTaskID)?.origin, .externalAgent(agentA))
        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == extTaskID })?.origin,
            .externalAgent(agentA)
        )

        // Clean up simulated running flags.
        sut.engineState[humanID] = nil
        sut.engineState[childID] = nil
        sut.engineState[builtInTaskID] = nil
    }

    func testCreateManagedTask_parallelCallsReserveSlotsBeforeFirstAwait_preventingLimitBreach() async {
        let (_, startupTeamID) = await pinManager()
        var tuning = AutovisorTuning.default
        tuning.maxConcurrentManagedTasks = 1
        tuning.maxManagedTasksPerReview = 1
        await sut.updateAutovisorTuning(tuning)

        // Hold pendingActiveTaskWrite so the first createManagedTask suspends inside createTask
        // AFTER synchronous slot reservation.
        var releaseWriteContinuation: CheckedContinuation<Void, Never>?
        let gateEntered = expectation(description: "pendingActiveTaskWrite gate armed")
        sut.pendingActiveTaskWrite = Task<Void, Error> {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                releaseWriteContinuation = cont
                gateEntered.fulfill()
            }
        }
        await fulfillment(of: [gateEntered], timeout: 2.0)

        let nextID = sut.snapshot?.tasksIndex.nextTaskID ?? 0
        for offset in 0..<4 {
            _ = sut.engineState.beginRunStart(nextID + offset)
        }
        defer {
            for offset in 0..<4 {
                sut.engineState.endRunStart(nextID + offset)
            }
        }

        let call1 = Task { @MainActor in
            await self.sut.performAutovisorAction(
                .createManagedTask(title: "Parallel 1", brief: "B1", teamID: startupTeamID),
                as: .builtInManager
            )
        }
        // Yield so call1 enters performAutovisorAction, reserves the slot synchronously,
        // and suspends at flushPendingActiveTaskWrite.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            sut.autovisorCreationLedger.builtInInFlightCount,
            1,
            "slot must be reserved synchronously before the first await"
        )

        let call2 = Task { @MainActor in
            await self.sut.performAutovisorAction(
                .createManagedTask(title: "Parallel 2", brief: "B2", teamID: startupTeamID),
                as: .builtInManager
            )
        }
        await Task.yield()
        await Task.yield()

        releaseWriteContinuation?.resume()
        let result2 = await call2.value
        XCTAssertFalse(result2.ok, "parallel call must be blocked by the in-flight reservation")

        let result1 = await call1.value
        XCTAssertTrue(result1.ok, "first call must complete after gate release: \(result1.message)")
        XCTAssertEqual(sut.autovisorCreationLedger.builtInInFlightCount, 0)
        XCTAssertEqual(sut.autovisorCreationsThisReview, 1)
    }

    func testCreateManagedTask_externalAgentEnforcesOpenTaskLimitAndWindowLimit() async {
        let (_, startupTeamID) = await pinManager()
        var tuning = AutovisorTuning.default
        tuning.maxConcurrentManagedTasks = 5
        tuning.maxOpenExternalTasks = 1
        tuning.maxExternalCreationsPerWindow = 2
        tuning.externalCreationWindowMinutes = 15
        await sut.updateAutovisorTuning(tuning)

        let agent = AgentIdentity(
            id: UUID(uuidString: "cccccccc-1111-2222-3333-444444444444")!,
            label: "cursor"
        )

        let baseID = sut.snapshot?.tasksIndex.nextTaskID ?? 0
        for offset in 0..<6 {
            _ = sut.engineState.beginRunStart(baseID + offset)
        }
        defer {
            for offset in 0..<6 {
                sut.engineState.endRunStart(baseID + offset)
            }
        }

        let r1 = await sut.performAutovisorAction(
            .createManagedTask(title: "Ext 1", brief: "B1", teamID: startupTeamID),
            as: .externalAgent(agent)
        )
        XCTAssertTrue(r1.ok, r1.message)
        guard let task1ID = r1.createdTaskID else { return XCTFail("Expected task1ID") }

        // With task1 still open (closedAt == nil) and maxOpenExternalTasks == 1, a 2nd creation is refused.
        let r2BlockedByOpen = await sut.performAutovisorAction(
            .createManagedTask(title: "Ext 2 Blocked", brief: "B2", teamID: startupTeamID),
            as: .externalAgent(agent)
        )
        XCTAssertFalse(r2BlockedByOpen.ok, "must refuse when open external task cap (1) is reached")

        // Closing task1 frees the open-task slot, allowing the 2nd creation within the window (limit 2).
        _ = await sut.performAutovisorAction(.controlTask(taskID: task1ID, verb: .close), as: .externalAgent(agent))

        let r2Allowed = await sut.performAutovisorAction(
            .createManagedTask(title: "Ext 2", brief: "B2", teamID: startupTeamID),
            as: .externalAgent(agent)
        )
        XCTAssertTrue(r2Allowed.ok, "closing task1 frees the open slot: \(r2Allowed.message)")
        guard let task2ID = r2Allowed.createdTaskID else { return XCTFail("Expected task2ID") }

        // Even after closing task2, the 3rd creation within the 15-min window hits maxExternalCreationsPerWindow == 2.
        _ = await sut.performAutovisorAction(.controlTask(taskID: task2ID, verb: .close), as: .externalAgent(agent))
        let r3BlockedByWindow = await sut.performAutovisorAction(
            .createManagedTask(title: "Ext 3 Window Blocked", brief: "B3", teamID: startupTeamID),
            as: .externalAgent(agent)
        )
        XCTAssertFalse(r3BlockedByWindow.ok, "must refuse when sliding window cap (2) is reached")
    }

    func testOpenWorkFolder_resetsCreationLedger() async throws {
        let (_, startupTeamID) = await pinManager()
        let agent = AgentIdentity(
            id: UUID(uuidString: "dddddddd-1111-2222-3333-444444444444")!,
            label: "codex"
        )

        let nextID = sut.snapshot?.tasksIndex.nextTaskID ?? 0
        _ = sut.engineState.beginRunStart(nextID)
        defer { sut.engineState.endRunStart(nextID) }

        let r = await sut.performAutovisorAction(
            .createManagedTask(title: "Ext Folder A", brief: "B", teamID: startupTeamID),
            as: .externalAgent(agent)
        )
        XCTAssertTrue(r.ok, r.message)
        sut.autovisorCreationsThisReview = 3
        XCTAssertEqual(sut.autovisorCreationLedger.externalWindowCount(for: agent.id, windowMinutes: 15), 1)

        // Open a second work folder -> ledger must reset.
        let folderB = tempDir.deletingLastPathComponent()
            .appendingPathComponent("NTMSBudgetResetB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderB) }

        await sut.openWorkFolder(folderB)
        XCTAssertEqual(sut.autovisorCreationsThisReview, 0, "opening another work folder must reset built-in review count")
        XCTAssertEqual(
            sut.autovisorCreationLedger.externalWindowCount(for: agent.id, windowMinutes: 15),
            0,
            "opening another work folder must reset external agent window counts"
        )
    }
}
