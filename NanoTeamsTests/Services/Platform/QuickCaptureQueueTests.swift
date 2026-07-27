import XCTest

@testable import NanoTeams

/// Tests for the per-task chat-message queue: FIFO storage, id-based + index-based
/// removal, target-role matching, terminal-state discard with user feedback, and the
/// `MainLayoutView` onChange handlers now living on `QuickCaptureController`.
@MainActor
final class QuickCaptureQueueTests: XCTestCase {

    var sut: QuickCaptureFormState!

    override func setUp() {
        super.setUp()
        sut = QuickCaptureFormState()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Force-unwrap helper — the failable init only fails on empty payload, which
    /// these tests never produce.
    private func msg(
        _ text: String,
        target: String? = nil,
        id: UUID = UUID()
    ) -> QuickCaptureFormState.QueuedChatMessage {
        QuickCaptureFormState.QueuedChatMessage(
            text: text, attachments: [], clippedTexts: [],
            targetRoleID: target, id: id
        )!
    }

    // MARK: - QueuedChatMessage — invariant enforcement (failable init)

    func testQueuedChatMessage_init_rejectsEmptyTextNoAttachmentsNoClips() {
        XCTAssertNil(QuickCaptureFormState.QueuedChatMessage(
            text: "", attachments: [], clippedTexts: []
        ))
        XCTAssertNil(QuickCaptureFormState.QueuedChatMessage(
            text: "   \n\t", attachments: [], clippedTexts: []
        ), "Whitespace-only text with no other payload must be rejected")
    }

    func testQueuedChatMessage_init_acceptsTextOnly() {
        XCTAssertNotNil(QuickCaptureFormState.QueuedChatMessage(
            text: "hello", attachments: [], clippedTexts: []
        ))
    }

    func testQueuedChatMessage_init_acceptsClipsOnly() {
        XCTAssertNotNil(QuickCaptureFormState.QueuedChatMessage(
            text: "", attachments: [], clippedTexts: ["pasted snippet"]
        ))
    }

    func testQueuedChatMessage_init_preservesOriginalWhitespace() {
        // Trimming is only for the emptiness check — the text itself is preserved
        // (leading/trailing whitespace matters in LLM prompts).
        let m = QuickCaptureFormState.QueuedChatMessage(
            text: "  padded  ", attachments: [], clippedTexts: []
        )
        XCTAssertEqual(m?.text, "  padded  ")
    }

    func testQueuedChatMessage_id_uniquePerInstance() {
        let a = msg("same text")
        let b = msg("same text")
        XCTAssertNotEqual(a.id, b.id, "Each instance must have a distinct UUID")
        XCTAssertNotEqual(a, b,
                          "Structural equality includes id — two equal-content messages with different ids are NOT equal")
    }

    func testQueuedChatMessage_equalityFollowsAllFields() {
        // `MonotonicClock.now()` returns a strictly increasing Date, so equal-content
        // messages get different `createdAt` by default — pin it explicitly for this
        // assertion to isolate the structural-equality contract.
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 12345)
        let a = QuickCaptureFormState.QueuedChatMessage(
            text: "same", attachments: [], clippedTexts: [],
            id: id, createdAt: createdAt
        )!
        let b = QuickCaptureFormState.QueuedChatMessage(
            text: "same", attachments: [], clippedTexts: [],
            id: id, createdAt: createdAt
        )!
        XCTAssertEqual(a, b, "Same id + same content + same createdAt → equal")
    }

    // MARK: - Multi-message FIFO storage

    func testAppend_storesInFIFOOrder() {
        sut.appendQueuedMessage(msg("first"), for: 1)
        sut.appendQueuedMessage(msg("second"), for: 1)
        sut.appendQueuedMessage(msg("third"), for: 1)

        XCTAssertEqual(sut.queuedMessages(for: 1).map(\.text), ["first", "second", "third"])
        XCTAssertTrue(sut.hasQueuedMessage(for: 1))
    }

    func testAppend_differentTaskIDsIsolated() {
        sut.appendQueuedMessage(msg("A"), for: 1)
        sut.appendQueuedMessage(msg("B"), for: 2)

        XCTAssertEqual(sut.queuedMessages(for: 1).map(\.text), ["A"])
        XCTAssertEqual(sut.queuedMessages(for: 2).map(\.text), ["B"])
        XCTAssertEqual(Set(sut.taskIDsWithQueuedMessages), [1, 2])
    }

    func testPopFirst_matchingTargetRole() {
        sut.appendQueuedMessage(msg("for PM", target: "pm-id"), for: 1)
        sut.appendQueuedMessage(msg("for anyone"), for: 1)
        sut.appendQueuedMessage(msg("for TL", target: "tl-id"), for: 1)

        let popped = sut.popFirstQueuedMessage(for: 1) { $0.targetRoleID == "tl-id" }

        XCTAssertEqual(popped?.text, "for TL")
        XCTAssertEqual(sut.queuedMessages(for: 1).map(\.text), ["for PM", "for anyone"],
                       "Only the TL-targeted message should be popped; others remain in order")
    }

    func testPopFirst_returnsNilWhenNoMatch() {
        sut.appendQueuedMessage(msg("for PM", target: "pm-id"), for: 1)
        let popped = sut.popFirstQueuedMessage(for: 1) { $0.targetRoleID == "missing" }
        XCTAssertNil(popped)
        XCTAssertEqual(sut.queuedMessages(for: 1).count, 1, "Queue unchanged on no-match")
    }

    func testPopFirst_matchesByStableID() {
        let a = msg("a")
        let b = msg("b")
        let c = msg("c")
        sut.appendQueuedMessage(a, for: 1)
        sut.appendQueuedMessage(b, for: 1)
        sut.appendQueuedMessage(c, for: 1)

        let popped = sut.popFirstQueuedMessage(for: 1) { $0.id == b.id }

        XCTAssertEqual(popped?.text, "b")
        XCTAssertEqual(sut.queuedMessages(for: 1).map(\.text), ["a", "c"])
    }

    func testRemoveAt_removesSingleMessage() {
        sut.appendQueuedMessage(msg("a"), for: 1)
        sut.appendQueuedMessage(msg("b"), for: 1)
        sut.appendQueuedMessage(msg("c"), for: 1)

        sut.removeQueuedMessage(at: 1, for: 1)

        XCTAssertEqual(sut.queuedMessages(for: 1).map(\.text), ["a", "c"])
    }

    func testRemoveAt_outOfBoundsIsNoOp() {
        sut.appendQueuedMessage(msg("a"), for: 1)
        sut.removeQueuedMessage(at: 99, for: 1)
        XCTAssertEqual(sut.queuedMessages(for: 1).count, 1)
    }

    func testRemoveAt_lastMessageClearsTaskEntry() {
        sut.appendQueuedMessage(msg("only"), for: 1)
        sut.removeQueuedMessage(at: 0, for: 1)
        XCTAssertFalse(sut.hasQueuedMessage(for: 1))
        XCTAssertTrue(sut.taskIDsWithQueuedMessages.isEmpty)
    }

    // MARK: - prependQueuedMessages (requeue-on-failure head-of-queue)

    /// Pinning the core invariant for `NTMSOrchestrator+QueuedMessages.requeueAll`:
    /// when a popped batch fails to deliver, it must restore to the HEAD of the
    /// queue — not append to the tail — so any messages queued by the user during
    /// the intervening `await` stay behind the batch, preserving FIFO intent.

    func testPrepend_insertsAtHead_preservingBatchOrder() {
        // Simulate an arrival-during-await: a message (`newcomer`) has been queued
        // while `consumeQueuedSupervisorMessage` was awaiting persistence. The
        // consumer then fails and re-inserts the popped batch via prepend.
        let newcomer = msg("arrived during await")
        sut.appendQueuedMessage(newcomer, for: 1)

        let batchA = msg("batch A")
        let batchB = msg("batch B")
        sut.prependQueuedMessages([batchA, batchB], for: 1)

        let result = sut.queuedMessages(for: 1).map(\.text)
        XCTAssertEqual(result, ["batch A", "batch B", "arrived during await"],
                       "Prepend must put the batch at HEAD, preserving internal order, with the newcomer pushed behind")
    }

