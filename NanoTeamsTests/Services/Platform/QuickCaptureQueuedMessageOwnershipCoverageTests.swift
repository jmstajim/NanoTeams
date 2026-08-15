import XCTest

@testable import NanoTeams

/// Box for the awaiter outcome resolved on a spawned handler task.
@MainActor
private final class InterruptOutcomeBox {
    var value: TaskCompletionAwaiter.WaitOutcome?
}

/// Wave 23 — what a queued message OWNS, and what can ride the interrupt channel.
///
/// A queued chat message is a value that outlives the composer that produced it: its
/// attachments keep pointing at `.nanoteams/staged/<draftID>/` while the live form goes on
/// using that same directory. Two lifecycles then collide — the form's cancel/create paths
/// delete the directory, and the delegation-interrupt path drops the queue entry while
/// carrying only its `text` field.
@MainActor
final class QuickCaptureQueuedMessageOwnershipCoverageTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var controller: QuickCaptureController!
    private var workFolder: URL!
    private var outsideDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-own-wf-\(UUID().uuidString)", isDirectory: true)
        outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-own-out-\(UUID().uuidString)", isDirectory: true)
        for dir in [workFolder!, outsideDir!] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
        for dir in [workFolder, outsideDir].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: dir)
        }
        workFolder = nil
        outsideDir = nil
        QuickCaptureController.shared._testReset()
        try await super.tearDown()
    }

    private func makeWired() async -> QuickCaptureController {
        let made = QuickCaptureController(formState: QuickCaptureFormState())
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        made.store = store
        controller = made
        return made
    }

    /// A file OUTSIDE the work folder, so staging makes a real copy under
    /// `.nanoteams/staged/<draftID>/` rather than recording an in-folder reference.
    private func stageOutsideFile(_ name: String, draftID: UUID) throws -> StagedAttachment {
        let src = outsideDir.appendingPathComponent(name)
        try Data("payload".utf8).write(to: src)
        guard let staged = store.stageAttachment(url: src, draftID: draftID) else {
            throw XCTSkip("staging unavailable")
        }
        return staged
    }

    // MARK: - The staged directory a queued message points into

    /// `submitQueuedMessageFromForm` moved the composer's attachments into the queue and
    /// cleared the live fields — but left `draftID` pointing at the very directory those
    /// files live in. `cancelDraft` then deleted it. The queue still held `StagedAttachment`
    /// values naming files that no longer existed, and the failure only surfaced minutes
    /// later, when the drain tried to finalize them.
    ///
    /// The fix is the pattern `clearTaskDraft()` already uses on the task path: rotate the
    /// id at hand-off, so the submitted batch owns its directory and the live composer
    /// starts a fresh one.
    ///
    /// RED: drop the `draftID` rotation from `submitQueuedMessageFromForm` → the two ids
    /// match, `cancelDraft` names the queued message's directory, and the file is gone.
    func testQueueingFromTheForm_handsTheStagedDirectoryToTheMessage() async throws {
        let sut = await makeWired()
        guard let taskID = await store.createTask(title: "T", supervisorTask: "x") else {
            return XCTFail("task creation failed")
        }
        let draftBefore = sut.formState.draftID
        let staged = try stageOutsideFile("shot.png", draftID: draftBefore)
        sut.formState.answerText = "look at this"
        sut.formState.answerAttachments = [staged]

        sut.submitQueuedMessageFromForm()

        XCTAssertTrue(sut.formState.hasQueuedMessage(for: taskID), "precondition")
        XCTAssertNotEqual(sut.formState.draftID, draftBefore,
            "the queued message now owns that staging directory; the live composer needs "
            + "a fresh one or the next cancel deletes files it does not own")
    }

    /// The consequence, end to end: the gesture that deletes the live draft must not reach
    /// inside a message already handed to the queue.
    ///
    /// RED: drop the rotation → `cancelDraft` deletes the queued message's file and this
    /// fails.
    func testCancellingTheLiveDraft_leavesAQueuedMessagesFilesOnDisk() async throws {
        let sut = await makeWired()
        guard let taskID = await store.createTask(title: "T", supervisorTask: "x") else {
            return XCTFail("task creation failed")
        }
        let staged = try stageOutsideFile("evidence.log", draftID: sut.formState.draftID)
        sut.formState.answerText = "look at this"
        sut.formState.answerAttachments = [staged]
        sut.submitQueuedMessageFromForm()
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path), "precondition")

        sut.cancelDraft()

        XCTAssertTrue(sut.formState.hasQueuedMessage(for: taskID),
            "cancelling the live draft is not a retraction of an already-queued message")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path),
            "the queued message still names this file; deleting it turns a pending "
            + "delivery into a finalize failure minutes later, with nothing on screen "
            + "connecting the two")
    }

    /// The rotation must not fire when nothing was queued — an empty payload is rejected by
    /// `QueuedChatMessage.init?`, and rotating there would orphan the staging directory of
    /// a draft the user is still editing.
    ///
    /// RED: rotate unconditionally instead of on the `queued` guard → this fails.
    func testRejectedEmptyMessage_leavesTheLiveDraftDirectoryAlone() async {
        let sut = await makeWired()
        _ = await store.createTask(title: "T", supervisorTask: "x")
        let draftBefore = sut.formState.draftID
        sut.formState.answerText = "   "

        sut.submitQueuedMessageFromForm()

        XCTAssertEqual(sut.formState.draftID, draftBefore,
            "nothing was handed off, so nothing changed owner")
    }

    // MARK: - What can ride the interrupt channel

    /// Seeds a role mid-`delegate_to_team` with a registered awaiter, so
    /// `notifyDelegationInterrupt` has something to wake.
    private func armDelegation(taskID: Int, childID: Int) async -> (Task<Void, Never>, InterruptOutcomeBox) {
        await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "role_a", role: .softwareEngineer, title: "Step",
                activeDelegationChildID: childID))
            task.runs.append(run)
        }
        let box = InterruptOutcomeBox()
        let handler = Task { @MainActor in
            box.value = await self.store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 100 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        return (handler, box)
    }

    /// The interrupt drops the queue entry after waking the role — so whatever it did not
    /// carry is destroyed, and `queueChatMessage` returns `true` regardless. Clips are
    /// text; they can ride, and they were being thrown away.
    ///
    /// RED: pass the bare `text` instead of the composed body → the awaiter receives
    /// "stop it" with no `## Clipped Text` section and this fails.
    func testInterrupt_carriesTheClipsInline() async {
        let sut = await makeWired()
        guard let taskID = await store.createTask(title: "T", supervisorTask: "x") else {
            return XCTFail("task creation failed")
        }
        let (handler, box) = await armDelegation(taskID: taskID, childID: 42)
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: 42), "precondition")

        let queued = sut.queueChatMessage(
            text: "stop it",
            attachments: [],
            clippedTexts: ["the child keeps re-reading the same file"],
            taskID: taskID,
            targetRoleID: "role_a")
        XCTAssertTrue(queued)

        await handler.value
        guard case .parentMessageQueued(let delivered)? = box.value else {
            return XCTFail("handler did not resume with the queued message")
        }
        XCTAssertTrue(delivered.contains("stop it"))
        XCTAssertTrue(delivered.contains("the child keeps re-reading the same file"),
            "the entry is destroyed right after this call, so anything the channel does "
            + "not carry is lost — and clips are text, which it can carry")
        XCTAssertTrue(delivered.contains("## Clipped Text"),
            "composed through the same builder every other submission path uses, so the "
            + "role reads clips in the shape its prompt describes")
        XCTAssertFalse(sut.formState.hasQueuedMessage(for: taskID),
            "unchanged: a delivered interrupt still removes the entry, or the role's next "
            + "iteration would consume the same guidance a second time")
    }

    /// Files cannot ride a `String` into a JSON envelope, and finalizing them here would
    /// start a second lifecycle for the same staged files the queue's own drain finalizes.
    /// So a message carrying attachments does not take the fast path at all: it stays
    /// queued and is delivered whole — late, but complete — instead of being dropped and
    /// reported as delivered.
    ///
    /// RED: drop the `attachments.isEmpty` guard → the interrupt fires, the entry is
    /// removed, and every assertion here fails.
    func testInterrupt_isDeclinedByAMessageCarryingFiles() async throws {
        let sut = await makeWired()
        guard let taskID = await store.createTask(title: "T", supervisorTask: "x") else {
            return XCTFail("task creation failed")
        }
        let (handler, box) = await armDelegation(taskID: taskID, childID: 43)
        let staged = try stageOutsideFile("screenshot.png", draftID: sut.formState.draftID)

        let queued = sut.queueChatMessage(
            text: "stop it, look at this",
            attachments: [staged],
            clippedTexts: [],
            taskID: taskID,
            targetRoleID: "role_a")

        XCTAssertTrue(queued)
        XCTAssertTrue(sut.formState.hasQueuedMessage(for: taskID),
            "kept, so the ordinary drain can deliver text AND files together")
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: 43),
            "the role is still suspended — nothing claimed to have woken it")
        XCTAssertEqual(sut.formState.queuedMessages(for: taskID).first?.attachments, [staged])

        store.completionAwaiter.cancelAll(taskID: 43)
        await handler.value
        if case .parentMessageQueued = box.value {
            XCTFail("the interrupt must not have fired for a message carrying files")
        }
    }

    /// Counter-test: a plain text message still takes the fast path. Without this the
    /// guard above could be widened to "never interrupt" and nothing would notice.
    ///
    /// RED: decline the fast path unconditionally → this fails.
    func testInterrupt_stillFiresForAPlainTextMessage() async {
        let sut = await makeWired()
        guard let taskID = await store.createTask(title: "T", supervisorTask: "x") else {
            return XCTFail("task creation failed")
        }
        let (handler, box) = await armDelegation(taskID: taskID, childID: 44)

        _ = sut.queueChatMessage(
            text: "stop it", attachments: [], clippedTexts: [],
            taskID: taskID, targetRoleID: "role_a")

        await handler.value
        XCTAssertEqual(box.value, .parentMessageQueued(text: "stop it"),
            "text-only is exactly what the channel carries losslessly, and the composed "
            + "body of a clip-less message is the text itself")
        XCTAssertFalse(sut.formState.hasQueuedMessage(for: taskID))
    }
}
