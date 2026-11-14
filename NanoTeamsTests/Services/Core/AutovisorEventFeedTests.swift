import XCTest
@testable import NanoTeams

/// Pins §9 (`AutovisorEventFeed`) and Ш12:
/// - question re-asked between polls is delivered;
/// - `replaceAll` with a stale row does not produce a second `question`;
/// - old-folder writes during a folder transition do not enter the new epoch;
/// - snapshot without cursor;
/// - foreign epoch / folder / ring gap → cursor reset with reason and snapshot;
/// - immediate return; block then event; timeout with advanced cursor;
/// - cancellation returns `waiterCount` to 0 (+ M14 fire/cancel/timeout race coverage);
/// - `superseded` (≤2 per legacy session, ≤4 per modern agent), `folder_changed`,
///   `driver_changed`, `shutting_down`;
/// - foreign tasks' events are never delivered to an external agent;
/// - a folder switch, lost readiness or shutdown that lands while the waiter is between
///   bridges is still reported, from the state compared after every wake and before a timeout;
/// - a stopped wait hands back the position it scanned, so nothing that landed with the stop
///   is skipped;
/// - a pause is keyed by its newest paused step, so writes that leave it standing do not
///   re-deliver it, and only the pause a run timeout caused reads `timed_out`;
/// - the delivered-identity cap evicts the oldest identity, also after a snapshot reset.
@MainActor
final class AutovisorEventFeedTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agentA = AgentIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555551")!,
        label: "Claude Code"
    )
    private let agentB = AgentIdentity(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555552")!,
        label: "Codex"
    )

    /// A feed built with non-default capacities, for the tests that need one. A field released
    /// in `tearDown`, not a local (Testing Conventions).
    private var customFeed: AutovisorEventFeed!

    override func tearDown() async throws {
        customFeed = nil
        try await super.tearDown()
    }

    // MARK: - 1. Question re-asked between polls is delivered

    func testQuestionReaskedBetweenPolls_isDelivered() async throws {
        await sut.openWorkFolder(tempDir)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let createdID = await sut.createTask(
            title: "Feature Task",
            supervisorTask: "Build it",
            makeActive: true,
            origin: .externalAgent(agentA),
            requestKey: "req-1"
        )
        let taskID = try XCTUnwrap(createdID)

        // First question parked on step "engineer".
        let q1ID = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: "engineer",
                role: .softwareEngineer,
                title: "Engineer",
                status: .needsSupervisorInput,
                updatedAt: t1,
                toolCalls: [
                    StepToolCall(
                        id: q1ID,
                        createdAt: t1,
                        name: ToolNames.askSupervisor,
                        argumentsJSON: #"{"question":"Which database?"}"#,
                        resultJSON: #"{"ok":true}"#
                    )
                ],
                needsSupervisorInput: true,
                supervisorQuestion: "Which database?"
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["engineer": .working])]
        }

        let poll1 = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursor0,
            timeoutSeconds: 0
        )
        // No `created`: the agent made the task itself and has its id from that call.
        XCTAssertEqual(poll1.events.map(\.kind), [.question])
        XCTAssertEqual(poll1.events.last?.question, "Which database?")
        let cursor1 = try XCTUnwrap(poll1.cursor)

        // Between polls: Q1 is answered and Q2 is asked on the SAME step before the next poll.
        let t2 = t1.addingTimeInterval(5)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].needsSupervisorInput = false
            task.runs[0].steps[0].status = .running
            task.runs[0].steps[0].supervisorAnswer = "Use SQLite"
            task.runs[0].steps[0].updatedAt = t2
            task.runs[0].steps[0].llmConversation.append(
                LLMMessage(
                    createdAt: t2,
                    role: .user,
                    content: "Supervisor answer: Use SQLite",
                    sourceContext: .supervisorAnswer
                )
            )
        }

        let q2ID = UUID()
        let t3 = t2.addingTimeInterval(5)
        _ = await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: "engineer",
                role: .softwareEngineer,
                title: "Engineer",
                status: .needsSupervisorInput,
                updatedAt: t3,
                toolCalls: [
                    StepToolCall(
                        id: q1ID,
                        createdAt: t1,
                        name: ToolNames.askSupervisor,
                        argumentsJSON: #"{"question":"Which database?"}"#,
                        resultJSON: #"{"ok":true}"#
                    ),
                    StepToolCall(
                        id: q2ID,
                        createdAt: t3,
                        name: ToolNames.askSupervisor,
                        argumentsJSON: #"{"question":"Which schema version?"}"#,
                        resultJSON: #"{"ok":true}"#
                    ),
                ],
                needsSupervisorInput: true,
                supervisorQuestion: "Which schema version?",
                llmConversation: task.runs[0].steps[0].llmConversation
            )
            task.runs[0].steps[0] = step
        }

        let poll2 = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursor1,
            timeoutSeconds: 0
        )
        XCTAssertEqual(poll2.events.map(\.kind), [.question], "Re-asked question between polls must be delivered")
        XCTAssertEqual(poll2.events.first?.question, "Which schema version?")
        XCTAssertEqual(poll2.events.first?.roleID, "engineer")
    }

    // MARK: - 2. replaceAll with a stale row does not produce a second question

    func testReplaceAllWithStaleRow_doesNotProduceDuplicateQuestion() async throws {
        await sut.openWorkFolder(tempDir)

        let createdID = await sut.createTask(
            title: "Question Task",
            supervisorTask: "Ask once",
            makeActive: true,
            origin: .externalAgent(agentA)
        )
        let taskID = try XCTUnwrap(createdID)

        let qID = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        _ = await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: "engineer",
                role: .softwareEngineer,
                title: "Engineer",
                status: .needsSupervisorInput,
                updatedAt: t1,
                toolCalls: [
                    StepToolCall(
                        id: qID,
                        createdAt: t1,
                        name: ToolNames.askSupervisor,
                        argumentsJSON: #"{"question":"First and only question?"}"#,
                        resultJSON: #"{"ok":true}"#
                    )
                ],
                needsSupervisorInput: true,
                supervisorQuestion: "First and only question?"
            )
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["engineer": .working])]
        }

        let firstPoll = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: nil,
            timeoutSeconds: 0
        )
        XCTAssertEqual(firstPoll.events.map(\.kind), [.question])
        let cursorAfterFirst = try XCTUnwrap(firstPoll.cursor)

        // Simulate a whole-index `replaceAll` carrying a stale disk row (not waiting),
        // followed by a `replaceAll` carrying the waiting row again (D6).
        let currentSummary = try XCTUnwrap(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID }))
        var staleSummary = currentSummary
        staleSummary.status = .running
        staleSummary.hasPendingSupervisorInput = false
        staleSummary.pendingSupervisorQuestionCount = 0
        staleSummary.updatedAt = t1.addingTimeInterval(-10)

        sut.taskFacts.replaceAll(with: [staleSummary])
        sut.taskFacts.replaceAll(with: [currentSummary])

        let secondPoll = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursorAfterFirst,
            timeoutSeconds: 0
        )
        XCTAssertTrue(
            secondPoll.events.isEmpty,
            "replaceAll with a stale row followed by the same question row must not emit a duplicate question"
        )
    }

    // MARK: - 3. Old-folder writes do not leak into the new epoch

    func testDisarmedDuringFolderTransition_oldFolderWritesDoNotLeakIntoNewEpoch() async throws {
        await sut.openWorkFolder(tempDir)
        let createdOldID = await sut.createTask(
            title: "Old Folder Task",
            supervisorTask: "Brief",
            makeActive: true,
            origin: .externalAgent(agentA)
        )
        let oldTaskID = try XCTUnwrap(createdOldID)
        let oldRow = try XCTUnwrap(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == oldTaskID }))

        // Disarm at the start of a folder transition.
        sut.autovisorEventFeed.disarmForFolderTransition()
        XCTAssertFalse(sut.autovisorEventFeed.isArmed)

        // Simulate late writes / cancelled steps unwinding from the old folder before the new folder commits.
        var lateWaitingRow = oldRow
        lateWaitingRow.status = .needsSupervisorInput
        lateWaitingRow.hasPendingSupervisorInput = true
        lateWaitingRow.pendingSupervisorQuestionCount = 1
        lateWaitingRow.updatedAt = Date()
        sut.taskFacts.replaceAll(with: [lateWaitingRow])
        sut.autovisorEventFeed.recordResumed(taskID: oldTaskID, by: .person)
        sut.autovisorEventFeed.recordClosed(taskID: oldTaskID, by: .person)
        sut.autovisorEventFeed.recordDeleted(
            taskID: oldTaskID,
            origin: .externalAgent(agentA),
            title: "Old Folder Task",
            by: .person
        )

        // Open a second work folder — commits a new epoch.
        let secondDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMSFeedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondDir) }

        await sut.openWorkFolder(secondDir)
        XCTAssertTrue(sut.autovisorEventFeed.isArmed)
        XCTAssertEqual(sut.autovisorEventFeed.headSeq, 0, "New folder epoch must start at seq 0 with no leaked writes")

        let newFolderID = try XCTUnwrap(sut.snapshot?.projection.id)
        let newEpoch = sut.autovisorEventFeed.epochToken
        let poll = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: "\(newFolderID.uuidString):\(newEpoch):0",
            timeoutSeconds: 0
        )
        XCTAssertTrue(poll.events.isEmpty)
    }

    // MARK: - 4. Snapshot without cursor

    /// What `folder_status`' description says about `event_cursor`, held against the feed: it is
    /// the HEAD, so a wait from it returns only what happens after it, and a question already
    /// standing reaches the agent only through a call without a cursor. A session that resumed
    /// from this cursor never heard of the question (2026-11-08). If the feed ever starts handing
    /// standing conditions to a wait from the head, that description has to change with it.
    func testAWaitFromFolderStatusCursorSkipsAStandingQuestion_thatACallWithoutOneDelivers() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        let created = await sut.createTask(
            title: "Waiting Question", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "eng", role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput,
                    needsSupervisorInput: true, supervisorQuestion: "Need API key?")],
                roleStatuses: ["eng": .working])]
        }

        let status = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.folderStatus, args: [:], agent: agentA)
        let statusEnvelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(status.outputJSON.utf8)) as? [String: Any])
        let cursor = try XCTUnwrap((statusEnvelope["data"] as? [String: Any])?["event_cursor"] as? String)

        let fromCursor = await sut.autovisorEventFeed.waitForEvents(agentID: agentA.id, after: cursor, timeoutSeconds: 0)
        XCTAssertEqual(fromCursor.events.map(\.kind), [], "a wait from the head returns only what happens after it")
        XCTAssertNil(fromCursor.cursorResetReason)

        let firstCall = await sut.autovisorEventFeed.waitForEvents(agentID: agentA.id, timeoutSeconds: 0)
        XCTAssertEqual(firstCall.events.map(\.kind), [.question])
        XCTAssertEqual(firstCall.events.first?.taskID, taskID)
    }

    func testSnapshotWithoutCursor_returnsCurrentStandingConditionsAndHeadCursor() async throws {
        await sut.openWorkFolder(tempDir)

        // 1) Task waiting on a question
        let qCreated = await sut.createTask(
            title: "Waiting Question",
            supervisorTask: "Brief 1",
            makeActive: false,
            origin: .externalAgent(agentA)
        )
        let qTaskID = try XCTUnwrap(qCreated)
        await sut.ensureTaskLoaded(qTaskID)
        _ = await sut.mutateTask(taskID: qTaskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [
                    StepExecution(
                        id: "eng",
                        role: .softwareEngineer,
                        title: "Engineer",
                        status: .needsSupervisorInput,
                        needsSupervisorInput: true,
                        supervisorQuestion: "Need API key?"
                    )
                ],
                roleStatuses: ["eng": .working]
            )]
        }

        // 2) Task at review (.needsSupervisorAcceptance)
        let reviewCreated = await sut.createTask(
            title: "In Review",
            supervisorTask: "Brief 2",
            makeActive: false,
            origin: .externalAgent(agentA)
        )
        let reviewTaskID = try XCTUnwrap(reviewCreated)
        await sut.ensureTaskLoaded(reviewTaskID)
        _ = await sut.mutateTask(taskID: reviewTaskID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [
                    StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .done)
                ],
                roleStatuses: ["eng": .needsAcceptance]
            )]
        }

        // 3) Task paused by timeout
        let pausedCreated = await sut.createTask(
            title: "Paused Task",
            supervisorTask: "Brief 3",
            makeActive: false,
            origin: .externalAgent(agentA)
        )
        let pausedTaskID = try XCTUnwrap(pausedCreated)
        await sut.ensureTaskLoaded(pausedTaskID)
        _ = await sut.mutateTask(taskID: pausedTaskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [
                    StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .paused)
                ],
                roleStatuses: ["eng": .working],
                timedOutAt: Date()
            )]
        }

        // 4) Task closed
        let closedCreated = await sut.createTask(
            title: "Closed Task",
            supervisorTask: "Brief 4",
            makeActive: false,
            origin: .externalAgent(agentA)
        )
        let closedTaskID = try XCTUnwrap(closedCreated)
        _ = await sut.closeTask(taskID: closedTaskID)

        let snapshotResult = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: nil,
            timeoutSeconds: 0
        )
        XCTAssertNil(snapshotResult.cursorResetReason)
        XCTAssertFalse(snapshotResult.timedOut)
        XCTAssertEqual(snapshotResult.cursor, sut.autovisorEventFeed.currentCursor)

        XCTAssertEqual(
            snapshotResult.events.filter { $0.taskID == qTaskID }.map(\.kind),
            [.question],
            "events: \(snapshotResult.events)"
        )
        XCTAssertEqual(
            snapshotResult.events.filter { $0.taskID == reviewTaskID }.map(\.kind),
            [.review],
            "events: \(snapshotResult.events)"
        )
        XCTAssertEqual(
            snapshotResult.events.filter { $0.taskID == pausedTaskID }.map(\.kind),
            [.paused],
            "events: \(snapshotResult.events)"
        )
        // A closed task waits on nobody: a snapshot reports what stands, not what is over.
        XCTAssertEqual(
            snapshotResult.events.filter { $0.taskID == closedTaskID }.map(\.kind),
            [],
            "events: \(snapshotResult.events)"
        )
        XCTAssertEqual(snapshotResult.events.compactMap(\.seq), [], "a snapshot's events are at no place in the feed")

        let pausedEvent = snapshotResult.events.first(where: { $0.taskID == pausedTaskID })
        XCTAssertEqual(pausedEvent?.pauseReason, .timedOut)

        // Polling immediately with the returned cursor must not re-emit the snapshot conditions.
        let followUp = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: snapshotResult.cursor,
            timeoutSeconds: 0
        )
        XCTAssertTrue(followUp.events.isEmpty)
    }

    // MARK: - 5. Foreign epoch / folder / ring gap → cursor reset

    func testForeignEpochAndFolderAndGap_resetsCursorWithReasonAndSnapshot() async throws {
        await sut.openWorkFolder(tempDir)
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id)

        let createdID = await sut.createTask(
            title: "Failed Task",
            supervisorTask: "Brief",
            makeActive: true,
            origin: .externalAgent(agentA)
        )
        let taskID = try XCTUnwrap(createdID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [
                    StepExecution(
                        id: "eng",
                        role: .softwareEngineer,
                        title: "Engineer",
                        status: .failed,
                        messages: [StepMessage(role: .softwareEngineer, content: "\(StepExecution.llmErrorNotePrefix): Compiler error")]
                    )
                ],
                roleStatuses: ["eng": .failed]
            )]
        }

        // 5a) Foreign folder_id -> .folderChanged
        let foreignFolderCursor = "\(UUID().uuidString):\(sut.autovisorEventFeed.epochToken):1"
        let folderReset = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: foreignFolderCursor,
            timeoutSeconds: 0
        )
        XCTAssertEqual(folderReset.cursorResetReason, .folderChanged)
        XCTAssertEqual(folderReset.events.map(\.kind), [.failed])

        // 5b) Foreign epoch -> .restarted (also test bumpEpochForServerEnable)
        let oldCursor = try XCTUnwrap(folderReset.cursor)
        sut.autovisorEventFeed.bumpEpochForServerEnable()
        let epochReset = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: oldCursor,
            timeoutSeconds: 0
        )
        XCTAssertEqual(epochReset.cursorResetReason, .restarted)
        XCTAssertEqual(epochReset.events.map(\.kind), [.failed])

        // 5c) Ring buffer gap -> .gap
        let cursorAtZero = "\(folderID.uuidString):\(sut.autovisorEventFeed.epochToken):0"
        for i in 0..<(AutovisorEventFeed.defaultRingCapacity + 10) {
            sut.autovisorEventFeed.recordDeleted(
                taskID: 10_000 + i,
                origin: .builtInAutovisor,
                title: "Noise \(i)",
                by: .person
            )
        }
        let gapReset = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursorAtZero,
            timeoutSeconds: 0
        )
        XCTAssertEqual(gapReset.cursorResetReason, .gap)
        XCTAssertEqual(gapReset.events.map(\.kind), [.failed])
    }

    // MARK: - 6. Immediate return; block then event; timeout with advanced cursor

    func testWaitModes_immediateReturn_blockThenEvent_timeoutWithAdvancedCursor() async throws {
        await sut.openWorkFolder(tempDir)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let createdID = await sut.createTask(
            title: "Async Task",
            supervisorTask: "Brief",
            makeActive: true,
            origin: .externalAgent(agentA)
        )
        let taskID = try XCTUnwrap(createdID)
        _ = await sut.closeTask(taskID: taskID)

        // 6a) Immediate return when event is already in the ring — the person's close.
        let immediate = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursor0,
            timeoutSeconds: 10
        )
        XCTAssertFalse(immediate.timedOut)
        XCTAssertEqual(immediate.events.map(\.kind), [.closed])
        XCTAssertEqual(immediate.events.first?.by, .person)
        let cursor1 = try XCTUnwrap(immediate.cursor)

        // 6b) Block, then event arrives and wakes waiter before timeout
        let waitTask = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                after: cursor1,
                timeoutSeconds: 10
            )
        }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1)

        await sut.removeTask(taskID)
        let woken = await waitTask.value
        XCTAssertFalse(woken.timedOut)
        XCTAssertEqual(woken.events.map(\.kind), [.deleted])
        XCTAssertEqual(woken.events.first?.by, .person)
        let cursor2 = try XCTUnwrap(woken.cursor)

        // 6c) Timeout with advanced cursor (when irrelevant/foreign candidates advance headSeq)
        let timeoutTask = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                after: cursor2,
                timeoutSeconds: 0.15
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        // Something happens to another agent's task while this one is waiting.
        recordForeignCandidate()
        let timedOutResult = await timeoutTask.value
        XCTAssertTrue(timedOutResult.timedOut)
        XCTAssertTrue(timedOutResult.events.isEmpty)
        XCTAssertNotEqual(timedOutResult.cursor, cursor2, "Timeout must return the advanced head cursor")
        XCTAssertEqual(timedOutResult.cursor, sut.autovisorEventFeed.currentCursor)
    }

    // MARK: - A wait in progress, for the auto-off tick

    /// The auto-off tick asks whether the agent is waiting in this folder at all
    /// (`hasWaitInProgress`) — any agent, any scope — so the sleep timer cannot end a wait the
    /// agent parked as its way of supervising. Counted per wait CALL, not per registered bridge:
    /// a candidate wakes every bridge and empties the registry at once, and a wait that then finds
    /// nothing of its own re-registers only on its next turn. In between it is still waiting.
    func testHasWaitInProgress_holdsForTheWholeWait_includingBetweenItsBridges() async throws {
        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress, "nothing waits yet")

        let wait = Task { @MainActor in
            await self.sut.autovisorEventFeed.waitForEvents(agentID: self.agentA.id, timeoutSeconds: 30)
        }
        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "premise: the wait is parked")
        XCTAssertTrue(sut.autovisorEventFeed.hasWaitInProgress)

        // Another agent's task: every bridge is woken and dropped, and this wait has nothing.
        recordForeignCandidate()
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0, "premise: the wake emptied the bridge registry")
        XCTAssertTrue(sut.autovisorEventFeed.hasWaitInProgress, "between bridges the wait is still the agent's")

        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "premise: it parked again")

        wait.cancel()
        _ = await wait.value
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress, "a wait that returned is not in progress")
    }

    /// A call that returns at once — a snapshot, a zero timeout — was never in progress, and a
    /// wait the folder transition interrupted is not this folder's even before it resumes.
    func testHasWaitInProgress_isFalseForAnImmediateAnswer_andForAnotherFolder() async throws {
        await sut.openWorkFolder(tempDir)

        _ = await sut.autovisorEventFeed.waitForEvents(agentID: agentA.id, timeoutSeconds: 0)
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress)

        let wait = Task { @MainActor in
            await self.sut.autovisorEventFeed.waitForEvents(agentID: self.agentA.id, timeoutSeconds: 30)
        }
        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertTrue(sut.autovisorEventFeed.hasWaitInProgress, "premise: parked")

        sut.autovisorEventFeed.disarmForFolderTransition()
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress, "a disarmed feed has no folder to wait in")
        sut.autovisorEventFeed.activateFolder(folderID: UUID())
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress, "the interrupted wait belongs to the folder before")

        let result = await wait.value
        XCTAssertEqual(result.stopReason, .folderChanged)
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress)
    }

    /// The count is per CALL, not per agent: with two waits of one agent in progress (a modern
    /// agent may hold four), the agent is waiting until the LAST of them ends — the first to
    /// return leaves the other's count behind, and only the last removes it.
    func testTwoWaitsOfOneAgent_theAgentWaitsUntilTheLastOneEnds() async throws {
        await sut.openWorkFolder(tempDir)
        let first = await parkedWait(on: sut.autovisorEventFeed, after: nil, timeoutSeconds: 30)
        let second = await parkedWait(on: sut.autovisorEventFeed, after: nil, timeoutSeconds: 30)
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 2, "premise: both parked")
        XCTAssertTrue(sut.autovisorEventFeed.hasWaitInProgress(forAgentID: agentA.id))

        first.cancel()
        _ = await first.value
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "one bridge left")
        XCTAssertTrue(sut.autovisorEventFeed.hasWaitInProgress(forAgentID: agentA.id), "the other wait is still the agent's")
        XCTAssertTrue(sut.autovisorEventFeed.hasWaitInProgress)

        second.cancel()
        _ = await second.value
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0)
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress(forAgentID: agentA.id), "the last wait ended")
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress)
    }

    // MARK: - What waits on the agent

    /// The classification the auto-off banner reads (`hasConditionAwaitingAnAgent`), decided per
    /// kind and, for a pause, per reason. Written out as a table so a new kind or reason has to
    /// be placed here as well as in the exhaustive switches. Value types only: no orchestrator.
    func testWhatWaitsOnTheAgent_isDecidedPerKindAndPerPauseReason() {
        typealias Shape = AutovisorEventKind.Shape
        let standing: [AutovisorEventKind: (shape: Shape, mayAwait: Bool)] = [
            .question: (.standing(.question), true), .acceptanceGate: (.standing(.acceptanceGate), true),
            .review: (.standing(.review), true), .failed: (.standing(.failed), true),
            .paused: (.standing(.paused), true), .stuck: (.standing(.stuck), true),
            .resumed: (.moment(.resumed), false), .closed: (.moment(.closed), false),
            .deleted: (.moment(.deleted), false),
        ]
        XCTAssertEqual(Set(standing.keys), Set(AutovisorEventKind.allCases), "every kind is placed")
        for kind in AutovisorEventKind.allCases {
            XCTAssertEqual(kind.shape, standing[kind]?.shape, "\(kind)")
            XCTAssertEqual(kind.mayAwaitItsAgent, standing[kind]?.mayAwait, "\(kind)")
        }
        // The standing kinds are a type of their own, and the two maps between it and the kind
        // agree: every standing kind names the kind whose shape it is, in the kinds' own order —
        // the order a snapshot reports conditions in.
        for standingKind in AutovisorEventKind.Standing.allCases {
            XCTAssertEqual(standingKind.kind.shape, .standing(standingKind), "\(standingKind)")
        }
        XCTAssertEqual(
            AutovisorEventKind.Standing.allCases.map(\.kind),
            AutovisorEventKind.allCases.filter { if case .standing = $0.shape { true } else { false } })

        let resumedByTheAgent: [AutovisorPauseReason: Bool] = [
            .byAgent: true, .timedOut: true, .iterationLimit: true, .recovered: true, .byPerson: false,
        ]
        XCTAssertEqual(Set(resumedByTheAgent.keys), Set(AutovisorPauseReason.allCases), "every reason is placed")
        for reason in AutovisorPauseReason.allCases {
            XCTAssertEqual(reason.awaitsTheAgent, resumedByTheAgent[reason], "\(reason)")
            let pause = AutovisorEvent(seq: 1, taskID: 1, kind: .paused, title: "T", pauseReason: reason)
            XCTAssertEqual(pause.awaitsItsAgent, resumedByTheAgent[reason], "a pause: \(reason)")
        }
        XCTAssertFalse(
            AutovisorEvent(seq: 1, taskID: 1, kind: .paused, title: "T").awaitsItsAgent,
            "a pause whose reason nobody knows is not claimed for the agent")
        for kind in AutovisorEventKind.allCases where kind != .paused {
            XCTAssertEqual(
                AutovisorEvent(seq: 1, taskID: 1, kind: kind, title: "T").awaitsItsAgent,
                standing[kind]?.mayAwait, "\(kind)")
        }
    }

    /// The banner's reading is the feed's, and a feed that cannot read — unarmed, or armed with
    /// no orchestrator to read tasks from — reports nothing waiting rather than guessing. A
    /// question standing on an agent's task waits on that agent; the moment a folder transition
    /// disarms the feed, the same question is nobody's to report here.
    func testHasConditionAwaitingAnAgent_isFalseWhenTheFeedCannotRead_andFollowsTheFolder() async throws {
        customFeed = AutovisorEventFeed()
        XCTAssertFalse(customFeed.hasConditionAwaitingAnAgent(), "unarmed, and no store")
        customFeed.activateFolder(folderID: UUID())
        XCTAssertFalse(customFeed.hasConditionAwaitingAnAgent(), "armed, but no store to read tasks from")

        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(sut.autovisorEventFeed.hasConditionAwaitingAnAgent(), "no task at all")

        let taskID = try await createOwnTask("Needs an answer")
        XCTAssertFalse(sut.autovisorEventFeed.hasConditionAwaitingAnAgent(), "a task with nothing standing on it")
        _ = await sut.mutateTask(taskID: taskID) { task in
            let step = StepExecution(
                id: "engineer", role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput,
                toolCalls: [
                    StepToolCall(
                        name: ToolNames.askSupervisor,
                        argumentsJSON: #"{"question":"Which database?"}"#,
                        resultJSON: #"{"ok":true}"#),
                ],
                needsSupervisorInput: true,
                supervisorQuestion: "Which database?")
            task.runs = [Run(id: 0, steps: [step], roleStatuses: ["engineer": .working])]
        }
        XCTAssertTrue(sut.autovisorEventFeed.hasConditionAwaitingAnAgent(), "a question on the agent's task waits on it")

        sut.autovisorEventFeed.disarmForFolderTransition()
        XCTAssertFalse(
            sut.autovisorEventFeed.hasConditionAwaitingAnAgent(),
            "disarmed: the folder is going away, and nothing in it is this feed's to report")
    }

    // MARK: - An agent's presence, from the same count

    /// Presence reads the same per-call count, by agent: an agent whose wait is in progress is
    /// present for the whole wait, between its bridges too. Review of 2026-11-08: presence read
    /// the bridge registry, which a candidate for ANY task empties at once, so an agent whose
    /// wait had outlived the presence window read as away until the wait parked again.
    func testPresence_holdsForTheWholeWait_includingBetweenItsBridges() async throws {
        await sut.openWorkFolder(tempDir)
        XCTAssertFalse(sut.isHostedMCPAgentPresent(agentA.id), "premise: never seen, nothing waits")

        let wait = Task { @MainActor in
            await self.sut.autovisorEventFeed.waitForEvents(agentID: self.agentA.id, timeoutSeconds: 30)
        }
        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "premise: the wait is parked")
        XCTAssertTrue(sut.isHostedMCPAgentPresent(agentA.id))

        // Another agent's task: every bridge is woken and dropped, and this wait has nothing.
        recordForeignCandidate()
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0, "premise: the wake emptied the bridge registry")
        XCTAssertTrue(sut.hasActiveHostedMCPWait(forAgent: agentA.id), "between bridges the wait is still A's")
        XCTAssertTrue(sut.isHostedMCPAgentPresent(agentA.id), "and A is still present")
        XCTAssertFalse(sut.hasActiveHostedMCPWait(forAgent: agentB.id), "B woke nothing of its own")
        XCTAssertFalse(sut.isHostedMCPAgentPresent(agentB.id))

        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "premise: it parked again")

        wait.cancel()
        _ = await wait.value
        XCTAssertFalse(sut.hasActiveHostedMCPWait(forAgent: agentA.id), "a wait that returned is not in progress")
        XCTAssertFalse(sut.isHostedMCPAgentPresent(agentA.id))
    }

    /// The pane re-reads presence when `hostedMCPAgentsRevision` moves, so the END of a wait must
    /// move it. After a token rotation (`cancelWaiters`) or any wake the registry is already
    /// empty, and the only thing that changes when the wait returns is the count.
    func testTheEndOfAWait_movesTheRevisionPresenceIsReadOn() async throws {
        await sut.openWorkFolder(tempDir)
        let wait = Task { @MainActor in
            await self.sut.autovisorEventFeed.waitForEvents(agentID: self.agentA.id, timeoutSeconds: 30)
        }
        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "premise: the wait is parked")

        sut.autovisorEventFeed.cancelWaiters(forAgentID: agentA.id)
        let revisionAfterTheCancel = sut.hostedMCPAgentsRevision
        XCTAssertTrue(sut.hasActiveHostedMCPWait(forAgent: agentA.id), "the cancelled wait has not returned yet")

        _ = await wait.value
        XCTAssertFalse(sut.hasActiveHostedMCPWait(forAgent: agentA.id))
        XCTAssertGreaterThan(
            sut.hostedMCPAgentsRevision, revisionAfterTheCancel,
            "the pane must hear that the wait ended, or it shows the agent waiting")
    }

    /// Presence is the folder's, like `hasWaitInProgress`: a wait the folder transition
    /// interrupted is not a wait in the next folder, even before it resumes.
    func testPresence_isNotHeldByAWaitOfTheFolderBefore() async throws {
        await sut.openWorkFolder(tempDir)
        let wait = Task { @MainActor in
            await self.sut.autovisorEventFeed.waitForEvents(agentID: self.agentA.id, timeoutSeconds: 30)
        }
        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertTrue(sut.hasActiveHostedMCPWait(forAgent: agentA.id), "premise: parked")

        sut.autovisorEventFeed.disarmForFolderTransition()
        XCTAssertFalse(sut.hasActiveHostedMCPWait(forAgent: agentA.id), "a disarmed feed has no folder to wait in")
        sut.autovisorEventFeed.activateFolder(folderID: UUID())
        XCTAssertFalse(sut.hasActiveHostedMCPWait(forAgent: agentA.id), "the interrupted wait belongs to the folder before")

        let result = await wait.value
        XCTAssertEqual(result.stopReason, .folderChanged)
        XCTAssertFalse(sut.hasActiveHostedMCPWait(forAgent: agentA.id))
    }

    // MARK: - 7. Cancellation returns waiterCount to 0 (+ M14 races)

    func testCancellation_returnsWaiterCountToZero() async throws {
        await sut.openWorkFolder(tempDir)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let w1 = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                sessionID: "sess-1",
                after: cursor,
                timeoutSeconds: 30
            )
        }
        let w2 = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                sessionID: "sess-1",
                after: cursor,
                timeoutSeconds: 30
            )
        }

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 2)

        w1.cancel()
        w2.cancel()
        _ = await w1.value
        _ = await w2.value

        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0, "Cancellation must return waiterCount to 0")

        // M14: race fire, cancel, and timeout across multiple iterations without leaking waiters.
        for _ in 0..<25 {
            let current = sut.autovisorEventFeed.currentCursor
            let raceWait = Task { @MainActor in
                await sut.autovisorEventFeed.waitForEvents(
                    agentID: agentA.id,
                    after: current,
                    timeoutSeconds: 0.01
                )
            }
            sut.autovisorEventFeed.recordDeleted(
                taskID: 5000,
                origin: .builtInAutovisor,
                title: "Race",
                by: .person
            )
            raceWait.cancel()
            _ = await raceWait.value
            XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0)
        }
    }

    // MARK: - 8. superseded, folder_changed, driver_changed, shutting_down

    /// Re-selecting the driver the folder already has changes nothing a wait answers for, so the
    /// wait goes on to its timeout.
    ///
    /// RED before 2026-11-07: `setAutovisorDriver` woke every wait with `driver_changed` whatever
    /// it was asked to set, and the wait ended with that reason.
    func testSettingTheSameDriverAgain_doesNotEndAWait() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        _ = await sut.setAutovisorEnabled(true)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let wait = Task { @MainActor in
            await self.sut.autovisorEventFeed.waitForEvents(agentID: self.agentA.id, after: cursor, timeoutSeconds: 1)
        }
        for _ in 0..<200 where sut.autovisorEventFeed.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "premise: the wait is parked")

        await sut.setAutovisorDriver(.externalAgent)

        let result = await wait.value
        XCTAssertNil(result.stopReason, "the driver did not change")
        XCTAssertTrue(result.timedOut)
    }

    func testWaitInterruptions_superseded_folderChanged_driverChanged_shuttingDown() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        _ = await sut.setAutovisorEnabled(true)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        // 8a) Legacy session limit: <= 2 concurrent waits per (agentID, sessionID)
        let legacy1 = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                sessionID: "legacy-s1",
                after: cursor,
                timeoutSeconds: 30
            )
        }
        let legacy2 = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                sessionID: "legacy-s1",
                after: cursor,
                timeoutSeconds: 30
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 2)

        // Starting a 3rd wait in the same legacy session evicts the oldest (legacy1).
        let legacy3 = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                sessionID: "legacy-s1",
                after: cursor,
                timeoutSeconds: 30
            )
        }
        let evictedLegacy = await legacy1.value
        XCTAssertTrue(evictedLegacy.superseded)
        XCTAssertEqual(evictedLegacy.stopReason, .superseded)
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 2)
        legacy2.cancel()
        legacy3.cancel()
        _ = await legacy2.value
        _ = await legacy3.value
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0)

        // 8b) Modern era limit: <= 4 concurrent waits per agentID (sessionID == nil)
        var modernTasks: [Task<AutovisorWaitResult, Never>] = []
        for _ in 0..<4 {
            modernTasks.append(Task { @MainActor in
                await sut.autovisorEventFeed.waitForEvents(
                    agentID: agentA.id,
                    sessionID: nil,
                    after: cursor,
                    timeoutSeconds: 30
                )
            })
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 4)

        let modern5 = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                sessionID: nil,
                after: cursor,
                timeoutSeconds: 30
            )
        }
        let evictedModern = await modernTasks[0].value
        XCTAssertTrue(evictedModern.superseded)
        XCTAssertEqual(evictedModern.stopReason, .superseded)
        for t in modernTasks.dropFirst() { t.cancel(); _ = await t.value }
        modern5.cancel()
        _ = await modern5.value
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0)

        // 8c) driver_changed when switching driver to .builtInModel
        let driverWait = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                after: cursor,
                timeoutSeconds: 30
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        await sut.setAutovisorDriver(.builtInModel)
        let driverResult = await driverWait.value
        XCTAssertEqual(driverResult.stopReason, .driverChanged)
        await sut.setAutovisorDriver(.externalAgent)

        // 8d) folder_changed when opening another folder
        let cursorBeforeFolderSwitch = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let folderWait = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                after: cursorBeforeFolderSwitch,
                timeoutSeconds: 30
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let otherDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMSFeedOther-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherDir) }
        await sut.openWorkFolder(otherDir)

        let folderResult = await folderWait.value
        XCTAssertEqual(folderResult.stopReason, .folderChanged)
        XCTAssertEqual(folderResult.cursorResetReason, .folderChanged)

        // 8e) shutting_down when app terminates
        let newCursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let shutdownWait = Task { @MainActor in
            await sut.autovisorEventFeed.waitForEvents(
                agentID: agentA.id,
                after: newCursor,
                timeoutSeconds: 30
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        await sut.shutdownForTermination()
        let shutdownResult = await shutdownWait.value
        XCTAssertEqual(shutdownResult.stopReason, .shuttingDown)
    }

    // MARK: - 9. Foreign tasks' events are never delivered

    func testForeignTaskEvents_areNeverDeliveredToAgent() async throws {
        await sut.openWorkFolder(tempDir)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        // Human task
        let humanCreated = await sut.createTask(
            title: "Human Task",
            supervisorTask: "Brief",
            makeActive: false,
            origin: nil
        )
        let humanID = try XCTUnwrap(humanCreated)
        // Built-in Autovisor task
        let builtInCreated = await sut.createTask(
            title: "Built-In Task",
            supervisorTask: "Brief",
            makeActive: false,
            origin: .builtInAutovisor
        )
        let builtInID = try XCTUnwrap(builtInCreated)
        // Other external agent's task
        let otherCreated = await sut.createTask(
            title: "Agent B Task",
            supervisorTask: "Brief",
            makeActive: false,
            origin: .externalAgent(agentB)
        )
        let otherAgentID = try XCTUnwrap(otherCreated)

        for id in [humanID, builtInID, otherAgentID] {
            await sut.ensureTaskLoaded(id)
            _ = await sut.mutateTask(taskID: id) { task in
                task.runs = [Run(
                    id: 0,
                    steps: [
                        StepExecution(
                            id: "eng",
                            role: .softwareEngineer,
                            title: "Engineer",
                            status: .needsSupervisorInput,
                            needsSupervisorInput: true,
                            supervisorQuestion: "Foreign question?"
                        )
                    ],
                    roleStatuses: ["eng": .working]
                )]
            }
            _ = await sut.closeTask(taskID: id)
        }
        await sut.removeTask(otherAgentID)

        // Agent A polls from cursor0: must see zero events
        let pollA = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursor0,
            timeoutSeconds: 0
        )
        XCTAssertTrue(pollA.events.isEmpty, "Foreign tasks' events must never be delivered to Agent A")

        // Agent A snapshot (after: nil): must also see zero events
        let snapshotA = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: nil,
            timeoutSeconds: 0
        )
        XCTAssertTrue(snapshotA.events.isEmpty, "Snapshot for Agent A must exclude foreign tasks")

        // Meanwhile Agent B receives its own deleted task event from cursor0!
        let pollB = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentB.id,
            after: cursor0,
            timeoutSeconds: 0
        )
        XCTAssertTrue(pollB.events.allSatisfy { $0.taskID == otherAgentID })
        XCTAssertTrue(pollB.events.map(\.kind).contains(.deleted))
    }

    // MARK: - 10. Acceptance gate, stuck episode dedup/re-arm, and iteration-limit pause

    func testAcceptanceGate_stuckEpisode_andIterationLimitPause() async throws {
        await sut.openWorkFolder(tempDir)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let created = await sut.createTask(
            title: "Pipeline Task",
            supervisorTask: "Brief",
            makeActive: true,
            origin: .externalAgent(agentA)
        )
        let taskID = try XCTUnwrap(created)

        // 1) Acceptance gate: non-chat task with one role at .needsAcceptance and downstream .idle
        let completedAt = Date(timeIntervalSince1970: 1_700_006_800)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [
                    StepExecution(
                        id: "architect",
                        role: .techLead,
                        title: "Architect",
                        status: .done,
                        completedAt: completedAt
                    )
                ],
                roleStatuses: ["architect": .needsAcceptance, "engineer": .idle]
            )]
        }

        let pollGate = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursor0,
            timeoutSeconds: 0
        )
        XCTAssertEqual(pollGate.events.map(\.kind), [.acceptanceGate])
        XCTAssertEqual(pollGate.events.last?.roleID, "architect")
        let cursorAfterGate = try XCTUnwrap(pollGate.cursor)

        // 2) Stuck episode: emits once, repeat tick does not re-emit, clears when not stuck, re-emits on new episode
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps = [
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Engineer", status: .running)
            ]
            task.runs[0].roleStatuses = ["architect": .done, "engineer": .working]
        }
        let tStuck1 = Date(timeIntervalSince1970: 1_700_100_000)
        sut.autovisorEventFeed.recordStuckTasks([taskID], now: tStuck1)

        let pollStuck1 = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursorAfterGate,
            timeoutSeconds: 0
        )
        XCTAssertEqual(pollStuck1.events.map(\.kind), [.stuck])
        let cursorAfterStuck1 = try XCTUnwrap(pollStuck1.cursor)

        // Second tick in the same stuck episode: must NOT re-emit
        sut.autovisorEventFeed.recordStuckTasks([taskID], now: tStuck1.addingTimeInterval(60))
        let pollStuckRepeat = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursorAfterStuck1,
            timeoutSeconds: 0
        )
        XCTAssertTrue(pollStuckRepeat.events.isEmpty, "Same stuck episode must not re-emit")
        let cursorAfterStuckRepeat = try XCTUnwrap(pollStuckRepeat.cursor)

        // Episode clears, then a new stuck episode starts -> must re-emit
        sut.autovisorEventFeed.recordStuckTasks([], now: tStuck1.addingTimeInterval(120))
        sut.autovisorEventFeed.recordStuckTasks([taskID], now: tStuck1.addingTimeInterval(180))
        let pollStuck2 = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursorAfterStuckRepeat,
            timeoutSeconds: 0
        )
        XCTAssertEqual(pollStuck2.events.map(\.kind), [.stuck])
        let cursorAfterStuck2 = try XCTUnwrap(pollStuck2.cursor)

        // 3) Iteration-limit pause via engine hook
        let engine = sut.engineForTask(taskID)
        engine.pausedIterationLimit = 10
        engine.onIterationLimitPaused?(10)

        let pollIterPause = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursorAfterStuck2,
            timeoutSeconds: 0
        )
        XCTAssertEqual(pollIterPause.events.map(\.kind), [.paused])
        XCTAssertEqual(pollIterPause.events.first?.pauseReason, .iterationLimit)
    }

    // MARK: - 11. Unloaded task hydration via ensureTaskLoadedSync (§2.5 Rule 10 & §9)

    func testUnloadedTaskHydration_recoversStaleRunningQuestionViaEnsureTaskLoaded() async throws {
        await sut.openWorkFolder(tempDir)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let created = await sut.createTask(
            title: "Crash-Interrupted Question Task",
            supervisorTask: "Brief",
            makeActive: false,
            origin: .externalAgent(agentA)
        )
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)

        let now = Date(timeIntervalSince1970: 1_700_182_000)
        // First record a question transition so a `.question` candidate is in the ring.
        _ = await sut.mutateTask(taskID: taskID) { task in
            var step = StepExecution(
                id: "eng",
                role: .softwareEngineer,
                title: "Engineer",
                status: .needsSupervisorInput,
                needsSupervisorInput: true,
                supervisorQuestion: "Recovered question after eviction?"
            )
            step.toolCalls = [
                StepToolCall(
                    id: UUID(),
                    createdAt: now,
                    name: ToolNames.askSupervisor,
                    argumentsJSON: #"{"question":"Recovered question after eviction?"}"#,
                    resultJSON: #"{"ok":true}"#
                )
            ]
            task.runs = [Run(
                id: 0,
                steps: [step],
                roleStatuses: ["eng": .working]
            )]
        }

        // Simulate a disk state where the step was still `.running` with `needsSupervisorInput == true`
        // (which raw `repository.loadTask` would leave `.running` and `answerableSupervisorSteps` would drop,
        // whereas `ensureTaskLoadedSync` runs `StatusRecoveryService.recoverStaleStatuses` to `.paused`).
        var staleDiskTask = try XCTUnwrap(sut.loadedTask(taskID))
        staleDiskTask.runs[0].steps[0].status = .running
        try sut.repository.updateTaskOnly(at: tempDir, task: staleDiskTask)

        // Evict the task from in-memory `snapshot.loadedTasks` so `AutovisorEventFeed` must hydrate it.
        sut.snapshot?.loadedTasks.removeValue(forKey: taskID)
        XCTAssertNil(sut.loadedTask(taskID))

        let poll = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursor0,
            timeoutSeconds: 0
        )
        XCTAssertNotNil(sut.loadedTask(taskID), "waitForEvents must hydrate unloaded tasks via ensureTaskLoadedSync")
        let questionEvent = poll.events.first(where: { $0.kind == .question })
        XCTAssertNotNil(questionEvent, "Hydrating via ensureTaskLoadedSync must recover stale .running question step and emit .question")
        XCTAssertEqual(questionEvent?.question, "Recovered question after eviction?")
    }

    // MARK: - 12. Readiness lost in the turn of a candidate's wake (§9)
    //
    // `wakeAllWaiters` empties the registry before it resolves anything, and a waiter a
    // candidate woke stays unregistered until its continuation runs. A folder switch, a lost
    // readiness or the app quitting in that gap wakes nobody, so the waiter can learn of it only
    // by comparing the state it started with against the state after the wake. Each test makes
    // both writes in ONE main-actor stretch, so the waiter cannot resume between them, and waits
    // with a short timeout so that a regression fails in seconds rather than after 30.

    func testDriverSwitchInTheTurnOfACandidateWake_stopsWithDriverChanged() async throws {
        let cursor = try await openFolderWithExternalDriver()
        let wait = await parkedWait(on: sut.autovisorEventFeed, after: cursor, timeoutSeconds: 2)

        recordForeignCandidate()
        await sut.setAutovisorDriver(.builtInModel)

        let result = await wait.value
        XCTAssertEqual(result.stopReason, .driverChanged)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.superseded)
        XCTAssertNil(result.cursorResetReason)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursor, cursor, "a stop hands back the position it scanned, not the head")
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0)
    }

    func testAutovisorDisabledInTheTurnOfACandidateWake_stopsWithNotReady() async throws {
        let cursor = try await openFolderWithExternalDriver(enableAutovisor: true)
        let wait = await parkedWait(on: sut.autovisorEventFeed, after: cursor, timeoutSeconds: 2)

        recordForeignCandidate()
        await sut.setAutovisorEnabled(false)

        let result = await wait.value
        XCTAssertEqual(result.stopReason, .notReady)
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.cursorResetReason)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.cursor, cursor)
    }

    func testFolderSwitchInTheTurnOfACandidateWake_stopsWithFolderChanged() async throws {
        let cursor = try await openFolderWithExternalDriver()
        let otherDir = try makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: otherDir) }
        let wait = await parkedWait(on: sut.autovisorEventFeed, after: cursor, timeoutSeconds: 2)

        recordForeignCandidate()
        await sut.openWorkFolder(otherDir)

        let result = await wait.value
        XCTAssertEqual(result.stopReason, .folderChanged)
        XCTAssertEqual(result.cursorResetReason, .folderChanged)
        XCTAssertNil(result.cursor, "the old folder's cursor names nothing in the new one")
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.events.isEmpty, "the new folder's conditions are not this wait's to report")
    }

    func testShutdownInTheTurnOfACandidateWake_stopsWithShuttingDown() async throws {
        let cursor = try await openFolderWithExternalDriver()
        let wait = await parkedWait(on: sut.autovisorEventFeed, after: cursor, timeoutSeconds: 2)

        recordForeignCandidate()
        await sut.shutdownHostedMCPForTermination()

        let result = await wait.value
        XCTAssertEqual(result.stopReason, .shuttingDown)
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.cursorResetReason)
        XCTAssertEqual(result.cursor, cursor)

        let late = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: cursor,
            timeoutSeconds: 30
        )
        XCTAssertEqual(late.stopReason, .shuttingDown, "a wait begun after the shutdown answers at once")
    }

    func testStopInTheTurnOfAnOwnCandidate_handsBackACursorThatStillDeliversIt() async throws {
        let cursor = try await openFolderWithExternalDriver()
        let wait = await parkedWait(on: sut.autovisorEventFeed, after: cursor, timeoutSeconds: 2)

        sut.autovisorEventFeed.recordDeleted(
            taskID: 4_242,
            origin: .externalAgent(agentA),
            title: "Own task",
            by: .person
        )
        await sut.setAutovisorDriver(.builtInModel)

        let stopped = await wait.value
        XCTAssertEqual(stopped.stopReason, .driverChanged)
        XCTAssertTrue(stopped.events.isEmpty, "a stopped wait delivers nothing")
        XCTAssertEqual(stopped.cursor, cursor)

        let resumed = await poll(after: stopped.cursor)
        XCTAssertEqual(describe(resumed.events), ["deleted#4242"])
        XCTAssertEqual(resumed.events.first?.by, .person)
        XCTAssertEqual(resumed.events.first?.title, "Own task")
        XCTAssertNil(resumed.stopReason)
    }

    func testDriverRewrittenWithoutAWake_isReportedInsteadOfTheTimeout() async throws {
        let cursor = try await openFolderWithExternalDriver()
        let wait = await parkedWait(on: sut.autovisorEventFeed, after: cursor, timeoutSeconds: 0.3)

        // A write the readiness signal is not told of — what a waiter sees when the timer has
        // already resolved its bridge and the switch's wake arrives too late to count.
        await sut.mutateWorkFolder { $0.settings.autovisorDriver = .builtInModel }
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1, "precondition: nothing woke the waiter")

        let result = await wait.value
        XCTAssertEqual(result.stopReason, .driverChanged)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.cursor, cursor)
    }

    // MARK: - 13. Paused identity: (task, run, stamp), and `timed_out` only for the timeout's pause

    func testPersonsPause_isNotRedeliveredByWritesThatLeaveItStanding() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Paused by a person")
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .paused)],
                roleStatuses: ["eng": .working]
            )]
        }

        let first = await poll(after: cursor)
        XCTAssertEqual(describe(first.events), ["paused#\(taskID)(by_person)"])

        // What `manage_role accept` does to a task whose other step stays paused: it stamps the run.
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].updatedAt = MonotonicClock.shared.now() }
        let afterRunWrite = await poll(after: first.cursor)
        XCTAssertEqual(describe(afterRunWrite.events), [], "a run-level write is not a new pause")

        _ = await sut.mutateTask(taskID: taskID) { $0.title = "Renamed while paused" }
        let afterRename = await poll(after: afterRunWrite.cursor)
        XCTAssertEqual(describe(afterRename.events), [], "nor is a write that stamps only the task")
    }

    func testPauseLatchedByRecovery_isReportedAsRecovered_andKeyedByItsNewestPausedStep() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Recovered pause")
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let olderRunStamp = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.status = .paused
            task.runs = [Run(
                id: 1,
                createdAt: olderRunStamp,
                updatedAt: olderRunStamp,
                steps: [StepExecution(
                    id: "eng",
                    role: .softwareEngineer,
                    title: "Engineer",
                    status: .paused,
                    updatedAt: olderRunStamp.addingTimeInterval(500)
                )],
                roleStatuses: ["eng": .working]
            )]
        }

        let first = await poll(after: cursor)
        XCTAssertEqual(describe(first.events), ["paused#\(taskID)(recovered)"])
        XCTAssertEqual(first.events.first?.title, "Recovered pause")

        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].updatedAt = MonotonicClock.shared.now() }
        let afterRunWrite = await poll(after: first.cursor)
        XCTAssertEqual(describe(afterRunWrite.events), [], "the newest paused step keys the pause, not the run")
    }

    func testTimedOutRun_resumedAndPausedAgain_deliversANewPauseByThePerson() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Timed run")
        await giveRunningStep(taskID)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        // A pause and a resume BEFORE the timeout: the timeout's own pause must still read as its.
        await pauseByPerson(taskID)
        let earlyPause = await poll(after: cursor0)
        XCTAssertEqual(describe(earlyPause.events), ["paused#\(taskID)(by_person)"])
        await setStepStatus(taskID, .running)

        await pauseByTimeout(taskID)
        let timeoutPause = await poll(after: earlyPause.cursor)
        XCTAssertEqual(
            describe(timeoutPause.events),
            ["paused#\(taskID)(timed_out)"],
            "the timeout's pause, though its step was written after timedOutAt"
        )

        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].updatedAt = MonotonicClock.shared.now()
            task.runs[0].steps[0].updatedAt = MonotonicClock.shared.now()
        }
        let standing = await poll(after: timeoutPause.cursor)
        XCTAssertEqual(describe(standing.events), [], "writes while the timeout's pause stands are not a new pause")

        // Resumed, then paused by the person: a repeated condition, and not the timeout's.
        await setStepStatus(taskID, .running)
        await pauseByPerson(taskID)
        let repeated = await poll(after: standing.cursor)
        XCTAssertEqual(describe(repeated.events), ["paused#\(taskID)(by_person)"])

        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].updatedAt = MonotonicClock.shared.now() }
        let afterRunWrite = await poll(after: repeated.cursor)
        XCTAssertEqual(describe(afterRunWrite.events), [])

        let snapshot = await poll(after: nil)
        XCTAssertEqual(
            describe(snapshot.events.filter { $0.taskID == taskID }),
            ["paused#\(taskID)(by_person)"],
            "a snapshot reports the pause that stands, by its own reason"
        )
    }

    func testTimedOutPause_isNeitherEndedNorHiddenByAnIndexThatLagsMemory() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Timed run, lagging index")
        await giveRunningStep(taskID)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        await pauseByTimeout(taskID)
        let timeoutPause = await poll(after: cursor0)
        XCTAssertEqual(describe(timeoutPause.events), ["paused#\(taskID)(timed_out)"])

        // The index a disk re-read applies while the pausing write is still in flight (D6): the
        // watchdog's first write — `timedOutAt` set, the row still running — stamped after
        // `timedOutAt` and before the pause.
        let current = try XCTUnwrap(sut.snapshot)
        var lagging = current
        let row = try XCTUnwrap(lagging.tasksIndex.tasks.firstIndex { $0.id == taskID })
        let timedOutAt = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last?.timedOutAt)
        let pausedRowStamp = current.tasksIndex.tasks[row].updatedAt
        lagging.tasksIndex.tasks[row].status = .running
        lagging.tasksIndex.tasks[row].updatedAt = timedOutAt.addingTimeInterval(
            pausedRowStamp.timeIntervalSince(timedOutAt) / 2
        )

        sut.apply(lagging, settings: .adopt)
        sut.apply(current, settings: .adopt)
        let afterFlicker = await poll(after: timeoutPause.cursor)
        XCTAssertEqual(describe(afterFlicker.events), [], "a lagging row does not end the pause")
        let snapshot = await poll(after: nil)
        XCTAssertEqual(describe(snapshot.events.filter { $0.taskID == taskID }), ["paused#\(taskID)(timed_out)"])

        // A lagging row still in the index when the run resumes: the resume's write is compared
        // with it, yet the resume still ends the timeout's pause.
        sut.apply(lagging, settings: .adopt)
        await setStepStatus(taskID, .running)
        await pauseByPerson(taskID)
        let repeated = await poll(after: afterFlicker.cursor)
        XCTAssertEqual(describe(repeated.events), ["paused#\(taskID)(by_person)"])
    }

    func testServerReEnable_keepsWhatTheFeedSawOfTheTimedOutRunsResume() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Timed run across a server re-enable")
        await giveRunningStep(taskID)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        await pauseByTimeout(taskID)
        let timeoutPause = await poll(after: cursor0)
        XCTAssertEqual(describe(timeoutPause.events), ["paused#\(taskID)(timed_out)"])
        await setStepStatus(taskID, .running)

        // A new epoch for the same folder and the same tasks: the resume it saw still counts.
        sut.autovisorEventFeed.bumpEpochForServerEnable()
        await pauseByPerson(taskID)

        let reset = await poll(after: timeoutPause.cursor)
        XCTAssertEqual(reset.cursorResetReason, .restarted)
        XCTAssertEqual(describe(reset.events.filter { $0.taskID == taskID }), ["paused#\(taskID)(by_person)"])
    }

    /// After a relaunch the feed remembers nothing it saw, so the run itself must say whose pause
    /// it stands in. A Pause leaves the role `.working` beside its parked step, so status recovery
    /// on the next load reads the pair as interrupted work and arms the task's `.paused` latch —
    /// over a pause somebody made on purpose.
    ///
    /// RED before 2026-11-07: the feed read that latch before the run's cause, so the person's
    /// (or the agent's own) pause reached the agent as `recovered` after every relaunch. The
    /// relaunch tests of e24d6305 re-armed the feed without a recovery pass and stayed green.
    func testAfterARelaunch_aPauseByThePerson_readsByPerson() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Paused by the person, then relaunched")
        await giveRunningStep(taskID)
        await sut.pauseRun(taskID: taskID)

        await relaunch(evicting: taskID)
        let snapshot = await poll(after: nil)

        XCTAssertEqual(sut.loadedTask(taskID)?.status, .paused, "premise: status recovery armed its latch")
        XCTAssertEqual(describe(snapshot.events.filter { $0.taskID == taskID }), ["paused#\(taskID)(by_person)"])
    }

    /// A timed-out run that was resumed and then paused by the person reads `by_person` after a
    /// relaunch, not `timed_out` and not `recovered`.
    ///
    /// RED before 2026-11-07 twice over: first the feed's in-memory pause history was all that
    /// told the timeout's pause from the person's, then the recovery latch read as `recovered`.
    func testAfterARelaunch_aPauseByThePersonAfterTheTimeout_readsByPerson() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Timed run, paused again, then relaunched")
        await giveRunningStep(taskID)
        await pauseByTimeout(taskID)
        await setStepStatus(taskID, .running)
        await sut.pauseRun(taskID: taskID)

        await relaunch(evicting: taskID)
        let snapshot = await poll(after: nil)

        XCTAssertEqual(sut.loadedTask(taskID)?.status, .paused, "premise: status recovery armed its latch")
        XCTAssertEqual(describe(snapshot.events.filter { $0.taskID == taskID }), ["paused#\(taskID)(by_person)"])
    }

    /// A run the quit interrupted after its timeout was resumed: status recovery parks the running
    /// step on the next load, records that pause as its own, and the agent reads `recovered`.
    ///
    /// RED before 2026-11-07 (the in-memory history): `timed_out`.
    func testAfterARelaunch_aRecoveredPauseAfterTheTimeout_readsRecovered() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Timed run, resumed, interrupted by a quit")
        await giveRunningStep(taskID)
        await pauseByTimeout(taskID)
        await setStepStatus(taskID, .running)

        await relaunch(evicting: taskID)
        let snapshot = await poll(after: nil)

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseCause, .recovered, "premise: recovery parked the running step")
        XCTAssertEqual(describe(snapshot.events.filter { $0.taskID == taskID }), ["paused#\(taskID)(recovered)"])
    }

    /// The timeout's own pause keeps its reason across a relaunch.
    func testAfterARelaunch_theTimeoutsOwnPause_stillReadsTimedOut() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Timed run, relaunched while paused")
        await giveRunningStep(taskID)
        await pauseByTimeout(taskID)

        await relaunch(evicting: taskID)
        let snapshot = await poll(after: nil)

        XCTAssertEqual(sut.loadedTask(taskID)?.status, .paused, "premise: status recovery armed its latch")
        XCTAssertEqual(describe(snapshot.events.filter { $0.taskID == taskID }), ["paused#\(taskID)(timed_out)"])
    }

    /// A second Pause of a timed-out run stops nothing, so it changes nothing the agent reads.
    ///
    /// RED before 2026-11-07: it rewrote the run's cause to the person's, and the agent received
    /// a second `paused` event, `by_person`, for the pause the timeout had made.
    func testASecondPauseOfATimedOutRun_deliversNoNewPausedEvent() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Timed out, then Pause pressed again")
        await giveRunningStep(taskID)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].timedOutAt = MonotonicClock.shared.now() }
        await sut.pauseRun(taskID: taskID, cause: .runTimedOut)
        let timeoutPause = await poll(after: cursor0)
        XCTAssertEqual(describe(timeoutPause.events), ["paused#\(taskID)(timed_out)"])

        await sut.pauseRun(taskID: taskID)

        let afterSecondPause = await poll(after: timeoutPause.cursor)
        XCTAssertEqual(describe(afterSecondPause.events), [])
    }

    // MARK: - 13b. A cursor belongs to its task_ids

    /// A wait with `task_ids` skips the candidates of the agent's other tasks, and the cursor it
    /// returns is past them. RED before 2026-11-07: reusing that cursor without `task_ids` — what
    /// the server instructions tell an agent to do with every cursor — never delivered them, so a
    /// pause, a question or a review of another of its tasks was lost to it (seen on the live
    /// run of that day). The cursor now carries its filter, and a call with other `task_ids`
    /// starts over with a snapshot of what stands.
    func testACursorReturnedWithTaskIDs_startsOverWithASnapshotWhenTheFilterChanges() async throws {
        await sut.openWorkFolder(tempDir)
        let watched = try await createOwnTask("Watched")
        let other = try await createOwnTask("Other")
        await giveRunningStep(watched)
        await giveRunningStep(other)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        await pauseByPerson(other)
        await pauseByPerson(watched)
        let filtered = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id, after: cursor0, taskIDs: [watched], timeoutSeconds: 0)
        XCTAssertEqual(describe(filtered.events), ["paused#\(watched)(by_person)"])

        let unfiltered = await poll(after: filtered.cursor)

        XCTAssertEqual(unfiltered.cursorResetReason, .filterChanged)
        XCTAssertTrue(describe(unfiltered.events).contains("paused#\(other)(by_person)"), "\(describe(unfiltered.events))")
    }

    /// The same `task_ids` resume from their own cursor: no snapshot, nothing repeated.
    func testACursorReturnedWithTaskIDs_resumesWithTheSameTaskIDs() async throws {
        await sut.openWorkFolder(tempDir)
        let watched = try await createOwnTask("Watched")
        await giveRunningStep(watched)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        await pauseByPerson(watched)
        let first = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id, after: cursor0, taskIDs: [watched], timeoutSeconds: 0)
        XCTAssertEqual(describe(first.events), ["paused#\(watched)(by_person)"])

        let again = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id, after: first.cursor, taskIDs: [watched], timeoutSeconds: 0)

        XCTAssertNil(again.cursorResetReason)
        XCTAssertEqual(describe(again.events), [])
    }

    /// Narrowing loses nothing: a cursor without a filter (`folder_status.event_cursor`, any call
    /// without `task_ids`) skipped no task, so a call with `task_ids` resumes from it as is.
    func testAnUnfilteredCursorPassedWithTaskIDs_resumesWithoutASnapshot() async throws {
        await sut.openWorkFolder(tempDir)
        let watched = try await createOwnTask("Watched")
        await giveRunningStep(watched)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        await pauseByPerson(watched)

        let filtered = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id, after: cursor, taskIDs: [watched], timeoutSeconds: 0)

        XCTAssertNil(filtered.cursorResetReason)
        XCTAssertEqual(describe(filtered.events), ["paused#\(watched)(by_person)"])
    }

    /// Between two filters the same rule: a subset of the cursor's tasks resumes, a task the
    /// cursor's call did not watch starts over.
    func testAFilteredCursor_resumesForASubsetOfItsTasks_andStartsOverForATaskItDidNotWatch() async throws {
        await sut.openWorkFolder(tempDir)
        let first = try await createOwnTask("First")
        let second = try await createOwnTask("Second")
        await giveRunningStep(first)
        await giveRunningStep(second)
        let cursor0 = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let both = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id, after: cursor0, taskIDs: [first, second], timeoutSeconds: 0)

        let narrowed = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id, after: both.cursor, taskIDs: [first], timeoutSeconds: 0)
        XCTAssertNil(narrowed.cursorResetReason)

        let widened = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id, after: narrowed.cursor, taskIDs: [first, second], timeoutSeconds: 0)
        XCTAssertEqual(widened.cursorResetReason, .filterChanged)
    }

    /// A cursor without a filter keeps its three-part form; a filtered one names its task ids in
    /// ascending order; a malformed filter part is no cursor at all. The epoch is a token read
    /// whole — a bare counter from an earlier build parses, and is simply not this epoch.
    func testCursorFormat_carriesItsTaskIDs() throws {
        let folder = UUID()
        let plain = AutovisorEventFeed.formatCursor(folderID: folder, epoch: "ab12cd34.3", seq: 7)
        XCTAssertEqual(plain, "\(folder.uuidString):ab12cd34.3:7")
        let parsedPlain = try XCTUnwrap(AutovisorEventFeed.parseCursor(plain))
        XCTAssertNil(parsedPlain.taskIDs)
        XCTAssertEqual(parsedPlain.epoch, "ab12cd34.3")

        let filtered = AutovisorEventFeed.formatCursor(folderID: folder, epoch: "ab12cd34.3", seq: 7, taskIDs: [12, 0, 5])
        XCTAssertEqual(filtered, "\(folder.uuidString):ab12cd34.3:7:0,5,12")
        let parsed = try XCTUnwrap(AutovisorEventFeed.parseCursor(filtered))
        XCTAssertEqual(parsed.seq, 7)
        XCTAssertEqual(parsed.taskIDs, [0, 5, 12])

        let none = AutovisorEventFeed.formatCursor(folderID: folder, epoch: "ab12cd34.3", seq: 7, taskIDs: [])
        XCTAssertEqual(none, "\(folder.uuidString):ab12cd34.3:7:")
        XCTAssertEqual(try XCTUnwrap(AutovisorEventFeed.parseCursor(none)).taskIDs, [])

        XCTAssertEqual(try XCTUnwrap(AutovisorEventFeed.parseCursor("\(folder.uuidString):3:7")).epoch, "3")
        XCTAssertNil(AutovisorEventFeed.parseCursor("\(folder.uuidString)::7"), "no epoch, no cursor")
        XCTAssertNil(AutovisorEventFeed.parseCursor("\(folder.uuidString):3:-7"))
        XCTAssertNil(AutovisorEventFeed.parseCursor("\(folder.uuidString):3:7:x"))
        XCTAssertNil(AutovisorEventFeed.parseCursor("\(folder.uuidString):3:7:-1"))
        XCTAssertNil(AutovisorEventFeed.parseCursor("\(folder.uuidString):3:7:1:2"))
    }

    // MARK: - 14. The delivered-identity cap

    func testDeliveredIdentityCap_evictsTheOldestIdentity_alsoAfterASnapshotReset() async throws {
        await sut.openWorkFolder(tempDir)
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id)
        customFeed = AutovisorEventFeed(ringCapacity: 16, deliveredIdentityCap: 1)
        customFeed.store = sut
        customFeed.activateFolder(folderID: folderID)

        // The snapshot resets the agent's delivered set first; the reset must keep the cap.
        let snapshot = await customFeed.waitForEvents(agentID: agentA.id, after: nil, timeoutSeconds: 0)
        XCTAssertEqual(describe(snapshot.events), [])

        customFeed.recordDeleted(taskID: 701, origin: .externalAgent(agentA), title: "First", by: .person)
        customFeed.recordDeleted(taskID: 702, origin: .externalAgent(agentA), title: "Second", by: .person)
        let both = await customFeed.waitForEvents(agentID: agentA.id, after: snapshot.cursor, timeoutSeconds: 0)
        XCTAssertEqual(describe(both.events), ["deleted#701", "deleted#702"])

        // With room for one identity, remembering 702 evicted 701: 701 reads as new again.
        customFeed.recordDeleted(taskID: 701, origin: .externalAgent(agentA), title: "First", by: .person)
        let again = await customFeed.waitForEvents(agentID: agentA.id, after: both.cursor, timeoutSeconds: 0)
        XCTAssertEqual(describe(again.events), ["deleted#701"])

        // The default cap remembers both, so the same replay delivers nothing.
        let defaultCursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        sut.autovisorEventFeed.recordDeleted(taskID: 701, origin: .externalAgent(agentA), title: "First", by: .person)
        sut.autovisorEventFeed.recordDeleted(taskID: 702, origin: .externalAgent(agentA), title: "Second", by: .person)
        sut.autovisorEventFeed.recordDeleted(taskID: 701, origin: .externalAgent(agentA), title: "First", by: .person)
        let defaultFeed = await poll(after: defaultCursor)
        XCTAssertEqual(describe(defaultFeed.events), ["deleted#701", "deleted#702"])
    }

    // MARK: - 15. Cursor resets, cancellation and repeated candidates

    func testMalformedCursor_resetsWithRestartedAndASnapshotOfStandingConditions() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Failed task")
        let errorNote = "\(StepExecution.llmErrorNotePrefix): Compiler error"
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "eng",
                    role: .softwareEngineer,
                    title: "Engineer",
                    status: .failed,
                    messages: [StepMessage(role: .softwareEngineer, content: errorNote)]
                )],
                roleStatuses: ["eng": .failed]
            )]
        }

        let result = await sut.autovisorEventFeed.waitForEvents(
            agentID: agentA.id,
            after: "not-a-valid-cursor",
            timeoutSeconds: 30
        )
        XCTAssertEqual(result.cursorResetReason, .restarted)
        XCTAssertEqual(describe(result.events), ["failed#\(taskID)@eng"])
        XCTAssertEqual(result.events.first?.errorMessage, errorNote)
        XCTAssertEqual(result.cursor, sut.autovisorEventFeed.currentCursor)
        XCTAssertFalse(result.timedOut, "a reset answers at once, whatever the timeout")
        XCTAssertNil(result.stopReason)
    }

    func testRingOverflowWhileParked_resetsWithGapAndASnapshot() async throws {
        await sut.openWorkFolder(tempDir)
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id)
        let ownTaskID = try await createOwnTask("Failed before the overflow")
        _ = await sut.mutateTask(taskID: ownTaskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .failed)],
                roleStatuses: ["eng": .failed]
            )]
        }
        customFeed = AutovisorEventFeed(ringCapacity: 16)
        customFeed.store = sut
        customFeed.activateFolder(folderID: folderID)
        let cursor = try XCTUnwrap(customFeed.currentCursor)
        let wait = await parkedWait(on: customFeed, after: cursor, timeoutSeconds: 5)

        for i in 1...18 {
            customFeed.recordDeleted(taskID: 900 + i, origin: .externalAgent(agentB), title: "B\(i)", by: .person)
        }

        let result = await wait.value
        XCTAssertEqual(result.cursorResetReason, .gap)
        XCTAssertEqual(result.cursor, customFeed.currentCursor)
        XCTAssertEqual(describe(result.events), ["failed#\(ownTaskID)@eng"], "the snapshot of what stands")
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.stopReason)
    }

    func testCancelWaiters_endsOnlyThatAgentsWaits() async throws {
        await sut.openWorkFolder(tempDir)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let waitA = await parkedWait(on: sut.autovisorEventFeed, after: cursor, timeoutSeconds: 30)
        let waitB = await parkedWait(on: sut.autovisorEventFeed, agentID: agentB.id, after: cursor, timeoutSeconds: 30)

        sut.autovisorEventFeed.cancelWaiters(forAgentID: agentA.id)

        let resultA = await waitA.value
        XCTAssertFalse(resultA.timedOut)
        XCTAssertNil(resultA.stopReason)
        XCTAssertTrue(resultA.events.isEmpty)
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress(forAgentID: agentA.id))
        XCTAssertTrue(sut.autovisorEventFeed.hasWaitInProgress(forAgentID: agentB.id), "agent B's wait is not A's")
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 1)

        waitB.cancel()
        _ = await waitB.value
        XCTAssertEqual(sut.autovisorEventFeed.waiterCount, 0)
    }

    func testRepeatedDeletedCandidates_areDeliveredOnce() async throws {
        await sut.openWorkFolder(tempDir)
        let liveTaskID = try await createOwnTask("Still here")
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let feed: AutovisorEventFeed = sut.autovisorEventFeed

        feed.recordDeleted(taskID: 99_999, origin: .externalAgent(agentA), title: "Gone", by: .person)
        feed.recordDeleted(taskID: 99_999, origin: .externalAgent(agentA), title: "Gone", by: .person)
        // A deletion whose task is still in the index is stale; another agent's is not A's.
        feed.recordDeleted(taskID: liveTaskID, origin: .externalAgent(agentA), title: "Still here", by: .person)
        feed.recordDeleted(taskID: 99_998, origin: .externalAgent(agentB), title: "Agent B's", by: .person)

        let result = await poll(after: cursor)
        XCTAssertEqual(describe(result.events), ["deleted#99999"])
        XCTAssertEqual(result.events.last?.title, "Gone")
    }

    // MARK: - 16. Gates, review and failure

    func testSnapshot_reportsAcceptanceGateAndStuckEpisode() async throws {
        await sut.openWorkFolder(tempDir)
        let gateTaskID = try await createOwnTask("At the gate")
        _ = await sut.mutateTask(taskID: gateTaskID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "architect",
                    role: .techLead,
                    title: "Architect",
                    status: .done,
                    completedAt: Date(timeIntervalSince1970: 1_700_006_800)
                )],
                roleStatuses: ["architect": .needsAcceptance, "engineer": .idle]
            )]
        }
        let stuckTaskID = try await createOwnTask("Stuck")
        await giveRunningStep(stuckTaskID)
        sut.autovisorEventFeed.recordStuckTasks([stuckTaskID], now: Date(timeIntervalSince1970: 1_700_256_800))

        // The row levels the snapshot reads: on the gate's row, the gate is the only one that holds.
        let gateRow = try XCTUnwrap(sut.snapshot?.tasksIndex.tasks.first { $0.id == gateTaskID })
        XCTAssertTrue(NTMSOrchestrator.AutovisorAttentionTrigger.acceptanceGate.levelHolds(for: gateRow))
        let otherTriggers: [NTMSOrchestrator.AutovisorAttentionTrigger] = [
            .completed, .failed, .needsSupervisor, .created, .stuck,
        ]
        for trigger in otherTriggers {
            XCTAssertFalse(trigger.levelHolds(for: gateRow), "\(trigger)")
        }

        let snapshot = await poll(after: nil)
        XCTAssertNil(snapshot.cursorResetReason)
        XCTAssertEqual(
            describe(snapshot.events.filter { $0.taskID == gateTaskID }),
            ["acceptance_gate#\(gateTaskID)@architect"]
        )
        XCTAssertEqual(describe(snapshot.events.filter { $0.taskID == stuckTaskID }), ["stuck#\(stuckTaskID)"])
    }

    func testGateRowRewrite_isNotANewGate_andReviewAndFailureArriveWithTheirPayloads() async throws {
        await sut.openWorkFolder(tempDir)
        let pipelineID = try await createOwnTask("Pipeline")
        let failingID = try await createOwnTask("Failing")
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        _ = await sut.mutateTask(taskID: pipelineID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "architect",
                    role: .techLead,
                    title: "Architect",
                    status: .done,
                    completedAt: Date(timeIntervalSince1970: 1_700_016_800)
                )],
                roleStatuses: ["architect": .needsAcceptance, "engineer": .idle]
            )]
        }
        let gate = await poll(after: cursor)
        XCTAssertEqual(describe(gate.events), ["acceptance_gate#\(pipelineID)@architect"])

        _ = await sut.mutateTask(taskID: pipelineID) { $0.title = "Pipeline (renamed at the gate)" }
        let rewrite = await poll(after: gate.cursor)
        XCTAssertEqual(describe(rewrite.events), [], "the same gate, rewritten, is not a new gate")

        let errorNote = "\(StepExecution.llmErrorNotePrefix): Build failed"
        _ = await sut.mutateTask(taskID: pipelineID) { task in
            task.runs[0].roleStatuses = ["architect": .done, "engineer": .done]
            task.runs[0].steps = [
                StepExecution(id: "architect", role: .techLead, title: "Architect", status: .done, completedAt: Date()),
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Engineer", status: .done, completedAt: Date()),
            ]
        }
        _ = await sut.mutateTask(taskID: failingID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "eng",
                    role: .softwareEngineer,
                    title: "Engineer",
                    status: .failed,
                    messages: [StepMessage(role: .softwareEngineer, content: errorNote)]
                )],
                roleStatuses: ["eng": .failed]
            )]
        }
        let settled = await poll(after: rewrite.cursor)
        XCTAssertEqual(describe(settled.events), ["review#\(pipelineID)", "failed#\(failingID)@eng"])
        XCTAssertEqual(settled.events.first?.title, "Pipeline (renamed at the gate)")
        XCTAssertEqual(settled.events.last?.errorMessage, errorNote)
    }

    // MARK: - 17. A feed that cannot wait answers at once

    func testWaitOnAnUnarmedDisarmedOrShutDownFeed_answersAtOnce() async throws {
        await sut.openWorkFolder(tempDir)
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id)
        customFeed = AutovisorEventFeed()
        customFeed.store = sut

        let unarmed = await customFeed.waitForEvents(agentID: agentA.id, after: nil, timeoutSeconds: 30)
        XCTAssertEqual(unarmed.stopReason, .notReady)
        XCTAssertNil(unarmed.cursor)

        customFeed.activateFolder(folderID: folderID)
        customFeed.disarmForFolderTransition()
        let disarmed = await customFeed.waitForEvents(agentID: agentA.id, after: nil, timeoutSeconds: 30)
        XCTAssertEqual(disarmed.stopReason, .notReady)
        XCTAssertNil(disarmed.cursor)

        customFeed.handleReadinessWake(.shuttingDown)
        let shutDown = await customFeed.waitForEvents(agentID: agentA.id, after: nil, timeoutSeconds: 30)
        XCTAssertEqual(shutDown.stopReason, .shuttingDown)
        XCTAssertFalse(shutDown.timedOut)
    }

    // MARK: - Helpers

    /// Opens the work folder with the external driver selected and returns the head cursor.
    private func openFolderWithExternalDriver(enableAutovisor: Bool = false) async throws -> String {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        if enableAutovisor {
            let enabled = await sut.setAutovisorEnabled(true)
            XCTAssertTrue(enabled)
        }
        return try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
    }

    /// Starts `waitForEvents` and returns once its bridge is registered, so what the test does
    /// next happens to a parked waiter. Yields rather than sleeps: the waiter and the test share
    /// the main actor, and a yield is what lets the waiter run up to its suspension.
    private func parkedWait(
        on feed: AutovisorEventFeed,
        agentID: UUID? = nil,
        after cursor: String?,
        timeoutSeconds: TimeInterval
    ) async -> Task<AutovisorWaitResult, Never> {
        let waitingAgent = agentID ?? agentA.id
        let before = feed.waiterCount
        let wait = Task { @MainActor in
            await feed.waitForEvents(agentID: waitingAgent, after: cursor, timeoutSeconds: timeoutSeconds)
        }
        var spins = 0
        while feed.waiterCount == before, spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(feed.waiterCount, before + 1, "the wait never parked")
        return wait
    }

    /// A candidate agent A has no stake in, so its wake delivers nothing and the waiter would
    /// otherwise register a fresh bridge and keep waiting.
    private func recordForeignCandidate() {
        sut.autovisorEventFeed.recordDeleted(
            taskID: 424_242,
            origin: .externalAgent(agentB),
            title: "Agent B's task",
            by: .person
        )
    }

    /// A second work folder to switch to; the caller removes it.
    private func makeScratchFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTMSFeedSwitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func poll(after cursor: String?) async -> AutovisorWaitResult {
        await sut.autovisorEventFeed.waitForEvents(agentID: agentA.id, after: cursor, timeoutSeconds: 0)
    }

    private func createOwnTask(_ title: String) async throws -> Int {
        let created = await sut.createTask(
            title: title,
            supervisorTask: "Brief",
            makeActive: false,
            origin: .externalAgent(agentA)
        )
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        return taskID
    }

    private func giveRunningStep(_ taskID: Int) async {
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working]
            )]
        }
    }

    private func setStepStatus(_ taskID: Int, _ status: StepStatus) async {
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].steps[0].status = status }
    }

    /// The run-timeout watchdog's writes in its order: `timedOutAt` with the run stamp, then
    /// `pauseRun(cause: .runTimedOut)` — the cause first, then the pause. The step is written once
    /// more after `timedOutAt`, as the streaming cancel arm does when the pause cancels a step
    /// mid-stream and it commits the partial content.
    private func pauseByTimeout(_ taskID: Int) async {
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].timedOutAt = MonotonicClock.shared.now()
            task.runs[0].updatedAt = MonotonicClock.shared.now()
        }
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].pauseCause = .runTimedOut }
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].updatedAt = MonotonicClock.shared.now()
            task.runs[0].steps[0].status = .paused
        }
    }

    /// What `pauseRun` writes for a person's (or an agent's) Pause: the cause, then the paused step.
    private func pauseByPerson(_ taskID: Int) async {
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].pauseCause = .requested }
        await setStepStatus(taskID, .paused)
    }

    // MARK: - Wave W8.2: Soft Role Completion Event Seam

    func testSoftRoleCompletion_emitsAcceptanceGate_andSuppressesPausedEvent() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = try await createOwnTask("Soft Gate Task")
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "architect",
                    role: .techLead,
                    title: "Architect",
                    status: .needsApproval
                )],
                roleStatuses: ["architect": .needsAcceptance]
            )]
        }
        let snapshot = await poll(after: nil)
        let taskEvents = snapshot.events.filter { $0.taskID == taskID }
        XCTAssertTrue(taskEvents.contains(where: { $0.kind == .acceptanceGate }), "Must emit acceptance_gate")
        XCTAssertFalse(taskEvents.contains(where: { $0.kind == .paused }), "Must NOT emit paused event for soft role completion")
    }

    /// A relaunch as the app performs one. A new process holds no task in memory, so the first
    /// read of each one is a cold load from disk, and a cold load runs status recovery — the pass
    /// whose latch the feed misread. An in-process reopen of the same folder keeps `loadedTasks`
    /// and recovers only the rows still marked active, so the tasks are evicted first; the reopen
    /// then re-arms the feed with nothing it saw before. Re-arming the feed alone, as e24d6305's
    /// relaunch tests did, skipped the recovery pass and passed over that defect.
    private func relaunch(evicting taskIDs: Int...) async {
        for taskID in taskIDs { sut.evictLoadedTask(taskID) }
        await sut.openWorkFolder(tempDir)
    }

    /// `kind#task`, then `(pause reason)` and `@role` when present — enough to tell any two
    /// events of these tests apart in one comparison.
    private func describe(_ events: [AutovisorEvent]) -> [String] {
        events.map { event in
            var text = "\(event.kind.rawValue)#\(event.taskID)"
            if let reason = event.pauseReason { text += "(\(reason.rawValue))" }
            if let roleID = event.roleID { text += "@\(roleID)" }
            return text
        }
    }
}