    func testPrepend_emptyQueue_createsEntry() {
        sut.prependQueuedMessages([msg("solo")], for: 5)
        XCTAssertEqual(sut.queuedMessages(for: 5).map(\.text), ["solo"])
    }

    func testPrepend_emptyArray_isNoOp() {
        sut.appendQueuedMessage(msg("existing"), for: 7)
        sut.prependQueuedMessages([], for: 7)
        XCTAssertEqual(sut.queuedMessages(for: 7).count, 1)
        // Also no-op on a nonexistent task id — must not create an empty entry.
        sut.prependQueuedMessages([], for: 999)
        XCTAssertFalse(sut.hasQueuedMessage(for: 999))
    }

    // MARK: - ID-based removal (new API used by the composer's X button)

    func testRemoveByID_removesTheTargetedMessage() {
        let a = msg("a")
        let b = msg("b")
        let c = msg("c")
        sut.appendQueuedMessage(a, for: 1)
        sut.appendQueuedMessage(b, for: 1)
        sut.appendQueuedMessage(c, for: 1)

        sut.removeQueuedMessage(withID: b.id, for: 1)

        XCTAssertEqual(sut.queuedMessages(for: 1).map(\.text), ["a", "c"])
    }

    func testRemoveByID_unknownIDIsNoOp() {
        sut.appendQueuedMessage(msg("only"), for: 1)
        sut.removeQueuedMessage(withID: UUID(), for: 1)
        XCTAssertEqual(sut.queuedMessages(for: 1).count, 1,
                       "Unknown id must not mutate the queue")
    }

    func testRemoveByID_lastMessageClearsTaskEntry() {
        let a = msg("only")
        sut.appendQueuedMessage(a, for: 1)
        sut.removeQueuedMessage(withID: a.id, for: 1)
        XCTAssertTrue(sut.taskIDsWithQueuedMessages.isEmpty,
                      "Empty queue must drop the task key so `taskIDsWithQueuedMessages` doesn't leak it")
    }

    func testClearQueuedMessages_wipesTaskQueue() {
        sut.appendQueuedMessage(msg("a"), for: 1)
        sut.appendQueuedMessage(msg("b"), for: 1)
        sut.appendQueuedMessage(msg("kept"), for: 2)

        sut.clearQueuedMessages(for: 1)

        XCTAssertFalse(sut.hasQueuedMessage(for: 1))
        XCTAssertTrue(sut.hasQueuedMessage(for: 2), "Sibling task untouched")
    }

    // MARK: - Controller contract

    func testController_queueChatMessage_appendsInOrder() {
        let controller = QuickCaptureController(formState: sut)
        XCTAssertTrue(controller.queueChatMessage(
            text: "one", attachments: [], clippedTexts: [], taskID: 1
        ))
        XCTAssertTrue(controller.queueChatMessage(
            text: "two", attachments: [], clippedTexts: [], taskID: 1, targetRoleID: "pm"
        ))

        XCTAssertEqual(sut.queuedMessages(for: 1).count, 2)
        XCTAssertEqual(sut.queuedMessages(for: 1)[1].targetRoleID, "pm")
    }

    func testController_queueChatMessage_rejectsAllEmpty() {
        let controller = QuickCaptureController(formState: sut)
        XCTAssertFalse(controller.queueChatMessage(
            text: "   ", attachments: [], clippedTexts: [], taskID: 1
        ))
        XCTAssertFalse(sut.hasQueuedMessage(for: 1))
    }

    func testController_discardQueuedChatMessage_wipesEntireQueue() {
        let controller = QuickCaptureController(formState: sut)
        sut.appendQueuedMessage(msg("a"), for: 42)
        sut.appendQueuedMessage(msg("b"), for: 42)

        controller.discardQueuedChatMessage(taskID: 42)

        XCTAssertFalse(sut.hasQueuedMessage(for: 42))
    }

    // MARK: - Terminal-state cleanup + user feedback

    func testTryFlush_dropsAllQueuedOnDone_andSurfacesInfoMessage() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        sut.appendQueuedMessage(msg("a"), for: 1)
        sut.appendQueuedMessage(msg("b"), for: 1)
        store.engineState[1] = .done

        controller.tryFlushQueuedMessages()

