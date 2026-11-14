import XCTest
@testable import NanoTeams

final class TaskOriginAndCreationLedgerTests: XCTestCase {
    private let decoder = JSONCoderFactory.makeDateDecoder()
    private let encoder = JSONCoderFactory.makePersistenceEncoder()

    func testNTMSTaskAndTaskSummary_codableRoundTrip_absentKey_unknownVariant_andNonDefaultWrite() throws {
        // 1. Default human task (origin == nil) omits "origin" on encode and round-trips to nil.
        let humanTask = NTMSTask(id: 1, title: "Human Task", supervisorTask: "Brief")
        let humanTaskData = try encoder.encode(humanTask)
        let humanTaskJSON = try XCTUnwrap(String(data: humanTaskData, encoding: .utf8))
        XCTAssertFalse(humanTaskJSON.contains("\"origin\""), "default nil origin must not write an origin key")
        let decodedHuman = try decoder.decode(NTMSTask.self, from: humanTaskData)
        XCTAssertNil(decodedHuman.origin)

        let humanSummary = humanTask.toSummary()
        let humanSummaryData = try encoder.encode(humanSummary)
        let humanSummaryJSON = try XCTUnwrap(String(data: humanSummaryData, encoding: .utf8))
        XCTAssertFalse(humanSummaryJSON.contains("\"origin\""), "default nil summary origin must not write an origin key")
        let decodedHumanSummary = try decoder.decode(TaskSummary.self, from: humanSummaryData)
        XCTAssertNil(decodedHumanSummary.origin)

        // 2. Non-default origins round-trip and mirror into TaskSummary via toSummary().
        let agent = AgentIdentity(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            label: "claude-code"
        )
        let externalTask = NTMSTask(
            id: 2,
            title: "External Task",
            supervisorTask: "Brief",
            origin: .externalAgent(agent)
        )
        let externalSummary = externalTask.toSummary()
        XCTAssertEqual(externalSummary.origin, .externalAgent(agent), "toSummary() must mirror origin")

        let externalTaskData = try encoder.encode(externalTask)
        let decodedExternalTask = try decoder.decode(NTMSTask.self, from: externalTaskData)
        XCTAssertEqual(decodedExternalTask.origin, .externalAgent(agent))
        XCTAssertEqual(decodedExternalTask.origin?.externalAgentIdentity, agent)
        XCTAssertTrue(decodedExternalTask.origin?.isExternalAgent == true)
        XCTAssertTrue(decodedExternalTask.origin?.matchesExternalAgent(agent.id) == true)

        let builtInTask = NTMSTask(
            id: 3,
            title: "BuiltIn Task",
            supervisorTask: "Brief",
            origin: .builtInAutovisor
        )
        let builtInData = try encoder.encode(builtInTask)
        let decodedBuiltIn = try decoder.decode(NTMSTask.self, from: builtInData)
        XCTAssertEqual(decodedBuiltIn.origin, .builtInAutovisor)
        XCTAssertTrue(decodedBuiltIn.origin?.isBuiltInAutovisor == true)
        XCTAssertEqual(builtInTask.toSummary().origin, .builtInAutovisor)

        // 3. Unknown future variant in NTMSTask and TaskSummary decodes tolerantly to nil without throwing.
        let unknownOriginTaskJSON = """
        {
          "id": 9,
          "title": "Future Task",
          "supervisorTask": "Brief",
          "origin": { "kind": "quantumAutovisor" }
        }
        """
        let tolerantTask = try decoder.decode(NTMSTask.self, from: Data(unknownOriginTaskJSON.utf8))
        XCTAssertNil(tolerantTask.origin, "unknown TaskOrigin variant in NTMSTask must decode to nil")

        let unknownOriginSummaryJSON = """
        {
          "id": 9,
          "title": "Future Summary",
          "origin": { "kind": "quantumAutovisor" }
        }
        """
        let tolerantSummary = try decoder.decode(TaskSummary.self, from: Data(unknownOriginSummaryJSON.utf8))
        XCTAssertNil(tolerantSummary.origin, "unknown TaskOrigin variant in TaskSummary must decode to nil")
    }

