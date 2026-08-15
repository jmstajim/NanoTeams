import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **per-task answer-draft persistence**.
///
/// Scenario: the Supervisor is writing an answer to a role's question on
/// Task A, then switches to Task B (which is also waiting for an answer
/// on a different question). The user types a few characters for Task B,
/// then switches back to Task A. Task A's half-written answer must be
/// restored exactly as left — nothing lost, nothing leaked from B.
///
/// Pinned behavior:
/// 1. Enter answer mode for Task A → fresh empty draft.
/// 2. Type text → saved as draft.
/// 3. Switch to Task B via `switchAnswerTask` → A's draft is persisted,
///    B starts fresh.
/// 4. Type text on B → saved as B's draft.
/// 5. Switch back to A → A's draft is restored bit-for-bit.
/// 6. Exit answer mode → draft persists (next enter restores it).
/// 7. Successful submit → `discardAnswerDraft` removes it for good.
/// 8. Non-destructive re-entry: entering answer mode while already in
///    answer mode for the SAME task does NOT clobber the user's
///    supervisorTask (task draft) — only the payload updates.
@MainActor
final class EndToEndAnswerDraftPersistenceTests: XCTestCase {

    private var formState: QuickCaptureFormState!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        formState = QuickCaptureFormState()
    }

    override func tearDown() async throws {
        formState = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func payload(taskID: Int, question: String = "What next?") -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "pm",
            taskID: taskID,
            role: .productManager,
            roleDefinition: nil,
            question: question,
            messageContent: nil,
            thinking: nil,
            isChatMode: false
        )
    }

    // MARK: - Scenario 1: Fresh draft on first entry

    func testEnterAnswerMode_freshTask_emptyInitialFields() {
        formState.supervisorTask = "was typing a new task"

        formState.enterAnswerMode(payload: payload(taskID: 1))

        // In answer mode, supervisorTask is repurposed as the answer field
        // (and the "was typing a new task" is saved for restore on exit).
        XCTAssertEqual(formState.answerText, "",
                       "Fresh task answer draft starts empty")
        XCTAssertTrue(formState.answerAttachments.isEmpty)
        XCTAssertTrue(formState.answerClippedTexts.isEmpty)
    }

    // MARK: - Scenario 2: Draft preserved across task switch

    func testSwitchAnswerTask_preservesTaskADraft_startsTaskBFresh() {
        // Task A: type an answer
        formState.enterAnswerMode(payload: payload(taskID: 1))
        formState.answerText = "Answer for task A — half done"

        // Switch to Task B
        formState.switchAnswerTask(from: 1, to: payload(taskID: 2))

        XCTAssertEqual(formState.answerText, "",
                       "Task B starts with a fresh draft")

        // Switch back to Task A
        formState.switchAnswerTask(from: 2, to: payload(taskID: 1))

        XCTAssertEqual(formState.answerText, "Answer for task A — half done",
                       "Task A's draft is restored bit-for-bit after return")
    }

    // MARK: - Scenario 3: Drafts for both tasks survive round-trip

    func testSwitchAnswerTask_roundTrip_bothDraftsPreserved() {
        formState.enterAnswerMode(payload: payload(taskID: 1))
        formState.answerText = "A draft"
        formState.switchAnswerTask(from: 1, to: payload(taskID: 2))
        formState.answerText = "B draft"
        formState.switchAnswerTask(from: 2, to: payload(taskID: 1))

        XCTAssertEqual(formState.answerText, "A draft")

        formState.switchAnswerTask(from: 1, to: payload(taskID: 2))
        XCTAssertEqual(formState.answerText, "B draft",
                       "Task B draft preserved across A-B-A cycle")
    }

    // MARK: - Scenario 4: Exit answer mode persists draft

    func testExitAnswerMode_draftPersists_forNextEntry() {
        formState.enterAnswerMode(payload: payload(taskID: 42))
        formState.answerText = "In-progress answer"

        formState.exitAnswerMode()

        // Re-enter later for same task
        formState.enterAnswerMode(payload: payload(taskID: 42))

        XCTAssertEqual(formState.answerText, "In-progress answer",
                       "Exit+re-enter must restore the saved draft")
    }

    // MARK: - Scenario 5: Successful submit discards the draft

    func testDiscardAnswerDraft_removesDraft_nextEntryIsFresh() {
        formState.enterAnswerMode(payload: payload(taskID: 7))
        formState.answerText = "Final answer"
        formState.exitAnswerMode()

        // Simulate successful submit
        formState.discardAnswerDraft(taskID: 7)

        formState.enterAnswerMode(payload: payload(taskID: 7))
        XCTAssertEqual(formState.answerText, "",
                       "After discard, re-entry is a fresh draft")
    }

    // MARK: - Scenario 6: Exit restores the OUTER task-creation text

    /// The user was typing a new task, then got an answer request. On exit
    /// from answer mode, the half-typed task-creation text must be restored
    /// (it was saved as `savedSupervisorTask`).
    func testExitAnswerMode_restoresOriginalTaskCreationDraft() {
        formState.supervisorTask = "Draft of a new task"

        formState.enterAnswerMode(payload: payload(taskID: 3))
        formState.answerText = "Typed an answer instead"

        formState.exitAnswerMode()

        XCTAssertEqual(formState.supervisorTask, "Draft of a new task",
                       "Outer task-creation draft restored on exit from answer mode")
    }

    // MARK: - Scenario 7: Non-destructive re-entry (same task)

    /// The system may call `enterAnswerMode` again while we're already in
    /// answer mode for the SAME task — e.g., the panel refresh fires as the
    /// LLM updates its question. The user's current answer text must NOT be
    /// overwritten.
    func testEnterAnswerMode_sameTaskTwice_preservesInProgressAnswer() {
        formState.enterAnswerMode(payload: payload(taskID: 10, question: "First question"))
        formState.answerText = "Partial answer"

        // Re-enter for the SAME task but with a different question (payload updated)
        formState.enterAnswerMode(payload: payload(taskID: 10, question: "Updated question"))

        XCTAssertEqual(formState.answerText, "Partial answer",
                       "Re-entry for same task must preserve in-progress answer text")
    }

    // MARK: - Scenario 8: Task-switch while already in answer mode

    /// User is in answer mode on Task A, user switches to a different task
    /// (Task B) which ALSO needs a supervisor answer. The second
    /// `enterAnswerMode` call with a different taskID must trigger
    /// `switchAnswerTask` — A's draft saved, B loaded.
    func testEnterAnswerMode_differentTaskID_triggersSwitch_draftsIsolated() {
        formState.enterAnswerMode(payload: payload(taskID: 1))
        formState.answerText = "Draft for 1"

        // Second enter with different taskID — state machine delegates to switchAnswerTask
        formState.enterAnswerMode(payload: payload(taskID: 2))

        XCTAssertEqual(formState.answerText, "",
                       "Task 2 starts fresh")

        formState.switchAnswerTask(from: 2, to: payload(taskID: 1))
        XCTAssertEqual(formState.answerText, "Draft for 1",
                       "Task 1's draft was preserved during the implicit switch")
    }

    // MARK: - Scenario 9: Clips preserved per task

    func testSwitchAnswerTask_clipsIsolatedPerTask() {
        formState.enterAnswerMode(payload: payload(taskID: 1))
        formState.answerClippedTexts = ["clip A1", "clip A2"]

        formState.switchAnswerTask(from: 1, to: payload(taskID: 2))
        XCTAssertTrue(formState.answerClippedTexts.isEmpty,
                      "Task 2 starts with no clips")

        formState.answerClippedTexts = ["clip B1"]
        formState.switchAnswerTask(from: 2, to: payload(taskID: 1))

        XCTAssertEqual(formState.answerClippedTexts, ["clip A1", "clip A2"],
                       "Task 1's clips preserved during the switch")
    }

    // MARK: - Scenario 11: Capture / Restore round-trip across chat-working ↔ answer

    /// Mirrors what the controller does at the `.taskWorking` (chat) ↔ `.supervisorAnswer`
    /// boundary: capture live composer fields into the answer draft on entry, restore
    /// from draft on exit. Round-trip must preserve text, attachments, and clips
    /// bit-for-bit — the same parity contract as the existing `enterAnswerMode` path.
    func testCaptureThenRestore_roundTrip_preservesAllThreeFields() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2EDraftTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("attachment.txt", isDirectory: false)
        try "data".write(to: url, atomically: true, encoding: .utf8)
        let attachment = try StagedAttachment(url: url, stagedRelativePath: "draft/attachment.txt")

        formState.answerText = "queued composition"
        formState.answerAttachments = [attachment]
        formState.answerClippedTexts = ["clip-1", "clip-2"]

        formState.captureLiveComposerAsAnswerDraft(taskID: 77)

        // Simulate the post-`exitAnswerMode` cleared state
        formState.answerText = ""
        formState.answerAttachments = []
        formState.answerClippedTexts = []

        formState.restoreAnswerDraftToLiveFields(taskID: 77)

        XCTAssertEqual(formState.answerText, "queued composition")
        XCTAssertEqual(formState.answerAttachments, [attachment])
        XCTAssertEqual(formState.answerClippedTexts, ["clip-1", "clip-2"])
    }

    // MARK: - Scenario 10: a dismissed answer comes back on re-entry

    /// Was written against `clearAnswerSession`, which `dismissPanel` only ever reached
    /// with `pendingAnswer == nil` — so the save it asserted could not fire in production
    /// and the method has been deleted. The round trip it describes is real; it belongs to
    /// the fork that actually runs on an answer-mode dismiss.
    func testDismissedAnswer_comesBackOnReEntry() {
        formState.enterAnswerMode(payload: payload(taskID: 99))
        formState.answerText = "Panel-dismiss draft"
        formState.answerClippedTexts = ["keep me"]

        formState.exitAnswerMode()

        XCTAssertTrue(formState.answerClippedTexts.isEmpty,
                      "Live fields cleared")

        // Re-enter: draft must come back
        formState.enterAnswerMode(payload: payload(taskID: 99))
        XCTAssertEqual(formState.answerText, "Panel-dismiss draft",
                       "Draft was saved before clear — restored on re-entry")
        XCTAssertEqual(formState.answerClippedTexts, ["keep me"],
                       "Clips restored along with text")
    }
}