        XCTAssertFalse(sut.hasQueuedMessage(for: 1))
        XCTAssertEqual(store.lastInfoMessage,
                       "2 queued message(s) discarded — task completed.",
                       "Terminal-state discard must surface a user-visible info message")
    }

    /// A `.failed` task must NOT discard the queue — sending a message resumes/retries
    /// the run (`resumeRun` revives the failed step). Mirrors the `.paused` wake path:
    /// dispatch `resumeRun`, preserve the queue (primary path drains it on the retried
    /// step's next iteration), no discard banner.
    func testTryFlush_failedEngineWithQueue_callsResumeRunAndPreservesQueue() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("a"), for: 7)
        store.engineState[7] = .failed

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [7],
                       ".failed with queued messages must wake the run via resumeRun, not discard")
        XCTAssertTrue(sut.hasQueuedMessage(for: 7),
                      "Queue must survive — the revived step drains it on its next iteration")
        XCTAssertNil(store.lastInfoMessage,
                     "No discard message — a failed task is retried, not stranded")
    }

    /// A closed task must NOT be resumed even when its engine is `.failed` — the
    /// `closedAt` guard in `wakeRunForQueuedMessages` discards the queue first. Sibling of
    /// `testTryFlush_pausedEngine_butTaskClosed_*`, for the `.failed` route.
    func testTryFlush_failedEngine_butTaskClosed_dropsQueueAndDoesNotResume() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "t", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        await store.mutateTask(taskID: taskID) { task in task.closedAt = Date() }

        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("late"), for: taskID)
        store.engineState[taskID] = .failed

        controller.tryFlushQueuedMessages()

        XCTAssertTrue(resumed.isEmpty,
                      "A closed task must NOT be resumed even when its engine is .failed")
        XCTAssertFalse(sut.hasQueuedMessage(for: taskID),
                       "Queue is discarded for a closed task")
        XCTAssertNotNil(store.lastInfoMessage,
                        "User is told the queued messages were discarded")
    }

    /// Per-task isolation across terminal states in one pass: a `.failed` task resumes
    /// (queue preserved) while a `.done` task discards — independently.
    func testTryFlush_twoTasks_failedResumesAndDoneDiscards() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("a"), for: 1)
        store.engineState[1] = .failed
        sut.appendQueuedMessage(msg("b"), for: 2)
        store.engineState[2] = .done

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [1], "Only the .failed task is resumed")
        XCTAssertTrue(sut.hasQueuedMessage(for: 1), "Failed task's queue preserved for the revived step")
        XCTAssertFalse(sut.hasQueuedMessage(for: 2), "Done task's queue is discarded")
        XCTAssertEqual(store.lastInfoMessage, "1 queued message(s) discarded — task completed.")
    }

    /// `.failed` uses the same in-flight dedup guard as `.paused`: two synchronous ticks
    /// collapse to one resumeRun while the first is in flight.
    func testTryFlush_failedEngine_inFlightGuard_dedupesResume() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("a"), for: 1)
        sut.appendQueuedMessage(msg("b"), for: 1)
        store.engineState[1] = .failed

        controller.tryFlushQueuedMessages()
        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [1],
                       "Two synchronous .failed tryFlush ticks must collapse to one resumeRun")
    }

    /// The user's actual recovery path: sending a message to a `.failed` task immediately
    /// wakes the run (queueChatMessage → tryFlush → resume), message stays queued.
    func testQueueChatMessage_failedEngine_immediatelyTriggersResume() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        store.engineState[1] = .failed

        _ = controller.queueChatMessage(
            text: "retry please", attachments: [], clippedTexts: [], taskID: 1
        )

        XCTAssertEqual(resumed, [1],
                       "Sending a message to a .failed task immediately wakes the run")
        XCTAssertTrue(sut.hasQueuedMessage(for: 1),
                      "Message stays queued for the revived step to consume")
    }

    // MARK: - .done CHAT task — wake with a fresh startRun, never discard

    /// A chat-mode task at `.done` is an ended turn, not a finished pipeline
    /// (`noteNonProductiveTurn` lands chat advisory steps there) — a queued
    /// message must START a fresh run (drained on iteration 1), not be discarded
    /// (the pre-fix bug: the Autovisor chat silently destroyed messages) and not
    /// `resumeRun` (which re-enters the all-terminal run and bounces back to `.done`).
    func testTryFlush_doneChatTask_startsRunAndPreservesQueue() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        var resumed: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: taskID)
        store.engineState[taskID] = .done

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(started, [taskID],
                       ".done chat task must wake via a fresh startRun")
        XCTAssertTrue(resumed.isEmpty,
                      "resumeRun would re-enter the all-terminal run — never used here")
        XCTAssertTrue(sut.hasQueuedMessage(for: taskID),
                      "Queue must survive — the fresh run drains it on iteration 1")
        XCTAssertNil(store.lastInfoMessage, "No discard banner — the message is delivered")
    }

    /// Chat-mode detection must survive the task being unloaded (background task
    /// evicted from `loadedTasks`): the `TaskSummary.isChatMode` fallback in
    /// `isChatModeTask` still routes `.done` to the wake, not the discard.
    func testTryFlush_doneChatTask_unloadedTask_usesSummaryFallback() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        // makeActive: false → the task is indexed (summary carries isChatMode) but
        // NOT loaded, so the loaded-task branch of isChatModeTask returns nil.
        guard let taskID = await store.createTask(
            title: "chat", supervisorTask: "g", makeActive: false
        ) else {
            return XCTFail("Could not create task")
        }
        XCTAssertNil(store.loadedTask(taskID), "precondition: task must be unloaded")
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: taskID)
        store.engineState[taskID] = .done

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(started, [taskID],
                       "TaskSummary.isChatMode fallback must classify the unloaded task as chat")
        XCTAssertTrue(sut.hasQueuedMessage(for: taskID))
    }

    /// A CLOSED chat task is finalized — the wake path's closed guard discards the
    /// queue instead of starting a run (startRun would silently REOPEN it:
    /// `createNewRun` clears `closedAt`).
    func testTryFlush_doneChatTask_closed_dropsQueueAndDoesNotStart() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        await store.mutateTask(taskID: taskID) { $0.closedAt = Date() }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        sut.appendQueuedMessage(msg("late"), for: taskID)
        store.engineState[taskID] = .done

        controller.tryFlushQueuedMessages()

        XCTAssertTrue(started.isEmpty, "A closed task must never be restarted by a message")
        XCTAssertFalse(sut.hasQueuedMessage(for: taskID), "Queue is discarded for a closed task")
        XCTAssertEqual(store.lastInfoMessage, "1 queued message(s) discarded — task closed.")
    }

    /// `.done`-chat shares the in-flight dedup guard: two synchronous ticks collapse
    /// to one startRun while the first is in flight.
    func testTryFlush_doneChatTask_inFlightGuard_dedupesStart() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: taskID)
        store.engineState[taskID] = .done

        controller.tryFlushQueuedMessages()
        controller.tryFlushQueuedMessages()

        XCTAssertEqual(started, [taskID],
                       "Two synchronous .done-chat ticks must collapse to one startRun")
    }

    /// No wake-loop on an unconsumable queue: a started run that ends `.done` again
    /// WITHOUT consuming the message (consume-side persistence failure re-prepends
    /// the batch) gets exactly one attempt per message — the second fruitless tick
    /// discards honestly instead of starting LLM passes forever. Mirrors the
    /// `.failed` give-up.
    func testTryFlush_doneChatTask_fruitlessStart_secondTickDiscards() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: taskID)
        store.engineState[taskID] = .done

        controller.tryFlushQueuedMessages()
        XCTAssertEqual(started, [taskID], "First tick earns the wake attempt")
        // Simulate the dispatched startRun finishing with the queue STILL unconsumed
        // and the engine back at .done.
        controller.clearPendingResumeForQueueFlushForTesting(taskID: taskID)

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(started, [taskID], "No second start — the attempt was already spent")
        XCTAssertFalse(sut.hasQueuedMessage(for: taskID), "Queue is discarded honestly")
        XCTAssertEqual(store.lastInfoMessage,
                       "1 queued message(s) discarded — the chat couldn't be restarted.")
    }

    /// Loaded NON-chat task at `.done` still discards — pins the loaded-task branch
    /// of `isChatModeTask` (the no-work-folder discard tests only pin the fallback).
    func testTryFlush_doneNonChatLoadedTask_discards() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let faangID = store.snapshot?.workFolder.teams.first(where: { !$0.isChatMode })?.id,
              let taskID = await store.createTask(
                  title: "pipeline", supervisorTask: "g", preferredTeamID: faangID
              ) else {
            return XCTFail("Could not create non-chat task")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: taskID)
        store.engineState[taskID] = .done

        controller.tryFlushQueuedMessages()

        XCTAssertTrue(started.isEmpty, "A completed non-chat pipeline is never restarted by a message")
        XCTAssertFalse(sut.hasQueuedMessage(for: taskID))
        XCTAssertEqual(store.lastInfoMessage, "1 queued message(s) discarded — task completed.")
    }

    /// Mirror of `testTryFlush_failedEngine_brandNewMessageAfterPriorAttempt_*` for
    /// the `.done`-chat arm: a brand-new message sent after a fruitless start earns
    /// its own fresh wake (set algebra: queued ⊄ attempted) — without it, the second
    /// message a user sends to an idle chat after one fruitless start would be
    /// silently discarded.
    func testTryFlush_doneChatTask_brandNewMessageAfterPriorAttempt_getsFreshStart() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        sut.appendQueuedMessage(msg("first"), for: taskID)
        store.engineState[taskID] = .done

        controller.tryFlushQueuedMessages()
        XCTAssertEqual(started, [taskID])
        controller.clearPendingResumeForQueueFlushForTesting(taskID: taskID)
        sut.appendQueuedMessage(msg("second"), for: taskID)

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(started, [taskID, taskID],
                       "A brand-new message must earn a fresh start attempt")
        XCTAssertTrue(sut.hasQueuedMessage(for: taskID), "Both messages stay queued for the fresh run")
    }

    /// Review-critical pin: the `.failed`-resume and `.done`-chat-start give-up maps
    /// are SEPARATE. A spent resume attempt is no evidence a fresh-run start would
    /// fail (different mechanisms) — sharing one map would discard the message on a
    /// `.failed`→`.done` transition without the start path ever being tried.
    func testTryFlush_failedThenDoneChat_startGetsItsOwnAttempt() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        var resumed: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: taskID)

        // 1. Failed engine → resume attempt spends the message in the .failed map.
        store.engineState[taskID] = .failed
        controller.tryFlushQueuedMessages()
        XCTAssertEqual(resumed, [taskID])
        controller.clearPendingResumeForQueueFlushForTesting(taskID: taskID)

        // 2. Engine lands at .done (chat) with the message still queued — the start
        //    path must fire, NOT discard via the resume path's spent attempt.
        store.engineState[taskID] = .done
        controller.tryFlushQueuedMessages()

        XCTAssertEqual(started, [taskID],
                       "The .done-chat start must get its own attempt despite the spent resume")
        XCTAssertTrue(sut.hasQueuedMessage(for: taskID))
        XCTAssertNil(store.lastInfoMessage, "No discard — the message is being delivered")
    }

    // MARK: - performStartWake (the async .start body the test seam bypasses)

    /// The seam-based `.done`-chat tests never execute the dispatched Task body —
    /// this drives it directly. A CLOSED task must never be reopened by a queued
    /// message: `startRun` has no closed guard and `createNewRun` CLEARS `closedAt`,
    /// so the post-load re-check is the only thing standing between a stray message
    /// and silent task resurrection.
    func testPerformStartWake_closedTask_discardsQueue_neverReopens() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        await store.mutateTask(taskID: taskID) { $0.closedAt = Date() }
        let runsBefore = store.loadedTask(taskID)?.runs.count ?? 0
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        sut.appendQueuedMessage(msg("late"), for: taskID)

        await controller.performStartWake(taskID: taskID)

        XCTAssertEqual(store.loadedTask(taskID)?.runs.count ?? -1, runsBefore,
                       "No run may be created against a closed task")
        XCTAssertNotNil(store.loadedTask(taskID)?.closedAt,
                        "closedAt surviving proves createNewRun never ran (it clears the field)")
        XCTAssertFalse(sut.hasQueuedMessage(for: taskID), "Queue is discarded for a closed task")
        XCTAssertEqual(store.lastInfoMessage, "1 queued message(s) discarded — task closed.")
    }

    /// Load failure (task deleted concurrently / unreadable task.json) must NOT be
    /// conflated with "task is open": `loadedTask(id)?.closedAt == nil` would be
    /// vacuously true for a nil task and start a run against a phantom. The wake
    /// keeps the queue and surfaces the error instead.
    func testPerformStartWake_loadFailure_keepsQueue_surfacesError() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        let phantomID = 999
        sut.appendQueuedMessage(msg("hi"), for: phantomID)

        await controller.performStartWake(taskID: phantomID)

        XCTAssertTrue(sut.hasQueuedMessage(for: phantomID),
                      "Queue must survive a load failure (retried on a later tick)")
        XCTAssertEqual(store.lastErrorMessage,
                       "Couldn't load task #999 to deliver queued message(s) — kept in queue.")
    }

    /// Integrated contract for the load-failure path: the `.done`-chat arm stamps
    /// the give-up map BEFORE dispatching the wake, so a wake that aborts on load
    /// failure must UN-stamp — otherwise the "kept in queue" promise is followed by
    /// a misattributed "chat couldn't be restarted" discard on the next tick, with
    /// zero real start attempts ever made.
    func testTryFlush_doneChatTask_loadFailure_unstampsAttempt_nextTickRetries() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(
            title: "chat", supervisorTask: "g", makeActive: false
        ) else {
            return XCTFail("Could not create task")
        }
        // Unloadable while still indexed as chat-mode: delete the task's JSON.
        let taskJSON = tmp.appendingPathComponent(".nanoteams/internal/tasks/\(taskID)/task.json")
        try FileManager.default.removeItem(at: taskJSON)
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: taskID)
        store.engineState[taskID] = .done

        // Tick 1: stamps the give-up map + dispatches the wake (seam records it).
        controller.tryFlushQueuedMessages()
        XCTAssertEqual(started, [taskID])
        // The dispatched body load-fails — run the production body directly.
        await controller.performStartWake(taskID: taskID)
        XCTAssertTrue(sut.hasQueuedMessage(for: taskID), "Queue kept on load failure")
        XCTAssertFalse(controller._testHasChatStartAttempted(taskID: taskID),
                       "An aborted-before-startRun wake must not count as an attempt")
        controller.clearPendingResumeForQueueFlushForTesting(taskID: taskID)

        // Tick 2: the spent-attempt discard must NOT fire — the wake retries.
        controller.tryFlushQueuedMessages()
        XCTAssertEqual(started, [taskID, taskID],
                       "Load failure must not spend the message's one start attempt")
        XCTAssertTrue(sut.hasQueuedMessage(for: taskID))
    }

    /// Corner: the documented reopen scenario verbatim — an UNLOADED closed chat
    /// task. The sync pre-check in `wakeRunForQueuedMessages` is nil-soft for
    /// unloaded tasks, so `performStartWake`'s post-load re-check is the only
    /// guard; it must load the task from disk, see `closedAt`, and discard.
    func testPerformStartWake_unloadedClosedChatTask_discardsAfterLoad() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(
            title: "chat", supervisorTask: "g", makeActive: false
        ) else {
            return XCTFail("Could not create task")
        }
        // Close it (persists closedAt to disk), then UNLOAD so the sync pre-check
        // would have been blind to the closure.
        await store.ensureTaskLoaded(taskID)
        await store.mutateTask(taskID: taskID) { $0.closedAt = Date() }
        store.snapshot?.loadedTasks[taskID] = nil
        XCTAssertNil(store.loadedTask(taskID), "precondition: task must be unloaded")

        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        sut.appendQueuedMessage(msg("late"), for: taskID)

        await controller.performStartWake(taskID: taskID)

        XCTAssertNotNil(store.loadedTask(taskID)?.closedAt,
                        "closedAt surviving the wake proves the task was never reopened")
        XCTAssertEqual(store.loadedTask(taskID)?.runs.count ?? -1, 0,
                       "No run may be created against the closed task")
        XCTAssertFalse(sut.hasQueuedMessage(for: taskID))
        XCTAssertEqual(store.lastInfoMessage, "1 queued message(s) discarded — task closed.")
    }

    /// Corner: the give-up must be DEFERRED while a wake is in flight. Tick 2 sees
    /// every message attempted but the in-flight flag still set — it must neither
    /// discard nor double-start; only tick 3 (after the wake settles with the queue
    /// unconsumed) discards.
    func testTryFlush_doneChatTask_giveUpDeferredWhileWakeInFlight() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: taskID)
        store.engineState[taskID] = .done

        controller.tryFlushQueuedMessages()           // tick 1: wake, in-flight set
        controller.tryFlushQueuedMessages()           // tick 2: in-flight still set

        XCTAssertEqual(started, [taskID], "No double start while the wake is in flight")
        XCTAssertTrue(sut.hasQueuedMessage(for: taskID),
                      "No discard while the wake could still consume the queue")
        XCTAssertNil(store.lastInfoMessage)

        controller.clearPendingResumeForQueueFlushForTesting(taskID: taskID)
        controller.tryFlushQueuedMessages()           // tick 3: wake settled, queue unconsumed

        XCTAssertFalse(sut.hasQueuedMessage(for: taskID), "Now the give-up fires")
        XCTAssertEqual(store.lastInfoMessage,
                       "1 queued message(s) discarded — the chat couldn't be restarted.")
    }

    /// Truth table for `isChatModeTask` — the discriminator between "wake the chat"
    /// and "discard the pipeline queue": loaded chat / loaded non-chat / indexed-only
    /// chat (summary fallback) / unknown id (safe default false).
    func testIsChatModeTask_truthTable() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let faangID = store.snapshot?.workFolder.teams.first(where: { !$0.isChatMode })?.id,
              let chatLoaded = await store.createTask(title: "c1", supervisorTask: "g"),
              let pipeline = await store.createTask(title: "p", supervisorTask: "g", preferredTeamID: faangID),
              let chatIndexed = await store.createTask(title: "c2", supervisorTask: "g", makeActive: false)
        else {
            return XCTFail("Could not create tasks")
        }
        await store.ensureTaskLoaded(chatLoaded)
        XCTAssertNil(store.loadedTask(chatIndexed), "precondition: c2 must be index-only")

        XCTAssertTrue(QuickCaptureController.isChatModeTask(chatLoaded, store: store),
                      "loaded chat task → true")
        XCTAssertFalse(QuickCaptureController.isChatModeTask(pipeline, store: store),
                       "loaded non-chat task → false")
        XCTAssertTrue(QuickCaptureController.isChatModeTask(chatIndexed, store: store),
                      "unloaded task → TaskSummary.isChatMode fallback → true")
        XCTAssertFalse(QuickCaptureController.isChatModeTask(987_654, store: store),
                       "unknown id → false (safe default preserves the discard behavior)")
    }

    /// Corner of the honest-return contract: the `.needsSupervisorInput` consumption
    /// is a detached Task — at `queueChatMessage`'s return the message must still be
    /// queued (`true`), because "still queued" is exactly "not synchronously discarded".
    func testQueueChatMessage_needsSupervisorInput_returnsTrue_queueIntactAtReturn() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        store.engineState[3] = .needsSupervisorInput

        let queued = controller.queueChatMessage(
            text: "answer-ish", attachments: [], clippedTexts: [], taskID: 3
        )

        XCTAssertTrue(queued, "Async consumption must not affect the synchronous return")
        XCTAssertTrue(sut.hasQueuedMessage(for: 3),
                      "The flush Task has not run at return time — message still queued")
    }

    // MARK: - queueChatMessage honest return (synchronous discard → false)

    /// When the immediate flush synchronously discards the message (non-chat `.done`),
    /// `queueChatMessage` must return `false` so the composer keeps the draft and does
    /// NOT overwrite the discard banner with a "Message queued" lie — the pre-fix
    /// composer showed "resuming the task" while the message was already destroyed.
    func testQueueChatMessage_doneNonChat_returnsFalse_keepsDiscardBanner() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        store.engineState[1] = .done  // no work folder → chat lookup falls back to false

        let queued = controller.queueChatMessage(
            text: "hello?", attachments: [], clippedTexts: [], taskID: 1
        )

        XCTAssertFalse(queued, "Synchronously discarded message must report failure")
        XCTAssertFalse(sut.hasQueuedMessage(for: 1))
        XCTAssertEqual(store.lastInfoMessage, "1 queued message(s) discarded — task completed.",
                       "The discard banner is the honest one — callers must not overwrite it")
    }

    /// The chat counterpart: the message survives the flush (wake dispatched), so the
    /// composer's "Message queued — resuming the task" banner is earned.
    func testQueueChatMessage_doneChatTask_returnsTrue_andStarts() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "chat", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var started: [Int] = []
        controller.startRunForTesting = { started.append($0) }
        store.engineState[taskID] = .done

        let queued = controller.queueChatMessage(
            text: "continue please", attachments: [], clippedTexts: [], taskID: taskID
        )

        XCTAssertTrue(queued)
        XCTAssertEqual(started, [taskID], "Sending to a .done chat immediately starts a fresh run")
        XCTAssertTrue(sut.hasQueuedMessage(for: taskID))
    }

    /// A `.failed` task whose resume revives nothing (stall/deadlock, or an unrevivable
    /// step) must NOT wake-loop: the first send attempts a resume; once that attempt has
    /// completed and the engine is STILL `.failed`, the queue is discarded honestly
    /// instead of re-resuming forever.
    func testTryFlush_failedEngine_resumeDidNotRevive_secondTickDiscardsQueue() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("a"), for: 1)
        store.engineState[1] = .failed

        // Attempt #1: try to resume.
        controller.tryFlushQueuedMessages()
        XCTAssertEqual(resumed, [1], "First .failed send attempts a resume")
        XCTAssertTrue(sut.hasQueuedMessage(for: 1), "Queue preserved while the attempt is pending")
        XCTAssertNil(store.lastInfoMessage)

        // Simulate the dispatched resume completing while the engine stays .failed.
        controller.clearPendingResumeForQueueFlushForTesting(taskID: 1)

        // Attempt #2: still .failed, prior attempt done → give up + discard honestly.
        controller.tryFlushQueuedMessages()
        XCTAssertEqual(resumed, [1], "No second resume — the prior attempt already failed to revive")
        XCTAssertFalse(sut.hasQueuedMessage(for: 1), "Queue discarded once resume proved fruitless")
        XCTAssertEqual(store.lastInfoMessage,
                       "1 queued message(s) discarded — task failed and couldn't be retried.")
    }

    /// A new message via `queueChatMessage` has a not-yet-attempted ID, so a fresh send to
    /// a still-`.failed` task attempts a resume rather than immediately discarding.
    func testQueueChatMessage_newMessage_grantsFreshResumeAttempt() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        store.engineState[1] = .failed

        // Attempt #1 (direct append) then simulate it completing, still failed.
        sut.appendQueuedMessage(msg("a"), for: 1)
        controller.tryFlushQueuedMessages()
        controller.clearPendingResumeForQueueFlushForTesting(taskID: 1)
        resumed.removeAll()

        // A new message carries an un-attempted ID → its internal tryFlush attempts a
        // fresh resume instead of give-up-discarding.
        _ = controller.queueChatMessage(text: "b", attachments: [], clippedTexts: [], taskID: 1)

        XCTAssertEqual(resumed, [1], "A new (un-attempted) message earns a fresh resume attempt")
        XCTAssertTrue(sut.hasQueuedMessage(for: 1),
                      "Messages remain queued for the fresh attempt (not discarded)")
    }

    /// REGRESSION: a doomed resume drives the engine through a TRANSIENT `.running`
    /// (`engine.resume()` sets `.running` before the run loop re-detects the failed role
    /// and transitions back to `.failed`). That transient `.running` tick must NOT reset
    /// the one-shot give-up guard — otherwise the give-up never fires and the message
    /// wake-loops (resume → .running → .failed → resume …) forever in production, even
    /// though a `resumeRunForTesting`-based test (no real engine, no flicker) would pass.
    func testTryFlush_failedEngine_transientRunningDoesNotDefeatGiveUp() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("a"), for: 1)
        store.engineState[1] = .failed

        // Attempt #1.
        controller.tryFlushQueuedMessages()
        XCTAssertEqual(resumed, [1])
        controller.clearPendingResumeForQueueFlushForTesting(taskID: 1)

        // The engine flickers through .running during the doomed resume…
        store.engineState[1] = .running
        controller.tryFlushQueuedMessages()
        // …then re-fails. This .failed tick must GIVE UP, not grant a 2nd attempt.
        store.engineState[1] = .failed
        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [1],
                       "Transient .running must not grant a second resume attempt")
        XCTAssertFalse(sut.hasQueuedMessage(for: 1),
                       "Give-up must still fire after a transient .running")
        XCTAssertEqual(store.lastInfoMessage,
                       "1 queued message(s) discarded — task failed and couldn't be retried.")
    }

    /// REGRESSION: a brand-new queued message must earn its OWN resume attempt, even on a
    /// task that already had a (successful) attempt for a PRIOR message. Non-`queueChatMessage`
    /// enqueue paths — notably the Autovisor's `message_task`, which calls
    /// `appendQueuedMessage` directly — must not be silently discarded by a stale per-task
    /// give-up marker.
    func testTryFlush_failedEngine_brandNewMessageAfterPriorAttempt_getsFreshAttempt() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }

        // Episode 1: a message attempts a resume; simulate it SUCCEEDING (message consumed).
        sut.appendQueuedMessage(msg("a"), for: 1)
        store.engineState[1] = .failed
        controller.tryFlushQueuedMessages()
        controller.clearPendingResumeForQueueFlushForTesting(taskID: 1)
        sut.clearQueuedMessages(for: 1)            // msgA consumed by the revived step
        store.engineState[1] = .running
        controller.tryFlushQueuedMessages()

        // Episode 2: the task re-fails; a brand-new message arrives via a DIRECT append.
        resumed.removeAll()
        store.engineState[1] = .failed
        sut.appendQueuedMessage(msg("b"), for: 1)  // NOT via queueChatMessage
        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [1],
                       "A brand-new queued message must earn its own resume attempt")
        XCTAssertTrue(sut.hasQueuedMessage(for: 1),
                      "The new message must not be discarded by a stale prior-attempt marker")
    }

    /// The give-up is target-AGNOSTIC (it works on message IDs, not targetRoleID): a
    /// TARGETED message whose target role never runs in a failed task is discarded on
    /// give-up. Documents intentional behavior — an undeliverable targeted message is
    /// honestly discarded rather than held forever on a dead task.
    func testTryFlush_failedEngine_targetedMessage_participatesInGiveUp() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(
            QuickCaptureFormState.QueuedChatMessage(
                text: "for engineer", attachments: [], clippedTexts: [], targetRoleID: "engineer"
            )!,
            for: 1
        )
        store.engineState[1] = .failed

        controller.tryFlushQueuedMessages()                  // attempt
        controller.clearPendingResumeForQueueFlushForTesting(taskID: 1)
        controller.tryFlushQueuedMessages()                  // give up

        XCTAssertEqual(resumed, [1],
                       "One attempt then give up — targeting grants no extra attempts")
        XCTAssertFalse(sut.hasQueuedMessage(for: 1),
                       "An undeliverable targeted message is discarded on give-up, not held forever")
        XCTAssertEqual(store.lastInfoMessage,
                       "1 queued message(s) discarded — task failed and couldn't be retried.")
    }

    /// HYGIENE: the give-up attempted-IDs map must not leak entries for tasks that no
    /// longer have queued messages (deleted/consumed). `tryFlushQueuedMessages` prunes the
    /// map to live-queue tasks so a removed task's entry doesn't accumulate.
    func testTryFlush_prunesAttemptedEntriesForTasksWithoutQueuedMessages() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        controller.resumeRunForTesting = { _ in }

        // Task 1: a .failed attempt records an entry in the map.
        sut.appendQueuedMessage(msg("a"), for: 1)
        store.engineState[1] = .failed
        controller.tryFlushQueuedMessages()
        XCTAssertTrue(controller._testHasFailedResumeAttempted(taskID: 1),
                      "An attempt for task 1 records its message ID")

        // Task 1's queue empties (deleted / consumed); task 2 gets an unrelated message.
        sut.clearQueuedMessages(for: 1)
        sut.appendQueuedMessage(msg("b"), for: 2)
        store.engineState[2] = .failed
        controller.tryFlushQueuedMessages()

        XCTAssertFalse(controller._testHasFailedResumeAttempted(taskID: 1),
                       "The stale entry for the now-empty-queue task 1 is pruned")
    }

    func testTryFlush_preservesAllQueuedOnRunning() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        sut.appendQueuedMessage(msg("a"), for: 1)
        sut.appendQueuedMessage(msg("b"), for: 1)
        store.engineState[1] = .running

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(sut.queuedMessages(for: 1).count, 2)
        XCTAssertNil(store.lastInfoMessage, "No user feedback should fire for non-terminal states")
    }

    func testTryFlush_perTaskIsolation_onlyTargetedTaskIsAffected() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        sut.appendQueuedMessage(msg("terminal-a"), for: 1)
        sut.appendQueuedMessage(msg("kept"), for: 2)
        store.engineState[1] = .done
        store.engineState[2] = .running

        controller.tryFlushQueuedMessages()

        XCTAssertFalse(sut.hasQueuedMessage(for: 1))
        XCTAssertEqual(sut.queuedMessages(for: 2).map(\.text), ["kept"],
                       "Task 2's queue must not be touched when Task 1 hits a terminal state")
    }

    // MARK: - Paused / pending / no-engine — wake the run

    /// Regression for "messages just sit in the queue after app restart".
    /// `StatusRecoveryService` brings a chat task back as `.paused` (step `.paused`,
    /// role `.idle`, task `.paused`); without this branch the backstop's `default:
    /// continue` swallows the wake-up signal and the primary path never fires
    /// (no tool-loop is running while the step is paused).
    func testTryFlush_pausedEngineWithQueue_callsResumeRunAndPreservesQueue() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: 1)
        store.engineState[1] = .paused

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [1],
                       ".paused with queued messages must wake the run via resumeRun")
        XCTAssertTrue(sut.hasQueuedMessage(for: 1),
                      "Queue must survive — primary path drains it on the next tool-loop iter")
        XCTAssertNil(store.lastInfoMessage,
                     "No discard message — queue was woken, not dropped")
    }

    /// Engine state nil (e.g. immediately after app restart, before
    /// `syncEngineStateFromRun` runs) must also wake the run.
    func testTryFlush_noEngineEntry_withQueue_callsResumeRun() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("hi"), for: 9)
        // engineState[9] not set → nil

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [9],
                       "Missing engine entry with queued messages must wake the run")
    }

    /// Closed task must NOT be resumed, even when its engine state is `.paused`
    /// or `nil` and the queue is non-empty (race between `closeTask`'s synchronous
    /// `stopEngine` removing the engine state and `handleActiveTaskClosedAtChanged`
    /// dropping the queue). Falling through to a `Task { resumeRun }` here would
    /// resurrect a closed task by creating a fresh engine.
    func testTryFlush_pausedEngine_butTaskClosed_dropsQueueAndDoesNotResume() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "t", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        await store.mutateTask(taskID: taskID) { task in
            task.closedAt = Date()
        }

        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("late"), for: taskID)
        store.engineState[taskID] = .paused

        controller.tryFlushQueuedMessages()

        XCTAssertTrue(resumed.isEmpty,
                      "Closed task must NOT be resumed — queue is dropped instead")
        XCTAssertFalse(sut.hasQueuedMessage(for: taskID),
                       "Queue must be cleared for closed tasks (catches background-close gap)")
        XCTAssertNotNil(store.lastInfoMessage,
                        "User must be told their queued messages were discarded")
    }

    /// Two tryFlush ticks in a row (e.g. UI emits onChange engineState multiple
    /// times before the first resumeRun finishes) must dedupe — exactly one
    /// `resumeRun` per (taskID, in-flight cycle).
    func testTryFlush_pausedEngine_inFlightGuard_dedupesResume() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        // Synchronous closure means the in-flight flag is set + observed in this turn.
        // The flag is cleared after the closure returns by the production guard's
        // `defer`-style cleanup, so back-to-back tryFlush calls within the same
        // synchronous turn must collapse to one invocation.
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("a"), for: 1)
        sut.appendQueuedMessage(msg("b"), for: 1)
        store.engineState[1] = .paused

        controller.tryFlushQueuedMessages()
        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [1],
                       "Two synchronous tryFlush ticks must collapse to one resumeRun while the first is in-flight")
    }

    /// Enqueueing a message while the engine is `.paused` must immediately drive
    /// the wake-up — without this, the message hangs until some other event
    /// (engineState change) fires onChange. Caught the original user-reported bug.
    func testQueueChatMessage_pausedEngine_immediatelyTriggersResume() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        store.engineState[1] = .paused

        let queued = controller.queueChatMessage(
            text: "wake me up",
            attachments: [],
            clippedTexts: [],
            taskID: 1,
            targetRoleID: "coding-assistant"
        )

        XCTAssertTrue(queued)
        XCTAssertEqual(resumed, [1],
                       "queueChatMessage on .paused engine must trigger tryFlush → resumeRun without waiting for an engineState change")
    }

    /// Counterpart: queueing on a `.running` engine must NOT call resumeRun
    /// (the primary path will pick it up on the next tool-loop iteration).
    func testQueueChatMessage_runningEngine_doesNotTriggerResume() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        store.engineState[1] = .running

        _ = controller.queueChatMessage(
            text: "for the running role",
            attachments: [],
            clippedTexts: [],
            taskID: 1,
            targetRoleID: nil
        )

        XCTAssertTrue(resumed.isEmpty,
                      ".running engine — primary path handles delivery on next iteration; no wake-up needed")
        XCTAssertEqual(sut.queuedMessages(for: 1).count, 1)
    }

    /// `removeTask` must clear the per-task queue so a reincarnated taskID
    /// doesn't inherit stale messages, and so the new wake-up branch doesn't
    /// burn an empty `Task { resumeRun }` on every onChange engineState.
    func testRemoveTask_clearsQueuedMessages() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        store.quickCaptureFormState = sut
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "t", supervisorTask: "g") else {
            return XCTFail("Could not create task")
        }
        sut.appendQueuedMessage(msg("orphan"), for: taskID)

        await store.removeTask(taskID)

        XCTAssertFalse(sut.hasQueuedMessage(for: taskID),
                       "removeTask must clear the queue so background-task delete doesn't leak orphan messages")
    }

    // MARK: - End-to-end user scenarios

    /// Scenario: User restarts the app, opens a chat task, fires off three quick
    /// messages without waiting. Expectation: all three sit in the queue in FIFO
    /// order, exactly one `resumeRun` fires (in-flight guard collapses the burst),
    /// and after the simulated resume completes a fresh wake-up tick can dispatch
    /// another resume if needed.
    func testScenario_burstOfMessagesAfterRestart_singleResumeFIFOPreserved() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        store.engineState[1] = .paused

        _ = controller.queueChatMessage(text: "first",  attachments: [], clippedTexts: [], taskID: 1, targetRoleID: "ca")
        _ = controller.queueChatMessage(text: "second", attachments: [], clippedTexts: [], taskID: 1, targetRoleID: "ca")
        _ = controller.queueChatMessage(text: "third",  attachments: [], clippedTexts: [], taskID: 1, targetRoleID: "ca")

        XCTAssertEqual(resumed, [1],
                       "Three back-to-back enqueues must collapse to ONE resume — in-flight guard")
        XCTAssertEqual(sut.queuedMessages(for: 1).map(\.text), ["first", "second", "third"],
                       "All three messages preserved in FIFO order — primary path will drain on iter 1")

        // Simulate the production `Task { resumeRun }` completing — engine moved
        // to .running, in-flight flag cleared. A subsequent enqueue (e.g. user
        // sends a fourth while the assistant is still streaming) routes through
        // the .running default branch (no resume needed; primary path handles it).
        controller.clearPendingResumeForQueueFlushForTesting(taskID: 1)
        store.engineState[1] = .running
        _ = controller.queueChatMessage(text: "fourth", attachments: [], clippedTexts: [], taskID: 1, targetRoleID: "ca")

        XCTAssertEqual(resumed, [1],
                       ".running engine — primary path drains; no extra resume")
        XCTAssertEqual(sut.queuedMessages(for: 1).count, 4,
                       "Fourth message also queued, awaiting next tool-loop iter")
    }

    /// Scenario: Two paused chat tasks (e.g. user has Coding Assistant and Quest
    /// Party both running, restarted the app, both came back as `.paused`). User
    /// sends one message to each. Each task's resume must fire independently —
    /// the in-flight guard is per-task, not global.
    func testScenario_twoPausedTasks_eachGetsIndependentResume() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        store.engineState[1] = .paused
        store.engineState[2] = .paused

        _ = controller.queueChatMessage(text: "to task 1", attachments: [], clippedTexts: [], taskID: 1, targetRoleID: nil)
        _ = controller.queueChatMessage(text: "to task 2", attachments: [], clippedTexts: [], taskID: 2, targetRoleID: nil)

        XCTAssertEqual(Set(resumed), [1, 2],
                       "Each task's resume fires independently — guard set is per-taskID")
        XCTAssertTrue(sut.hasQueuedMessage(for: 1))
        XCTAssertTrue(sut.hasQueuedMessage(for: 2))
    }

    /// Scenario: User sends a message into a task that is already `.needsSupervisorInput`
    /// (i.e. an `ask_supervisor` is pending). The backstop's `flushQueuedChatMessage`
    /// path must fire — NOT the wake-up resume path. Critical: queueing on .needsSupervisorInput
    /// historically only fired when an unrelated `engineState` onChange happened later;
    /// the post-enqueue `tryFlush` ensures it fires immediately.
    func testScenario_queueWhileSupervisorAwaiting_immediatelyDispatchesBackstop() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        store.engineState[1] = .needsSupervisorInput

        _ = controller.queueChatMessage(text: "answer-as-msg", attachments: [], clippedTexts: [], taskID: 1, targetRoleID: nil)

        XCTAssertTrue(resumed.isEmpty,
                      ".needsSupervisorInput must NOT call resumeRun — backstop's `flushQueuedChatMessage` owns this state")
        // Queue is preserved here because the dispatched flushQueuedChatMessage `Task`
        // hasn't completed in this synchronous turn. The behavioral check above is
        // what matters — wake-up branch was skipped, not the wrong path.
        XCTAssertEqual(sut.queuedMessages(for: 1).count, 1,
                       "Message preserved until the async backstop completes")
    }

    /// Scenario: User closes a task while messages are queued. Both via the
    /// established `handleActiveTaskClosedAtChanged` (active-task path) and via
    /// the new wake-up branch's closed-task guard (covers race + background-task gap).
    func testScenario_userClosesTaskWithQueuedMessages_messagesDiscardedWithFeedback() async throws {
        let tmp = try makeTempWorkFolder()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TestOrchestrator.make()
        store.quickCaptureFormState = sut
        await store.openWorkFolder(tmp)
        guard let taskID = await store.createTask(title: "t", supervisorTask: "g") else {
            return XCTFail("createTask returned nil")
        }
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("first"), for: taskID)
        sut.appendQueuedMessage(msg("second"), for: taskID)
        sut.appendQueuedMessage(msg("third"), for: taskID)
        // Simulate the racy ordering: closeTask removed the engine state, but the
        // `closedAt` onChange hasn't fired yet (so handleActiveTaskClosedAtChanged
        // hasn't dropped the queue). Then a wake-up tick comes in.
        await store.mutateTask(taskID: taskID) { $0.closedAt = Date() }
        store.engineState.removeEngine(for: taskID)

        controller.tryFlushQueuedMessages()

        XCTAssertTrue(resumed.isEmpty,
                      "Closed task must NOT be resurrected by the wake-up branch")
        XCTAssertFalse(sut.hasQueuedMessage(for: taskID),
                       "All 3 queued messages discarded")
        XCTAssertEqual(store.lastInfoMessage,
                       "3 queued message(s) discarded — task closed.",
                       "User must see the count of dropped messages")
    }

    /// Scenario: User just sent a message to a paused chat. The first resume
    /// dispatches; the engine transitions paused → running → paused (e.g. role
    /// completed an iteration and is awaiting the next user input in chat mode).
    /// A second user message must be deliverable — the in-flight guard must clear.
    func testScenario_resumeCompletes_thenSecondMessageCanResumeAgain() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        store.engineState[1] = .paused

        _ = controller.queueChatMessage(text: "msg-1", attachments: [], clippedTexts: [], taskID: 1, targetRoleID: nil)
        XCTAssertEqual(resumed, [1])

        // Simulate the dispatched Task completing (clears in-flight flag).
        controller.clearPendingResumeForQueueFlushForTesting(taskID: 1)

        // Now user sends another while engine is still .paused (role finished
        // iter, hasn't picked up the queued message yet, or chat re-paused).
        _ = controller.queueChatMessage(text: "msg-2", attachments: [], clippedTexts: [], taskID: 1, targetRoleID: nil)
        XCTAssertEqual(resumed, [1, 1],
                       "After the first resume completes, the second message must dispatch a new resume")
    }

    /// Scenario: User has a chat with no engine state entry yet (very fresh
    /// task right after restart, before `syncEngineStateFromRun` ran). Messages
    /// queued in this window must still wake the run.
    func testScenario_freshAfterRestart_noEngineEntryYet_queueStillTriggersResume() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        // engineState is empty — the orchestrator hasn't seeded it yet.

        _ = controller.queueChatMessage(text: "early bird", attachments: [], clippedTexts: [], taskID: 42, targetRoleID: nil)

        XCTAssertEqual(resumed, [42],
                       "Fresh task with no engine state entry must still wake the run on enqueue")
    }

    /// Scenario: Queue is empty. Wake-up branches must not fire spurious
    /// resumeRun calls when there's nothing to deliver.
    func testScenario_emptyQueue_neverDispatchesResumeRegardlessOfState() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }

        for state: TeamEngineState in [.pending, .running, .paused, .needsSupervisorInput, .needsAcceptance, .done, .failed] {
            store.engineState[1] = state
            controller.tryFlushQueuedMessages()
        }

        XCTAssertTrue(resumed.isEmpty,
                      "tryFlush iterates `taskIDsWithQueuedMessages` — empty queue means zero iterations and zero dispatches")
    }

    /// Scenario: Multi-task setup where one task is paused (with queue) and
    /// another is running (with queue). Only the paused one should be woken;
    /// the running one's queue is owned by the primary path on its next iter.
    func testScenario_mixedStates_onlyPausedTriggersResume() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        var resumed: [Int] = []
        controller.resumeRunForTesting = { resumed.append($0) }
        sut.appendQueuedMessage(msg("for paused"), for: 1)
        sut.appendQueuedMessage(msg("for running"), for: 2)
        store.engineState[1] = .paused
        store.engineState[2] = .running

        controller.tryFlushQueuedMessages()

        XCTAssertEqual(resumed, [1],
                       ".paused wakes; .running is left to the primary path")
        XCTAssertTrue(sut.hasQueuedMessage(for: 1))
        XCTAssertTrue(sut.hasQueuedMessage(for: 2),
                      ".running queue preserved — primary path consumes on next iter")
    }

    // MARK: - Test helpers (paused/closed task scenarios)

    private func makeTempWorkFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoteams-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - MainLayoutView onChange handler wiring

    func testHandleActiveTaskClosedAtChanged_dropsQueueWhenClosed() {
        let controller = QuickCaptureController(formState: sut)
        sut.appendQueuedMessage(msg("a"), for: 10)

        controller.handleActiveTaskClosedAtChanged(newValue: Date(), taskID: 10)

        XCTAssertFalse(sut.hasQueuedMessage(for: 10))
    }

    func testHandleActiveTaskClosedAtChanged_ignoresNilTransition() {
        let controller = QuickCaptureController(formState: sut)
        sut.appendQueuedMessage(msg("a"), for: 10)

        // closedAt going non-nil→nil (e.g. task re-opened) must NOT drop the queue
        controller.handleActiveTaskClosedAtChanged(newValue: nil, taskID: 10)

        XCTAssertTrue(sut.hasQueuedMessage(for: 10),
                      "Queue must survive a nil closedAt transition")
    }

    func testHandleActiveTaskClosedAtChanged_ignoresNilTaskID() {
        let controller = QuickCaptureController(formState: sut)
        sut.appendQueuedMessage(msg("a"), for: 10)

        // Defensive: MainLayoutView may fire onChange with no active task — no-op.
        controller.handleActiveTaskClosedAtChanged(newValue: Date(), taskID: nil)

        XCTAssertTrue(sut.hasQueuedMessage(for: 10))
    }

    // MARK: - Backstop priority-tier collector (collectQueuedMessagesForFlush)

    /// Pure-helper tests ensuring the backstop `.needsSupervisorInput` path
    /// uses the same priority tiers AND drain-all batching as the primary
    /// injection path. Without this alignment, delivery would diverge based
    /// on whether the role was running vs. paused.

    private func m(_ text: String, target: String? = nil, id: UUID = UUID())
        -> QuickCaptureFormState.QueuedChatMessage
    {
        QuickCaptureFormState.QueuedChatMessage(
            text: text, attachments: [], clippedTexts: [], targetRoleID: target, id: id
        )!
    }

    func testCollectForFlush_roleTargeted_winsOverOlderUntargeted_andDrainsBoth() {
        let untargeted = m("team first (older)", target: nil)
        let pmTargeted = m("PM (newer)", target: "pm")

        let pick = QuickCaptureController.collectQueuedMessagesForFlush(
            queue: [untargeted, pmTargeted],
            waitingStepRoleIDs: ["pm", "tl"]
        )

        XCTAssertEqual(pick?.stepRoleID, "pm",
                       "Role-targeted message picks the recipient role")
        XCTAssertEqual(pick?.messageIDs, [pmTargeted.id, untargeted.id],
                       "Tier 1 (role-targeted to picked role) drains first, then tier 2 (untargeted) — single batch")
    }

    func testCollectForFlush_roleTargetedButNotWaiting_skipsToUntargeted() {
        let pmTargeted = m("for PM (not waiting)", target: "pm")
        let untargeted = m("any role", target: nil)

        let pick = QuickCaptureController.collectQueuedMessagesForFlush(
            queue: [pmTargeted, untargeted],
            waitingStepRoleIDs: ["tl"] // PM is not in the waiting set
        )

        XCTAssertEqual(pick?.stepRoleID, "tl",
                       "Targeted but non-waiting target falls through to untargeted tier")
        XCTAssertEqual(pick?.messageIDs, [untargeted.id],
                       "PM-targeted stays queued for its own backstop fire; only untargeted joins this batch")
    }

    func testCollectForFlush_multipleTargetedSameRole_drainsAllInFIFO() {
        let pmA = m("PM A", target: "pm")
        let pmB = m("PM B", target: "pm")
        let tl = m("TL", target: "tl")

        let pick = QuickCaptureController.collectQueuedMessagesForFlush(
            queue: [pmA, pmB, tl],
            waitingStepRoleIDs: ["pm", "tl"]
        )

        XCTAssertEqual(pick?.stepRoleID, "pm",
                       "First role-targeted match picks the recipient")
        XCTAssertEqual(pick?.messageIDs, [pmA.id, pmB.id],
                       "Both PM-targeted drain in FIFO; TL-targeted stays queued for its own fire")
    }

    func testCollectForFlush_noWaitingSteps_returnsNil() {
        let pick = QuickCaptureController.collectQueuedMessagesForFlush(
            queue: [m("anything", target: nil)],
            waitingStepRoleIDs: []
        )
        XCTAssertNil(pick, "Empty waiting list = nothing to deliver to")
    }

    func testCollectForFlush_emptyQueue_returnsNil() {
        let pick = QuickCaptureController.collectQueuedMessagesForFlush(
            queue: [],
            waitingStepRoleIDs: ["pm"]
        )
        XCTAssertNil(pick)
    }

    func testCollectForFlush_untargetedDelivered_toFirstWaitingRole() {
        let untargeted1 = m("team a", target: nil)
        let untargeted2 = m("team b", target: nil)

        let pick = QuickCaptureController.collectQueuedMessagesForFlush(
            queue: [untargeted1, untargeted2],
            waitingStepRoleIDs: ["first", "second", "third"]
        )

        XCTAssertEqual(pick?.stepRoleID, "first",
                       "Untargeted messages route to the first waiting role, preserving caller order")
        XCTAssertEqual(pick?.messageIDs, [untargeted1.id, untargeted2.id],
                       "All untargeted drain into the same batch, FIFO")
    }

    func testCollectForFlush_drainsRoleTargetedThenUntargeted_mirrorsPrimaryPath() {
        // Mirrors `ConsumeQueuedSupervisorMessageTests.testConsume_drainsAllEligibleMessages_targetedBeforeUntargeted`
        let untargeted = m("team", target: nil)
        let pmA = m("pm A", target: "pm")
        let tlOnly = m("tl only", target: "tl")
        let pmB = m("pm B", target: "pm")

        let pick = QuickCaptureController.collectQueuedMessagesForFlush(
            queue: [untargeted, pmA, tlOnly, pmB],
            waitingStepRoleIDs: ["pm"]  // only PM is waiting
        )

        XCTAssertEqual(pick?.stepRoleID, "pm")
        XCTAssertEqual(pick?.messageIDs, [pmA.id, pmB.id, untargeted.id],
                       "Tier 1 (pm-targeted FIFO) → tier 2 (untargeted FIFO). TL-targeted skipped — its target isn't waiting.")
    }

    func testHandleEngineStateChanged_drivesFlush() async {
        let store = TestOrchestrator.make()
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        sut.appendQueuedMessage(msg("drop-me"), for: 1)
        store.engineState[1] = .done

        controller.handleEngineStateChanged()

        XCTAssertFalse(sut.hasQueuedMessage(for: 1),
                       "handleEngineStateChanged must internally call tryFlushQueuedMessages")
    }

    // MARK: - firstRunningStepRoleID — single source of truth for QuickCapture

    /// Ensures `QuickCaptureModeCoordinator` (title rendering) and
    /// `submitQueuedMessageFromForm` (queue targeting) read the same role.
    /// Regression: any divergence here would silently mis-route queued messages.

    private func makeTaskWithRunningStep(
        roleIDs: [String],
        runningRoleIDs: [String]
    ) -> NTMSTask {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "G")
        task.setStoredChatMode(true)
        var run = Run(id: 0, teamID: "t1")
        for roleID in roleIDs {
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: roleID, name: roleID.capitalized,
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            ))
            step.status = runningRoleIDs.contains(roleID) ? .running : .pending
            run.steps.append(step)
        }
        task.runs.append(run)
        return task
    }

    func testFirstRunningStepRoleID_singleRunning_returnsThatRoleID() {
        let task = makeTaskWithRunningStep(
            roleIDs: ["coding-assistant"],
            runningRoleIDs: ["coding-assistant"]
        )
        XCTAssertEqual(QuickCaptureController.firstRunningStepRoleID(in: task), "coding-assistant")
    }

    func testFirstRunningStepRoleID_multiRoleChat_returnsFirstRunning() {
        // Quest Party-shaped: 5 roles, all running. First wins — same role
        // QuickCapture's title displays.
        let task = makeTaskWithRunningStep(
            roleIDs: ["loremaster", "npc", "encounter", "rules", "quest-master"],
            runningRoleIDs: ["loremaster", "npc", "encounter", "rules", "quest-master"]
        )
        XCTAssertEqual(QuickCaptureController.firstRunningStepRoleID(in: task), "loremaster",
                       "Multi-role chat: first running step in run.steps order picks the recipient")
    }

    func testFirstRunningStepRoleID_someRunningSomeNot_returnsFirstRunning() {
        let task = makeTaskWithRunningStep(
            roleIDs: ["a", "b", "c"],
            runningRoleIDs: ["b", "c"]  // 'a' is .pending
        )
        XCTAssertEqual(QuickCaptureController.firstRunningStepRoleID(in: task), "b",
                       "Skips non-running steps, returns first running in order")
    }

    func testFirstRunningStepRoleID_noRunningStep_returnsNil() {
        let task = makeTaskWithRunningStep(
            roleIDs: ["a", "b"],
            runningRoleIDs: []  // none running — transient race window
        )
        XCTAssertNil(QuickCaptureController.firstRunningStepRoleID(in: task),
                     "Transient state with no running step → nil → submit falls back to Team queue")
    }

    func testFirstRunningStepRoleID_emptyRuns_returnsNil() {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "G")
        task.setStoredChatMode(true)
        XCTAssertNil(QuickCaptureController.firstRunningStepRoleID(in: task))
    }
}