    func testProjectSettings_autovisorDriver_codableRoundTrip_absentKey_unknownVariant_andNonDefaultWrite() throws {
        // 1. Default settings (.builtInModel) omit "autovisorDriver" on encode.
        let defaultSettings = ProjectSettings.defaults
        XCTAssertEqual(defaultSettings.autovisorDriver, .builtInModel)
        let defaultData = try encoder.encode(defaultSettings)
        let defaultJSON = try XCTUnwrap(String(data: defaultData, encoding: .utf8))
        XCTAssertFalse(
            defaultJSON.contains("\"autovisorDriver\""),
            "default .builtInModel must not write autovisorDriver key to settings.json"
        )

        // 2. Absent key decodes to .builtInModel.
        let decodedDefault = try decoder.decode(ProjectSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decodedDefault.autovisorDriver, .builtInModel)

        // 3. Unknown future variant decodes tolerantly to .builtInModel without throwing.
        let unknownDriverJSON = #"{ "autovisorDriver": "futureQuantumDriver", "context": "keep-me" }"#
        let decodedUnknown = try decoder.decode(ProjectSettings.self, from: Data(unknownDriverJSON.utf8))
        XCTAssertEqual(decodedUnknown.autovisorDriver, .builtInModel)
        XCTAssertEqual(decodedUnknown.context, "keep-me")

        // 4. Non-default .externalAgent writes key and round-trips.
        var externalSettings = ProjectSettings.defaults
        externalSettings.autovisorDriver = .externalAgent
        let externalData = try encoder.encode(externalSettings)
        let externalJSON = try XCTUnwrap(String(data: externalData, encoding: .utf8))
        XCTAssertTrue(externalJSON.contains("\"autovisorDriver\""), "non-default .externalAgent must be written")
        let decodedExternal = try decoder.decode(ProjectSettings.self, from: externalData)
        XCTAssertEqual(decodedExternal.autovisorDriver, .externalAgent)
    }

    /// `contextUpdatedAtMonotonic` was written and read by nothing (F6 C12, removed 2026-11-12):
    /// a settings.json that still carries it decodes, keeps `contextUpdatedAt`, and the next write
    /// leaves the dead key out.
    func testProjectSettings_aStoredContextUpdatedAtMonotonic_isIgnored_andNotWrittenBack() throws {
        let json = #"{ "context": "keep-me", "contextUpdatedAt": "2026-11-01T01:00:00Z", "contextUpdatedAtMonotonic": "2026-11-01T01:00:00Z" }"#
        let decoded = try decoder.decode(ProjectSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.context, "keep-me")
        XCTAssertEqual(decoded.contextUpdatedAt, ISO8601DateFormatter().date(from: "2026-11-01T01:00:00Z"))

        let written = try XCTUnwrap(String(data: try encoder.encode(decoded), encoding: .utf8))
        XCTAssertTrue(written.contains("\"contextUpdatedAt\""))
        XCTAssertFalse(written.contains("contextUpdatedAtMonotonic"))
    }

    func testAutovisorTuning_externalBudgetFields_defaultsClampsAndPartialDecode() throws {
        let defaults = AutovisorTuning.default
        XCTAssertEqual(defaults.maxExternalCreationsPerWindow, 5)
        XCTAssertEqual(defaults.externalCreationWindowMinutes, 15)
        XCTAssertEqual(defaults.maxOpenExternalTasks, 3)

        let clampedInit = AutovisorTuning(
            maxExternalCreationsPerWindow: 0,
            externalCreationWindowMinutes: -5,
            maxOpenExternalTasks: 0
        )
        XCTAssertEqual(clampedInit.maxExternalCreationsPerWindow, 1)
        XCTAssertEqual(clampedInit.externalCreationWindowMinutes, 1)
        XCTAssertEqual(clampedInit.maxOpenExternalTasks, 1)

        var mutated = AutovisorTuning.default
        mutated.maxExternalCreationsPerWindow = 0
        mutated.externalCreationWindowMinutes = 0
        mutated.maxOpenExternalTasks = -1
        let reclamped = mutated.clamped()
        XCTAssertEqual(reclamped.maxExternalCreationsPerWindow, 1)
        XCTAssertEqual(reclamped.externalCreationWindowMinutes, 1)
        XCTAssertEqual(reclamped.maxOpenExternalTasks, 1)

        let partialJSON = #"{ "maxConcurrentManagedTasks": 4, "maxOpenExternalTasks": 0 }"#
        let decodedPartial = try decoder.decode(AutovisorTuning.self, from: Data(partialJSON.utf8))
        XCTAssertEqual(decodedPartial.maxConcurrentManagedTasks, 4)
        XCTAssertEqual(decodedPartial.maxOpenExternalTasks, 1)
        XCTAssertEqual(decodedPartial.maxExternalCreationsPerWindow, 5)
        XCTAssertEqual(decodedPartial.externalCreationWindowMinutes, 15)
    }

