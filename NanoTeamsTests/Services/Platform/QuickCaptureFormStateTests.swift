import XCTest

@testable import NanoTeams

/// Direct unit tests for `QuickCaptureFormState` — the answer-mode state machine,
/// submission guards, and draft-content predicates. No controller, no orchestrator.
@MainActor
final class QuickCaptureFormStateTests: XCTestCase {

    var sut: QuickCaptureFormState!

    override func setUp() async throws {
        try await super.setUp()
        sut = QuickCaptureFormState()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makePayload(
        taskID: Int = 0,
        question: String = "Q?",
        isChatMode: Bool = false
    ) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "step_\(taskID)",
            taskID: taskID,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: question,
            messageContent: nil,
            thinking: nil,
            isChatMode: isChatMode
        )
    }

    /// A two-question form, and a payload asking it.
    private var sampleInquiry: SupervisorInquiry {
        SupervisorInquiry(
            headline: "Q?",
            questions: [
                SupervisorInquiryQuestion(
                    id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
                    options: [
                        SupervisorInquiryOption(id: "debug", label: "Debug"),
                        SupervisorInquiryOption(id: "release", label: "Release"),
                    ])
            ])
    }

    private func makeFormPayload(taskID: Int = 0) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "step_\(taskID)", taskID: taskID, role: .softwareEngineer,
            roleDefinition: nil, question: "Q?", inquiry: sampleInquiry,
            messageContent: nil, thinking: nil, isChatMode: false)
    }

    /// A draft holding one decision, given to `sampleInquiry`.
    private func filledForm(_ optionID: String = "debug") -> SupervisorInquiryDraft {
        SupervisorInquiryDraft(
            inquiry: sampleInquiry,
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: [optionID])
            ]))
    }

    /// The branch a `makePayload(taskID:)` question belongs to. These payloads are team-mode
    /// on one role per task, so branch and task move together here.
    private func key(_ taskID: Int) -> AnswerDraftKey {
        QuickCaptureFormState.draftKey(for: makePayload(taskID: taskID))
    }

    // MARK: - Batch pop (popQueuedMessages)

    private func queuedMsg(
        _ text: String, target: String? = nil, id: UUID = UUID()
    ) -> QuickCaptureFormState.QueuedChatMessage {
        QuickCaptureFormState.QueuedChatMessage(
            text: text, attachments: [], clippedTexts: [],
            targetRoleID: target, id: id)!
    }

    /// The result feeds `bodies.joined` — it must carry the CALLER's tier order
    /// (targeted then untargeted), not the queue's arrival order.
    ///
    /// RED: implement the pop as `queue.filter { ids.contains($0.id) }` → the
    /// result comes back in arrival order and the join is reordered.
    func testPopQueuedMessages_returnsInIdsOrder_notQueueOrder() {
        let u1 = queuedMsg("u1"), t1 = queuedMsg("t1", target: "pm")
        let u2 = queuedMsg("u2"), t2 = queuedMsg("t2", target: "pm")
        for m in [u1, t1, u2, t2] { sut.appendQueuedMessage(m, for: 7) }

        let popped = sut.popQueuedMessages(withIDs: [t1.id, t2.id, u1.id, u2.id], for: 7)

        XCTAssertEqual(popped.map(\.text), ["t1", "t2", "u1", "u2"])
    }

    /// `taskIDsWithQueuedMessages` iterates KEYS — a lingering empty array under
    /// the key would wake the backstop on every engine-state change, forever.
    ///
    /// RED: write the survivors back unconditionally (`queuedChatMessages[taskID]
    /// = queue`) → the key survives empty and the assertion fails.
    func testPopQueuedMessages_removesTheDictionaryKeyWhenTheQueueEmpties() {
        let m1 = queuedMsg("a")
        sut.appendQueuedMessage(m1, for: 7)
        _ = sut.popQueuedMessages(withIDs: [m1.id], for: 7)
        XCTAssertFalse(sut.taskIDsWithQueuedMessages.contains(7))
    }

    func testPopQueuedMessages_survivorsKeepRelativeOrder_andUnknownIDsAreSkipped() {
        let a = queuedMsg("a"), b = queuedMsg("b"), c = queuedMsg("c")
        for m in [a, b, c] { sut.appendQueuedMessage(m, for: 7) }
        let popped = sut.popQueuedMessages(withIDs: [b.id, UUID()], for: 7)
        XCTAssertEqual(popped.map(\.text), ["b"])
        XCTAssertEqual(sut.queuedMessages(for: 7).map(\.text), ["a", "c"])
    }

    /// The consumption pipeline's re-queue-on-failure contract, round-tripped
    /// through the batch pop: prepend restores the exact head-of-queue position
    /// ahead of anything that arrived during the failed delivery's await.
    func testPopQueuedMessages_prependRoundTrip_restoresHeadPosition() {
        let a = queuedMsg("a"), b = queuedMsg("b"), late = queuedMsg("late")
        for m in [a, b] { sut.appendQueuedMessage(m, for: 7) }
        let popped = sut.popQueuedMessages(withIDs: [a.id, b.id], for: 7)
        sut.appendQueuedMessage(late, for: 7)
        sut.prependQueuedMessages(popped, for: 7)
        XCTAssertEqual(sut.queuedMessages(for: 7).map(\.text), ["a", "b", "late"])
    }

    // MARK: - Answer Mode Transitions

    /// The answer field starts empty, and the task draft is left exactly where it is. Both
    /// halves used to be one operation: `savedSupervisorTask` stashed the task draft so the
    /// SAME field could carry the answer. The stash is gone with the sharing — see
    /// `QuickCaptureComposerFieldOwnershipCoverageTests` for the routes it never covered.
    func testEnterAnswerMode_startsAFreshAnswerAndLeavesTheTaskDraftAlone() {
        sut.supervisorTask = "My task draft"
        sut.enterAnswerMode(payload: makePayload())

        XCTAssertTrue(sut.isInAnswerMode)
        XCTAssertEqual(sut.answerText, "")
        XCTAssertEqual(sut.supervisorTask, "My task draft")
        XCTAssertNotNil(sut.pendingAnswer)
    }

    func testExitAnswerMode_clearsTheAnswerAndStillLeavesTheTaskDraftAlone() {
        sut.supervisorTask = "Original"
        sut.enterAnswerMode(payload: makePayload())
        sut.answerText = "an answer"
        sut.exitAnswerMode()

        XCTAssertFalse(sut.isInAnswerMode)
        XCTAssertEqual(sut.answerText, "")
        XCTAssertEqual(sut.supervisorTask, "Original")
        XCTAssertNil(sut.pendingAnswer)
    }

    /// Re-entry for the same task is non-destructive: the in-progress answer stays, and the
    /// task draft — which re-entry never had any reason to touch — stays too.
    func testEnterAnswerMode_reentry_keepsBothDrafts() {
        sut.supervisorTask = "User's task draft"
        sut.enterAnswerMode(payload: makePayload(question: "First"))
        XCTAssertEqual(sut.answerText, "")

        // User types an answer, then `enterAnswerMode` fires again for the same task
        sut.answerText = "typing an answer"
        sut.enterAnswerMode(payload: makePayload(question: "Second"))

        XCTAssertEqual(sut.supervisorTask, "User's task draft")
        XCTAssertEqual(sut.pendingAnswer?.question, "Second")
        XCTAssertEqual(sut.answerText, "typing an answer")
    }

    func testUpdateAnswerPayload_updatesPayloadOnly() {
        sut.enterAnswerMode(payload: makePayload(question: "First"))
        sut.updateAnswerPayload(makePayload(question: "Second"))

        XCTAssertTrue(sut.isInAnswerMode)
        XCTAssertEqual(sut.pendingAnswer?.question, "Second")
    }

    // MARK: - Clear Methods

    func testClearTaskDraft_resetsAllTaskFields() {
        sut.title = "t"
        sut.supervisorTask = "g"
        sut.selectedTeamID = "team"
        sut.clippedTexts = [Clip].minting(["clip"])
        let oldDraftID = sut.draftID

        sut.clearTaskDraft()

        XCTAssertTrue(sut.title.isEmpty)
        XCTAssertTrue(sut.supervisorTask.isEmpty)
        XCTAssertNil(sut.selectedTeamID)
        XCTAssertTrue(sut.clippedTexts.isEmpty)
        XCTAssertTrue(sut.attachments.isEmpty)
        XCTAssertNotEqual(sut.draftID, oldDraftID)
    }

    // MARK: - canSubmit(mode:)

    func testCanSubmit_overlayMode_requiresText() {
        XCTAssertFalse(sut.canSubmit(mode: .overlay))
        sut.supervisorTask = "  "
        XCTAssertFalse(sut.canSubmit(mode: .overlay))
        sut.supervisorTask = "Do X"
        XCTAssertTrue(sut.canSubmit(mode: .overlay))
    }

    func testCanSubmit_supervisorAnswer_acceptsTextOrClipsOrAttachments() {
        let mode = QuickCaptureMode.supervisorAnswer(payload: makePayload())

        XCTAssertFalse(sut.canSubmit(mode: mode))

        sut.answerText = "Text answer"
        XCTAssertTrue(sut.canSubmit(mode: mode))

        sut.answerText = ""
        sut.answerClippedTexts = [Clip].minting(["clipped snippet"])
        XCTAssertTrue(sut.canSubmit(mode: mode))
    }

    /// Ticking options and pressing send without typing a word is how a questionnaire is
    /// ordinarily answered — the card IS the answer field there.
    ///
    /// RED: leave `hasAnsweredInquiry` out of the answer branch → the panel shows a filled-in
    /// form beside a dead send button, and nothing on screen says what is missing.
    func testCanSubmit_supervisorAnswer_acceptsAFilledFormWithNoProse() {
        let mode = QuickCaptureMode.supervisorAnswer(payload: makeFormPayload())
        XCTAssertFalse(sut.canSubmit(mode: mode))

        sut.answerInquiry = filledForm()
        XCTAssertTrue(sut.canSubmit(mode: mode))
    }

    /// Opening the "other" field mints an entry that holds nothing. It must not light the send
    /// button, or a click on "Other…" would offer to submit a blank answer.
    func testCanSubmit_supervisorAnswer_refusesAnOpenButBlankField() {
        let mode = QuickCaptureMode.supervisorAnswer(payload: makeFormPayload())
        sut.answerInquiry = SupervisorInquiryDraft(
            inquiry: sampleInquiry,
            answer: SupervisorInquiryAnswer(byQuestionID: ["scheme": .init(freeText: "")]))
        XCTAssertFalse(sut.canSubmit(mode: mode))
    }

    /// The bucket follows the panel across branches that continue one conversation, so the
    /// ticks in hand can belong to a form the role has since replaced with a plain question.
    ///
    /// RED: drop the identity check from `hasAnsweredInquiry` → Send lights over a plain
    /// question with no prose behind it, `submitAnswer` sends an empty answer, and the step is
    /// unparked having been told nothing.
    func testCanSubmit_supervisorAnswer_ignoresAFormTheQuestionIsNotAsking() {
        sut.answerInquiry = filledForm()
        XCTAssertFalse(sut.canSubmit(mode: .supervisorAnswer(payload: makePayload())),
                       "this payload asks a plain question — those ticks answer nothing here")

        let otherForm = SupervisorInquiry(
            headline: "Q?",
            questions: [SupervisorInquiryQuestion(
                id: "scheme", prompt: "Which scheme, really?", kind: .singleChoice,
                options: [SupervisorInquiryOption(id: "debug", label: "Debug")])])
        let otherPayload = SupervisorAnswerPayload(
            stepID: "step_0", taskID: 0, role: .softwareEngineer, roleDefinition: nil,
            question: "Q?", inquiry: otherForm, messageContent: nil, thinking: nil,
            isChatMode: false)
        XCTAssertFalse(sut.canSubmit(mode: .supervisorAnswer(payload: otherPayload)),
                       "same question id, different questionnaire — still not an answer to it")
    }

    /// The chat-working composer binds the same bucket and queues a MESSAGE. A questionnaire
    /// is not one, so it must not enable that send button.
    func testCanSubmit_chatWorking_ignoresAQuestionnaire() {
        sut.answerInquiry = filledForm()
        XCTAssertFalse(sut.canSubmit(mode: .taskWorking(roleName: "SWE", isChatMode: true)))
    }

    /// The answer bucket has FOUR members and they empty together. Three controller sites
    /// spelled the set by hand and each was one field behind the moment it grew a fourth.
    ///
    /// RED: leave any one field out of `clearAnswerFields` → whatever stays behind is parked by
    /// the `exitAnswerMode` that follows, under the branch whose question was just consumed.
    func testClearAnswerFields_emptiesEveryMemberOfTheBucket() {
        sut.answerText = "prose"
        sut.answerClippedTexts = [Clip].minting(["clip"])
        sut.answerInquiry = filledForm()

        sut.clearAnswerFields()

        XCTAssertEqual(sut.answerText, "")
        XCTAssertTrue(sut.answerAttachments.isEmpty)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
        XCTAssertNil(sut.answerInquiry)
    }

    // MARK: - hasTaskDraftContent

    func testHasTaskDraftContent_falseWhenEmpty() {
        XCTAssertFalse(sut.hasTaskDraftContent)
    }

    func testHasTaskDraftContent_ignoresWhitespace() {
        sut.title = "   "
        sut.supervisorTask = "\n\t"
        XCTAssertFalse(sut.hasTaskDraftContent)
    }

    func testHasTaskDraftContent_trueWithGoal() {
        sut.supervisorTask = "Build something"
        XCTAssertTrue(sut.hasTaskDraftContent)
    }

    // MARK: - Per-Task Answer Draft Persistence

    func testExitAnswerMode_savesDraft_reenterRestores() {
        let payload = makePayload(taskID: 1)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "my answer"
        sut.answerClippedTexts = [Clip].minting(["clip A"])

        sut.exitAnswerMode()

        // Draft saved
        XCTAssertEqual(sut.answerDraftStore.peek(for: key(1))?.text, "my answer")
        XCTAssertEqual(sut.answerDraftStore.peek(for: key(1))?.clippedTexts, ["clip A"])

        // Re-enter same task — draft restored
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.answerText, "my answer")
        XCTAssertEqual(sut.answerClippedTexts.texts, ["clip A"])
    }

    func testSwitchAnswerBranch_preservesBothDrafts() {
        let payloadA = makePayload(taskID: 10, question: "Q for A")
        let payloadB = makePayload(taskID: 20, question: "Q for B")

        sut.enterAnswerMode(payload: payloadA)
        sut.answerText = "answer A"
        sut.answerClippedTexts = [Clip].minting(["clip A"])

        // Switch to task B
        sut.updateAnswerPayload(payloadB)
        XCTAssertEqual(sut.answerText, "")
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)

        // Type answer for task B
        sut.answerText = "answer B"
        sut.answerClippedTexts = [Clip].minting(["clip B"])

        // Switch back to task A
        sut.updateAnswerPayload(payloadA)
        XCTAssertEqual(sut.answerText, "answer A")
        XCTAssertEqual(sut.answerClippedTexts.texts, ["clip A"])

        // Switch back to B — still there
        sut.updateAnswerPayload(payloadB)
        XCTAssertEqual(sut.answerText, "answer B")
        XCTAssertEqual(sut.answerClippedTexts.texts, ["clip B"])
    }

    /// `clearAnswerSession` is gone. Its comment claimed "Panel close calls
    /// clearAnswerSession", and that was true of exactly one fork of `dismissPanel` — the
    /// one reached only when `isInAnswerMode` is FALSE, where `pendingAnswer` is nil and
    /// the save these tests exercised could never run. What did run was a bare clear of
    /// the two buckets the chat-working composer renders. The behaviour worth keeping
    /// (a dismissed answer survives per task) belongs to `exitAnswerMode`, pinned below
    /// and by `QuickCaptureChatComposerBucketCoverageTests`.
    ///
    /// RED: drop the `saveCurrentAnswerDraft` call from `exitAnswerMode` → both
    /// assertions fail.
    func testDismissDraftPreservation_movedToExitAnswerMode() {
        let payload = makePayload(taskID: 5)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "draft text"
        sut.answerClippedTexts = [Clip].minting(["clip"])

        sut.exitAnswerMode()

        XCTAssertEqual(sut.answerDraftStore.peek(for: key(5))?.text, "draft text")
        XCTAssertEqual(sut.answerDraftStore.peek(for: key(5))?.clippedTexts, ["clip"])
    }

    func testDiscardAnswerDraft_removesDraft() {
        let payload = makePayload(taskID: 7)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "will be discarded"
        sut.exitAnswerMode()

        XCTAssertNotNil(sut.answerDraftStore.peek(for: key(7)))

        sut.discardAnswerDraft(for: key(7))
        XCTAssertNil(sut.answerDraftStore.peek(for: key(7)))
    }

    func testExitAnswerMode_emptyDraft_notSaved() {
        let payload = makePayload(taskID: 3)
        sut.enterAnswerMode(payload: payload)
        // Don't type anything, leave empty
        sut.exitAnswerMode()

        XCTAssertNil(sut.answerDraftStore.peek(for: key(3)))
    }

    func testDismissAndReopen_preservesDraft() {
        let payload = makePayload(taskID: 42)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "important answer"
        sut.answerClippedTexts = [Clip].minting(["code snippet"])

        // Simulate panel dismiss
        sut.exitAnswerMode()
        XCTAssertFalse(sut.isInAnswerMode)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)

        // Simulate panel reopen on same task
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.answerText, "important answer")
        XCTAssertEqual(sut.answerClippedTexts.texts, ["code snippet"])
    }

    func testSwitchAnswerBranch_newTaskWithNoDraft_startsFresh() {
        let payloadA = makePayload(taskID: 1, question: "Q1")
        let payloadB = makePayload(taskID: 2, question: "Q2")

        sut.enterAnswerMode(payload: payloadA)
        sut.answerText = "answer for A"

        sut.updateAnswerPayload(payloadB)

        // New task has no draft — starts fresh
        XCTAssertEqual(sut.answerText, "")
        XCTAssertTrue(sut.answerAttachments.isEmpty)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
        XCTAssertEqual(sut.pendingAnswer?.taskID, 2)
    }

    // MARK: - Regression: Issue #4 — enterAnswerMode re-entry with different taskID

    func testEnterAnswerMode_reentry_differentTaskID_switchesDrafts() {
        let payloadA = makePayload(taskID: 10, question: "Q for A")
        let payloadB = makePayload(taskID: 20, question: "Q for B")

        sut.enterAnswerMode(payload: payloadA)
        sut.answerText = "answer A"
        sut.answerClippedTexts = [Clip].minting(["clip A"])

        // Re-enter with a different taskID — the guard routes it to `updateAnswerPayload`
        sut.enterAnswerMode(payload: payloadB)

        // Must NOT show stale data from task A
        XCTAssertEqual(sut.answerText, "")
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
        XCTAssertEqual(sut.pendingAnswer?.taskID, 20)

        // Task A draft must be preserved
        XCTAssertEqual(sut.answerDraftStore.peek(for: key(10))?.text, "answer A")
        XCTAssertEqual(sut.answerDraftStore.peek(for: key(10))?.clippedTexts, ["clip A"])
    }

    func testEnterAnswerMode_reentry_sameTaskID_keepsState() {
        let payload1 = makePayload(taskID: 5, question: "Q1")
        let payload2 = makePayload(taskID: 5, question: "Q2")

        sut.enterAnswerMode(payload: payload1)
        sut.answerText = "my answer"
        sut.answerClippedTexts = [Clip].minting(["clip"])

        // Re-enter same taskID with updated question
        sut.enterAnswerMode(payload: payload2)

        // Answer text and clips stay as-is (same task, just payload update)
        XCTAssertEqual(sut.answerText, "my answer")
        XCTAssertEqual(sut.answerClippedTexts.texts, ["clip"])
        XCTAssertEqual(sut.pendingAnswer?.question, "Q2")
    }

    /// Regression: discardAnswerDraft + exitAnswerMode must not re-save stale attachments.
    /// Simulates the controller's submitAnswer() cleanup sequence.
    func testDiscardDraft_clearFields_exitAnswerMode_doesNotResaveDraft() {
        let payload = makePayload(taskID: 42)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "my answer"
        sut.answerClippedTexts = [Clip].minting(["clip"])

        // Simulate controller's post-submit cleanup
        sut.discardAnswerDraft(for: key(42))
        sut.answerText = ""
        sut.answerAttachments = []
        sut.answerClippedTexts = []
        sut.exitAnswerMode()

        // Re-enter for the same task — must start clean
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.answerText, "", "Stale answer text should not reappear")
        XCTAssertTrue(sut.answerAttachments.isEmpty, "Stale attachments should not reappear")
        XCTAssertTrue(sut.answerClippedTexts.isEmpty, "Stale clips should not reappear")
    }

    /// Regression: cancelDraft path — same pattern as submit.
    func testCancelDraft_clearFields_exitAnswerMode_doesNotResaveDraft() {
        let payload = makePayload(taskID: 7)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "partial answer"
        sut.answerClippedTexts = [Clip].minting(["snippet"])

        // Simulate controller's cancelDraft cleanup
        sut.discardAnswerDraft(for: key(7))
        sut.answerText = ""
        sut.answerAttachments = []
        sut.answerClippedTexts = []
        sut.exitAnswerMode()

        // Re-enter — must be clean
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.answerText, "")
        XCTAssertTrue(sut.answerAttachments.isEmpty)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
    }

    func testEnterAnswerMode_reentry_differentTask_thenBackRestoresDraft() {
        let payloadA = makePayload(taskID: 10, question: "QA")
        let payloadB = makePayload(taskID: 20, question: "QB")

        sut.enterAnswerMode(payload: payloadA)
        sut.answerText = "answer A"

        // Switch to B via re-entry
        sut.enterAnswerMode(payload: payloadB)
        sut.answerText = "answer B"

        // Switch back to A via re-entry
        sut.enterAnswerMode(payload: payloadA)
        XCTAssertEqual(sut.answerText, "answer A")

        // Switch back to B
        sut.enterAnswerMode(payload: payloadA)
        // Same task, no switch — stays on A
        XCTAssertEqual(sut.answerText, "answer A")
    }

    // MARK: - Capture / Restore Across Chat-Working ↔ Answer Mode

    private func makeStagedAttachment(name: String) throws -> StagedAttachment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QCFormStateTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try "stub".write(to: url, atomically: true, encoding: .utf8)
        return try StagedAttachment(url: url, stagedRelativePath: "draft/\(name)")
    }

    /// The hand-off parks what does NOT belong where the composer is going — all FOUR
    /// members of the bucket, the questionnaire included.
    ///
    /// RED: drop `inquiry` from `parkLiveAnswerFields` (or from `AnswerDraft`) → the
    /// half-filled form is gone the first time the panel changes branch, which is what the
    /// store's doc comment promises it survives.
    func testHandOff_toAnotherTask_parksEveryMemberOfTheBucket() throws {
        let attachment = try makeStagedAttachment(name: "spec.txt")
        sut.claimAnswerFields(for: .taskChat(42))
        sut.answerText = "queued message"
        sut.answerAttachments = [attachment]
        sut.answerClippedTexts = [Clip].minting(["clip-1"])
        sut.answerInquiry = filledForm()

        sut.handOffLiveAnswerFields(to: .taskChat(43))

        let draft = sut.answerDraftStore.peek(for: .taskChat(42))
        XCTAssertEqual(draft?.text, "queued message")
        XCTAssertEqual(draft?.attachments, [attachment])
        XCTAssertEqual(draft?.clippedTexts, ["clip-1"])
        XCTAssertEqual(draft?.inquiry?.answer.byQuestionID["scheme"]?.selectedOptionIDs, ["debug"])
        XCTAssertNil(sut.answerInquiry, "and the arriving branch starts with a clean form")
    }

    /// The other half: a parked form comes BACK with its prose.
    ///
    /// RED: drop `answerInquiry = draft?.inquiry` from `loadLiveAnswerFields`
    /// → the prose comes back and the questionnaire does not, so the last assertion fails.
    func testHandOff_backAgain_takesTheFormWithTheProse() {
        sut.claimAnswerFields(for: .taskChat(42))
        sut.answerText = "half a sentence"
        sut.answerInquiry = filledForm()

        sut.handOffLiveAnswerFields(to: .taskChat(43))
        sut.handOffLiveAnswerFields(to: .taskChat(42))

        XCTAssertEqual(sut.answerText, "half a sentence")
        XCTAssertEqual(sut.answerInquiry?.answer.byQuestionID["scheme"]?.selectedOptionIDs,
                       ["debug"])
        XCTAssertNil(sut.answerDraftStore.peek(for: .taskChat(42)),
                     "taken, not copied")
    }

    /// A chat task's thread and the question that thread asks are ONE conversation, so the
    /// live fields follow instead of round-tripping through the store.
    ///
    /// RED: make `AnswerDraftKey.continues(into:)` return false for the chat↔role pair → the
    /// text is parked under `.taskChat` and the answer box opens empty, which is exactly the
    /// "my message disappears" report the hand-off machinery exists to close.
    func testHandOff_chatThreadToItsOwnRolesQuestion_movesNothing() {
        sut.claimAnswerFields(for: .taskChat(42))
        sut.answerText = "was writing to the assistant"

        sut.handOffLiveAnswerFields(to: .role(TaskStepKey(taskID: 42, stepID: "assistant")))

        XCTAssertEqual(sut.answerText, "was writing to the assistant")
        XCTAssertTrue(sut.answerDraftStore.keys(forTask: 42).isEmpty,
                      "nothing was parked — the fields were re-labelled, not moved")
        XCTAssertEqual(sut.answerFieldsOwnerKey,
                       .role(TaskStepKey(taskID: 42, stepID: "assistant")))
    }

    /// Two roles of ONE chat task are two conversations. Quest Party has five.
    ///
    /// RED: collapse a chat task's recipients onto `.taskChat(t)` again → the Lore Master's
    /// reply is still in the box when the NPC Creator's question arrives.
    func testHandOff_betweenTwoRolesOfOneChatTask_parksTheFirstReply() {
        let lore = AnswerDraftKey.role(TaskStepKey(taskID: 3, stepID: "lore"))
        let npc = AnswerDraftKey.role(TaskStepKey(taskID: 3, stepID: "npc"))
        sut.claimAnswerFields(for: lore)
        sut.answerText = "for the Lore Master"

        sut.handOffLiveAnswerFields(to: npc)

        XCTAssertEqual(sut.answerText, "", "the NPC Creator's box opens empty")
        XCTAssertEqual(sut.answerDraftStore.peek(for: lore)?.text, "for the Lore Master")
    }

    // MARK: - The unclaimed arrival — the one hand-off with nothing to compare against

    /// `dismissPanel` in answer mode parks under the ROLE that was asking. Reopening onto the
    /// task's chat composer must still put the text back on screen: the thread and the question
    /// asked in it are one conversation, and there is exactly one candidate.
    func testUnclaimedArrival_withOneParkedBranch_takesIt() {
        let assistant = AnswerDraftKey.role(TaskStepKey(taskID: 3, stepID: "assistant"))
        sut.answerDraftStore.save(AnswerDraft(text: "half an answer"), for: assistant)

        sut.restoreAnswerDraftToLiveFields(for: .taskChat(3))

        XCTAssertEqual(sut.answerText, "half an answer")
        XCTAssertTrue(sut.answerDraftStore.keys(forTask: 3).isEmpty, "taken, not copied")
        XCTAssertEqual(sut.answerFieldsOwnerKey, .taskChat(3))
    }

    /// Two roles of one task each holding an unsent reply is a real state (CLAUDE.md #45), and
    /// the chat thread continues BOTH of their conversations. Taking one would be a guess
    /// settled by sort order; both stay parked and the docked composer's rows offer them by
    /// name.
    ///
    /// RED: take `candidates.first` instead of requiring exactly one → the chat box opens
    /// holding the Lore Master's reply because "lore" sorts before "npc".
    func testUnclaimedArrival_withTwoParkedBranches_takesNeither() {
        let lore = AnswerDraftKey.role(TaskStepKey(taskID: 3, stepID: "lore"))
        let npc = AnswerDraftKey.role(TaskStepKey(taskID: 3, stepID: "npc"))
        sut.answerDraftStore.save(AnswerDraft(text: "for the Lore Master"), for: lore)
        sut.answerDraftStore.save(AnswerDraft(text: "for the NPC"), for: npc)

        sut.restoreAnswerDraftToLiveFields(for: .taskChat(3))

        XCTAssertEqual(sut.answerText, "", "neither reply is guessed into the box")
        XCTAssertEqual(sut.answerDraftStore.keys(forTask: 3).count, 2, "both stay parked")
        XCTAssertEqual(sut.answerFieldsOwnerKey, .taskChat(3),
                       "the bucket is claimed either way — the claim is not the load")
    }

    /// Another task's parked reply is not a candidate, however lonely this task's chat thread.
    func testUnclaimedArrival_ignoresAnotherTasksParkedDraft() {
        sut.answerDraftStore.save(AnswerDraft(text: "belongs to task 9"), for: .taskChat(9))

        sut.restoreAnswerDraftToLiveFields(for: .taskChat(3))

        XCTAssertEqual(sut.answerText, "")
        XCTAssertEqual(sut.answerDraftStore.peek(for: .taskChat(9))?.text, "belongs to task 9")
    }

    func testHandOff_emptyContent_leavesNoPhantomDraft() throws {
        let attachment = try makeStagedAttachment(name: "stale.txt")
        // Pre-seed a draft by parking a real one.
        sut.claimAnswerFields(for: .taskChat(99))
        sut.answerText = "stale"
        sut.answerAttachments = [attachment]
        sut.handOffLiveAnswerFields(to: .taskChat(100))
        XCTAssertNotNil(sut.answerDraftStore.peek(for: .taskChat(99)))

        // Come back, empty the fields, leave again — an empty park removes the entry.
        sut.handOffLiveAnswerFields(to: .taskChat(99))
        sut.answerText = "   "
        sut.answerAttachments = []
        sut.answerClippedTexts = []
        sut.handOffLiveAnswerFields(to: .taskChat(100))

        XCTAssertNil(sut.answerDraftStore.peek(for: .taskChat(99)))
    }

    func testRestoreAnswerDraftToLiveFields_loadsSavedDraft() throws {
        let attachment = try makeStagedAttachment(name: "doc.txt")
        sut.answerText = "msg"
        sut.answerAttachments = [attachment]
        sut.answerClippedTexts = [Clip].minting(["c1", "c2"])
        sut.answerDraftStore.save(
            AnswerDraft(text: "msg", attachments: [attachment], clippedTexts: ["c1", "c2"]),
            for: .taskChat(7))

        // Simulate the post-`exitAnswerMode` cleared state
        sut.answerText = ""
        sut.answerAttachments = []
        sut.answerClippedTexts = []

        sut.restoreAnswerDraftToLiveFields(for: .taskChat(7))

        XCTAssertEqual(sut.answerText, "msg")
        XCTAssertEqual(sut.answerAttachments, [attachment])
        XCTAssertEqual(sut.answerClippedTexts.texts, ["c1", "c2"])
        // TAKEN, not read. Leaving the entry behind puts the same reply in the live fields
        // AND in the store — and the store is what the docked composer's parked-draft rows
        // render, so the user would be offered back the text already in front of them.
        //
        // RED: `peek` instead of `take` in `restoreAnswerDraftToLiveFields`.
        XCTAssertNil(sut.answerDraftStore.peek(for: .taskChat(7)),
                     "the store holds nothing under a branch the live fields are holding")
    }

    func testRestoreAnswerDraftToLiveFields_noDraft_isNoOp() {
        sut.answerText = "live"
        sut.answerClippedTexts = [Clip].minting(["c"])

        sut.restoreAnswerDraftToLiveFields(for: .taskChat(1234))

        // Live fields untouched — no draft existed for that taskID
        XCTAssertEqual(sut.answerText, "live")
        XCTAssertEqual(sut.answerClippedTexts.texts, ["c"])
    }

}
