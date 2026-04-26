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
        let store = NTMSOrchestrator(repository: NTMSRepository())
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

    func testTryFlush_dropsAllQueuedOnFailed_andSurfacesInfoMessage() async {
        let store = NTMSOrchestrator(repository: NTMSRepository())
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        sut.appendQueuedMessage(msg("a"), for: 7)
        store.engineState[7] = .failed

        controller.tryFlushQueuedMessages()

        XCTAssertFalse(sut.hasQueuedMessage(for: 7))
        XCTAssertEqual(store.lastInfoMessage, "1 queued message(s) discarded — task failed.")
    }

    func testTryFlush_preservesAllQueuedOnRunning() async {
        let store = NTMSOrchestrator(repository: NTMSRepository())
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
        let store = NTMSOrchestrator(repository: NTMSRepository())
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

    // MARK: - Backstop priority-tier picker (pickQueuedMessageForFlush)

    /// Pure-helper tests ensuring the backstop `.needsSupervisorInput` path
    /// uses the same priority tiers as the primary injection path. Without
    /// this alignment, delivery order would diverge based on whether the role
    /// was running vs. paused (review finding I4).

    private func m(_ text: String, target: String? = nil, id: UUID = UUID())
        -> QuickCaptureFormState.QueuedChatMessage
    {
        QuickCaptureFormState.QueuedChatMessage(
            text: text, attachments: [], clippedTexts: [], targetRoleID: target, id: id
        )!
    }

    func testPickForFlush_roleTargeted_winsOverOlderUntargeted() {
        let untargeted = m("team first (older)", target: nil)
        let pmTargeted = m("PM (newer)", target: "pm")

        let pick = QuickCaptureController.pickQueuedMessageForFlush(
            queue: [untargeted, pmTargeted],
            waitingStepRoleIDs: ["pm", "tl"]
        )

        XCTAssertEqual(pick?.messageID, pmTargeted.id,
                       "Role-targeted must pop before untargeted regardless of FIFO order")
        XCTAssertEqual(pick?.stepRoleID, "pm")
    }

    func testPickForFlush_roleTargetedButNotWaiting_skipsToUntargeted() {
        let pmTargeted = m("for PM (not waiting)", target: "pm")
        let untargeted = m("any role", target: nil)

        let pick = QuickCaptureController.pickQueuedMessageForFlush(
            queue: [pmTargeted, untargeted],
            waitingStepRoleIDs: ["tl"] // PM is not in the waiting set
        )

        XCTAssertEqual(pick?.messageID, untargeted.id,
                       "Targeted but non-waiting target falls through to untargeted tier")
        XCTAssertEqual(pick?.stepRoleID, "tl")
    }

    func testPickForFlush_multipleTargeted_picksFirstMatching() {
        let pmA = m("PM A", target: "pm")
        let pmB = m("PM B", target: "pm")
        let tl = m("TL", target: "tl")

        let pick = QuickCaptureController.pickQueuedMessageForFlush(
            queue: [pmA, pmB, tl],
            waitingStepRoleIDs: ["pm", "tl"]
        )

        XCTAssertEqual(pick?.messageID, pmA.id,
                       "Within tier 1, FIFO — oldest role-targeted message wins")
    }

    func testPickForFlush_noWaitingSteps_returnsNil() {
        let pick = QuickCaptureController.pickQueuedMessageForFlush(
            queue: [m("anything", target: nil)],
            waitingStepRoleIDs: []
        )
        XCTAssertNil(pick, "Empty waiting list = nothing to deliver to")
    }

    func testPickForFlush_emptyQueue_returnsNil() {
        let pick = QuickCaptureController.pickQueuedMessageForFlush(
            queue: [],
            waitingStepRoleIDs: ["pm"]
        )
        XCTAssertNil(pick)
    }

    func testPickForFlush_untargetedDelivered_toFirstWaitingRole() {
        let untargeted = m("team", target: nil)

        let pick = QuickCaptureController.pickQueuedMessageForFlush(
            queue: [untargeted],
            waitingStepRoleIDs: ["first", "second", "third"]
        )

        XCTAssertEqual(pick?.stepRoleID, "first",
                       "Untargeted messages route to the first waiting role, preserving caller order")
    }

    func testHandleEngineStateChanged_drivesFlush() async {
        let store = NTMSOrchestrator(repository: NTMSRepository())
        let controller = QuickCaptureController(formState: sut)
        controller.store = store
        sut.appendQueuedMessage(msg("drop-me"), for: 1)
        store.engineState[1] = .done

        controller.handleEngineStateChanged()

        XCTAssertFalse(sut.hasQueuedMessage(for: 1),
                       "handleEngineStateChanged must internally call tryFlushQueuedMessages")
    }
}