    func testAutovisorCreationLedger_perActorBudgetsAndSlidingWindow() throws {
        var ledger = AutovisorCreationLedger()
        var tuning = AutovisorTuning.default
        tuning.maxConcurrentManagedTasks = 2
        tuning.maxManagedTasksPerReview = 2
        tuning.maxOpenExternalTasks = 2
        tuning.maxExternalCreationsPerWindow = 2
        tuning.externalCreationWindowMinutes = 15

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let agentA = AgentIdentity(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            label: "claude"
        )
        let agentB = AgentIdentity(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            label: "codex"
        )

        // Built-in manager reserves 2 slots synchronously -> 3rd is blocked by review capeven before commit.
        let r1 = try ledger.tryReserveSlot(for: .builtInManager, tuning: tuning, runningCount: 0, now: t0).get()
        let r2 = try ledger.tryReserveSlot(for: .builtInManager, tuning: tuning, runningCount: 0, now: t0).get()
        XCTAssertEqual(
            ledger.tryReserveSlot(for: .builtInManager, tuning: tuning, runningCount: 0, now: t0),
            .failure(.tooManyRunning(count: 2, limit: 2)),
            "two in-flight reservations saturate the running ceiling"
        )

        // Rollback r2 -> frees slot; commit r1 -> 1 created this review.
        ledger.rollback(r2)
        ledger.commit(r1, now: t0)
        XCTAssertEqual(ledger.builtInCreatedThisReview, 1)

        // External agent A has its own independent budget.
        let extA1 = try ledger.tryReserveSlot(
            for: .externalAgent(agentA, session: "s1"),
            tuning: tuning,
            runningCount: 0,
            openExternalCount: 0,
            now: t0
        ).get()
        ledger.commit(extA1, now: t0)

        // Open task cap for agent A: if openExternalCount == 2, refuses with tooManyOpenTasks.
        XCTAssertEqual(
            ledger.tryReserveSlot(
                for: .externalAgent(agentA),
                tuning: tuning,
                runningCount: 0,
                openExternalCount: 2,
                now: t0
            ),
            .failure(.tooManyOpenTasks(count: 2, limit: 2))
        )

        // Second creation in window for agent A succeeds when openExternalCount == 1; 3rd hits window limit.
        let extA2 = try ledger.tryReserveSlot(
            for: .externalAgent(agentA),
            tuning: tuning,
            runningCount: 0,
            openExternalCount: 1,
            now: t0.addingTimeInterval(60)
        ).get()
        ledger.commit(extA2, now: t0.addingTimeInterval(60))

        XCTAssertEqual(
            ledger.tryReserveSlot(
                for: .externalAgent(agentA),
                tuning: tuning,
                runningCount: 0,
                openExternalCount: 0,
                now: t0.addingTimeInterval(120)
            ),
            .failure(.windowCreationLimitReached(limit: 2, windowMinutes: 15))
        )

        // Agent B is unaffected by Agent A's window exhaustion.
        let extB1 = try ledger.tryReserveSlot(
            for: .externalAgent(agentB),
            tuning: tuning,
            runningCount: 0,
            openExternalCount: 0,
            now: t0.addingTimeInterval(120)
        ).get()
        ledger.commit(extB1, now: t0.addingTimeInterval(120))

        // Resetting built-in review clears builtInCreatedThisReview without wiping external agent history.
        ledger.resetBuiltInReview()
        XCTAssertEqual(ledger.builtInCreatedThisReview, 0)
        XCTAssertEqual(ledger.externalWindowCount(for: agentA.id, windowMinutes: 15, now: t0.addingTimeInterval(120)), 2)

        // After 15 minutes + 1s from t0, agent A's first creation expires from the window.
        let afterWindow = t0.addingTimeInterval(15 * 60 + 1)
        XCTAssertEqual(ledger.externalWindowCount(for: agentA.id, windowMinutes: 15, now: afterWindow), 1)
        let extA3 = try ledger.tryReserveSlot(
            for: .externalAgent(agentA),
            tuning: tuning,
            runningCount: 0,
            openExternalCount: 0,
            now: afterWindow
        ).get()
        ledger.commit(extA3, now: afterWindow)

        // Folder transition resets both built-in and external agent ledgers.
        ledger.setBuiltInCreatedThisReview(2)
        ledger.resetForFolderTransition()
        XCTAssertEqual(ledger.builtInCreatedThisReview, 0)
        XCTAssertEqual(ledger.externalWindowCount(for: agentA.id, windowMinutes: 15, now: afterWindow), 0)
    }

