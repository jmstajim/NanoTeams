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

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        formState = QuickCaptureFormState()
    }

    override func tearDown() {
        formState = nil
        super.tearDown()
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
        XCTAssertEqual(formState.supervisorTask, "",
                       "Fresh task answer draft starts empty")
        XCTAssertTrue(formState.answerAttachments.isEmpty)
        XCTAssertTrue(formState.answerClippedTexts.isEmpty)
    }

    // MARK: - Scenario 2: Draft preserved across task switch

    func testSwitchAnswerTask_preservesTaskADraft_startsTaskBFresh() {
        // Task A: type an answer
        formState.enterAnswerMode(payload: payload(taskID: 1))
        formState.supervisorTask = "Answer for task A — half done"

        // Switch to Task B
        formState.switchAnswerTask(from: 1, to: payload(taskID: 2))

        XCTAssertEqual(formState.supervisorTask, "",
                       "Task B starts with a fresh draft")

        // Switch back to Task A
        formState.switchAnswerTask(from: 2, to: payload(taskID: 1))

        XCTAssertEqual(formState.supervisorTask, "Answer for task A — half done",
                       "Task A's draft is restored bit-for-bit after return")
    }

    // MARK: - Scenario 3: Drafts for both tasks survive round-trip

    func testSwitchAnswerTask_roundTrip_bothDraftsPreserved() {
        formState.enterAnswerMode(payload: payload(taskID: 1))
        formState.supervisorTask = "A draft"
        formState.switchAnswerTask(from: 1, to: payload(taskID: 2))
        formState.supervisorTask = "B draft"
        formState.switchAnswerTask(from: 2, to: payload(taskID: 1))

        XCTAssertEqual(formState.supervisorTask, "A draft")

        formState.switchAnswerTask(from: 1, to: payload(taskID: 2))
        XCTAssertEqual(formState.supervisorTask, "B draft",
                       "Task B draft preserved across A-B-A cycle")
    }

    // MARK: - Scenario 4: Exit answer mode persists draft

    func testExitAnswerMode_draftPersists_forNextEntry() {
        formState.enterAnswerMode(payload: payload(taskID: 42))
        formState.supervisorTask = "In-progress answer"

        formState.exitAnswerMode()

        // Re-enter later for same task
        formState.enterAnswerMode(payload: payload(taskID: 42))

        XCTAssertEqual(formState.supervisorTask, "In-progress answer",
                       "Exit+re-enter must restore the saved draft")
    }

    // MARK: - Scenario 5: Successful submit discards the draft

    func testDiscardAnswerDraft_removesDraft_nextEntryIsFresh() {
        formState.enterAnswerMode(payload: payload(taskID: 7))
        formState.supervisorTask = "Final answer"
        formState.exitAnswerMode()

        // Simulate successful submit
        formState.discardAnswerDraft(taskID: 7)

        formState.enterAnswerMode(payload: payload(taskID: 7))
        XCTAssertEqual(formState.supervisorTask, "",
                       "After discard, re-entry is a fresh draft")
    }

    // MARK: - Scenario 6: Exit restores the OUTER task-creation text

    /// The user was typing a new task, then got an answer request. On exit
    /// from answer mode, the half-typed task-creation text must be restored
    /// (it was saved as `savedSupervisorTask`).
    func testExitAnswerMode_restoresOriginalTaskCreationDraft() {
        formState.supervisorTask = "Draft of a new task"

        formState.enterAnswerMode(payload: payload(taskID: 3))
        formState.supervisorTask = "Typed an answer instead"

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
        formState.supervisorTask = "Partial answer"

        // Re-enter for the SAME task but with a different question (payload updated)
        formState.enterAnswerMode(payload: payload(taskID: 10, question: "Updated question"))

        XCTAssertEqual(formState.supervisorTask, "Partial answer",
                       "Re-entry for same task must preserve in-progress answer text")
    }

    // MARK: - Scenario 8: Task-switch while already in answer mode

    /// User is in answer mode on Task A, user switches to a different task
    /// (Task B) which ALSO needs a supervisor answer. The second
    /// `enterAnswerMode` call with a different taskID must trigger
    /// `switchAnswerTask` — A's draft saved, B loaded.
    func testEnterAnswerMode_differentTaskID_triggersSwitch_draftsIsolated() {
        formState.enterAnswerMode(payload: payload(taskID: 1))
        formState.supervisorTask = "Draft for 1"

        // Second enter with different taskID — state machine delegates to switchAnswerTask
        formState.enterAnswerMode(payload: payload(taskID: 2))

        XCTAssertEqual(formState.supervisorTask, "",
                       "Task 2 starts fresh")

        formState.switchAnswerTask(from: 2, to: payload(taskID: 1))
        XCTAssertEqual(formState.supervisorTask, "Draft for 1",
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

    // MARK: - Scenario 10: clearAnswerSession saves draft (not a destructive clear)

    func testClearAnswerSession_savesDraft_fieldsCleared() {
        formState.enterAnswerMode(payload: payload(taskID: 99))
        formState.supervisorTask = "Panel-dismiss draft"
        formState.answerClippedTexts = ["keep me"]

        formState.clearAnswerSession()

        XCTAssertTrue(formState.answerClippedTexts.isEmpty,
                      "Session fields cleared")

        // Re-enter: draft must come back
        formState.enterAnswerMode(payload: payload(taskID: 99))
        XCTAssertEqual(formState.supervisorTask, "Panel-dismiss draft",
                       "Draft was saved before clear — restored on re-entry")
        XCTAssertEqual(formState.answerClippedTexts, ["keep me"],
                       "Clips restored along with text")
    }
}