    // MARK: - The creation window across a relaunch (F6 L4)

    private let windowAgent = AgentIdentity(
        id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!, label: "claude")

    /// A creation committed now, through the real reservation.
    private func commitCreation(
        _ ledger: inout AutovisorCreationLedger, tuning: AutovisorTuning, at now: Date
    ) throws {
        let reservation = try ledger.tryReserveSlot(
            for: .externalAgent(windowAgent), tuning: tuning, runningCount: 0, openExternalCount: 0, now: now
        ).get()
        ledger.commit(reservation, now: now)
    }

    /// What a previous process left is put back, a stamp the ledger already holds is not doubled,
    /// and the stamps come back in order — the window and its reopening time read them.
    func testRestoreExternalCreations_mergesWithoutDoubling_andKeepsOrder() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = AutovisorCreationLedger()
        ledger.restoreExternalCreations([windowAgent.id: [t0.addingTimeInterval(120), t0]])
        ledger.restoreExternalCreations([windowAgent.id: [t0, t0.addingTimeInterval(60)]])

        XCTAssertEqual(ledger.externalCreationStamps[windowAgent.id],
                       [t0, t0.addingTimeInterval(60), t0.addingTimeInterval(120)])
        XCTAssertEqual(ledger.externalWindowCount(for: windowAgent.id, windowMinutes: 15, now: t0.addingTimeInterval(180)), 3)
        XCTAssertEqual(ledger.externalWindowReopensAt(for: windowAgent.id, windowMinutes: 15, now: t0.addingTimeInterval(180)),
                       t0.addingTimeInterval(15 * 60))
    }

    /// Nothing to restore leaves the ledger as it was — no empty entry for an agent with no stamp.
    func testRestoreExternalCreations_ofNothing_changesNothing() {
        var ledger = AutovisorCreationLedger()
        ledger.restoreExternalCreations([:])
        ledger.restoreExternalCreations([windowAgent.id: []])
        XCTAssertTrue(ledger.externalCreationStamps.isEmpty)
    }

    /// Restored creations fill the window like ones made in this process: a full window refuses.
    func testRestoredCreations_countAgainstTheWindow() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var tuning = AutovisorTuning.default
        tuning.maxExternalCreationsPerWindow = 2
        tuning.maxOpenExternalTasks = 10
        tuning.externalCreationWindowMinutes = 15
        var ledger = AutovisorCreationLedger()
        ledger.restoreExternalCreations([windowAgent.id: [t0, t0.addingTimeInterval(60)]])

        XCTAssertEqual(
            ledger.tryReserveSlot(for: .externalAgent(windowAgent), tuning: tuning, runningCount: 0,
                                  openExternalCount: 0, now: t0.addingTimeInterval(120)),
            .failure(.windowCreationLimitReached(limit: 2, windowMinutes: 15)))
    }

    /// A stamp out of the window but inside the retention is KEPT — counted by nothing now, found
    /// by the window once it is raised. Pruning at the window dropped it, and the store, which
    /// writes what the ledger holds, could then never give it back.
    func testAStampPastTheWindow_isKeptForTheRetention_andCountsOnceTheWindowIsRaised() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var tuning = AutovisorTuning.default
        tuning.maxExternalCreationsPerWindow = 5
        tuning.maxOpenExternalTasks = 10
        tuning.externalCreationWindowMinutes = 15
        var ledger = AutovisorCreationLedger()
        try commitCreation(&ledger, tuning: tuning, at: t0)

        let anHourLater = t0.addingTimeInterval(3_600)
        try commitCreation(&ledger, tuning: tuning, at: anHourLater)

        XCTAssertEqual(ledger.externalWindowCount(for: windowAgent.id, windowMinutes: 15, now: anHourLater), 1)
        XCTAssertEqual(ledger.externalCreationStamps[windowAgent.id]?.count, 2, "kept for the retention")
        XCTAssertEqual(ledger.externalWindowCount(for: windowAgent.id, windowMinutes: 120, now: anHourLater), 2)
    }

    /// Past the retention a stamp goes at the next reservation — the ledger does not grow forever.
    func testAStampPastTheRetention_isDroppedAtTheNextReservation() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var tuning = AutovisorTuning.default
        tuning.maxExternalCreationsPerWindow = 5
        tuning.maxOpenExternalTasks = 10
        tuning.externalCreationWindowMinutes = 15
        var ledger = AutovisorCreationLedger()
        try commitCreation(&ledger, tuning: tuning, at: t0)

        let pastRetention = t0.addingTimeInterval(
            TimeInterval(AutovisorConstants.maxExternalCreationWindowMinutes * 60) + 1)
        try commitCreation(&ledger, tuning: tuning, at: pastRetention)

        XCTAssertEqual(ledger.externalCreationStamps[windowAgent.id], [pastRetention])
    }

    /// A window set longer than the settings offer (by hand, in settings.json) keeps stamps for its
    /// own length, so the window it enforces is the one it reports.
    func testAWindowLongerThanTheSettingsOffer_keepsStampsForItsOwnLength() throws {
        XCTAssertEqual(ExternalCreationWindowStore.retentionMinutes(forWindow: 15),
                       AutovisorConstants.maxExternalCreationWindowMinutes)
        XCTAssertEqual(ExternalCreationWindowStore.retentionMinutes(forWindow: 600), 600)

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var tuning = AutovisorTuning.default
        tuning.maxExternalCreationsPerWindow = 5
        tuning.maxOpenExternalTasks = 10
        tuning.externalCreationWindowMinutes = 600
        var ledger = AutovisorCreationLedger()
        try commitCreation(&ledger, tuning: tuning, at: t0)
        let fiveHoursLater = t0.addingTimeInterval(5 * 3_600)
        try commitCreation(&ledger, tuning: tuning, at: fiveHoursLater)

        XCTAssertEqual(ledger.externalWindowCount(for: windowAgent.id, windowMinutes: 600, now: fiveHoursLater), 2)
    }

    // MARK: - authorLabel (the mark on the task's Supervisor card)

    /// One answer for "who wrote this task, if not the person", read by both the feed's card and
    /// `conversation_log.md`. The built-in Autovisor gets the word an unsigned automated turn
    /// already wears, so its card carries the same mark as its messages.
    func testAuthorLabel_namesWhoCreatedTheTask() {
        let agent = AgentIdentity(label: "Claude Code")
        XCTAssertEqual(TaskOrigin.externalAgent(agent).authorLabel, "Claude Code")
        XCTAssertEqual(TaskOrigin.builtInAutovisor.authorLabel, LLMMessage.automatedSupervisorLabel)
    }

    func testAuthorLabel_trimsAndDropsABlankAgentLabel() {
        XCTAssertEqual(TaskOrigin.externalAgent(AgentIdentity(label: "  Codex \n")).authorLabel, "Codex")
        XCTAssertNil(TaskOrigin.externalAgent(AgentIdentity(label: " \n ")).authorLabel)
    }
}
