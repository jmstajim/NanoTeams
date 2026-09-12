import XCTest
@testable import NanoTeams

/// The identity of an unsent reply, and the take-and-return store that holds one per branch.
///
/// The suite is organised around the three things the old `[Int: AnswerDraft]` map could not
/// represent: two roles of one task waiting at once (CLAUDE.md #45), the same role id living in
/// two tasks (#5), and a form half-filled beside the prose.
@MainActor
final class SupervisorAnswerDraftStoreTests: XCTestCase {

    var sut: SupervisorAnswerDraftStore!
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        sut = SupervisorAnswerDraftStore()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        sut = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func attachment(named name: String = "spec.txt") throws -> StagedAttachment {
        let url = tempDir.appendingPathComponent(name, isDirectory: false)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return try StagedAttachment(url: url, stagedRelativePath: "draft/\(name)")
    }

    private var sampleInquiry: SupervisorInquiry {
        SupervisorInquiry(
            headline: "Which scheme?",
            questions: [SupervisorInquiryQuestion(
                id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
                options: [SupervisorInquiryOption(id: "debug", label: "Debug")])])
    }

    /// A questionnaire draft is the answers PAIRED with the form they were given to — a set of
    /// ticks alone means nothing beside a different set of questions.
    private func filledForm() -> SupervisorInquiryDraft {
        SupervisorInquiryDraft(
            inquiry: sampleInquiry,
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["debug"])
            ]))
    }

    // MARK: - Key — which branch a draft belongs to

    func testTaskID_isReadableFromEitherShape() {
        XCTAssertEqual(AnswerDraftKey.role(TaskStepKey(taskID: 9, stepID: "pm")).taskID, 9)
        XCTAssertEqual(AnswerDraftKey.taskChat(9).taskID, 9)
    }

    func testRoleID_taskChatAddressesNoRole() {
        XCTAssertEqual(AnswerDraftKey.role(TaskStepKey(taskID: 9, stepID: "pm")).roleID, "pm")
        XCTAssertNil(AnswerDraftKey.taskChat(9).roleID,
                     "A chat branch names the task, not one of the roles talking in it")
    }

    func testSameRoleIDInTwoTasks_areDifferentBranches() {
        // `StepExecution.id == roleID`, so the id string is shared across tasks on one team
        // (CLAUDE.md #5). Keying by role alone would let task 1's draft answer task 2.
        XCTAssertNotEqual(
            AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "engineer")),
            AnswerDraftKey.role(TaskStepKey(taskID: 2, stepID: "engineer")))
    }

    // MARK: - continues(into:) — when the live fields follow instead of being parked

    func testContinues_sameRole_isTheSameConversation() {
        let pm = AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "pm"))
        XCTAssertTrue(pm.continues(into: pm))
    }

    func testContinues_aTasksChatThreadAndAnyOfItsRoles_areOneThread() {
        // Quick Capture binds ONE field for a chat task's working composer and its answer
        // composer. The user was writing to the role that is now asking, so the text follows
        // and nothing is parked — the round trip through the store is what used to lose it.
        let chat = AnswerDraftKey.taskChat(1)
        let lore = AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "lore"))
        XCTAssertTrue(chat.continues(into: lore))
        XCTAssertTrue(lore.continues(into: chat), "and back again when the role stops asking")
    }

    func testContinues_twoRolesOfOneTask_areNotOneConversation() {
        // THE case a task-id comparison got wrong. Parallel roles park at once (CLAUDE.md
        // #45), so answering one elsewhere hands the panel the other's question under the
        // same task id — and the reply written to the PM must not become the TL's.
        let pm = AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "pm"))
        let tl = AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "tl"))
        XCTAssertFalse(pm.continues(into: tl))
        XCTAssertFalse(tl.continues(into: pm))
    }

    func testContinues_differentTasks_never() {
        XCTAssertFalse(AnswerDraftKey.taskChat(1).continues(into: .taskChat(2)))
        XCTAssertFalse(
            AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "pm"))
                .continues(into: .role(TaskStepKey(taskID: 2, stepID: "pm"))),
            "same role id, different task — a reply to task A is not a reply to task B")
        XCTAssertFalse(AnswerDraftKey.taskChat(1)
            .continues(into: .role(TaskStepKey(taskID: 2, stepID: "pm"))))
    }

    // MARK: - Draft — what counts as worth keeping

    func testIsEmpty_whitespaceOnlyText_isEmpty() {
        XCTAssertTrue(AnswerDraft(text: "   \n\t ").isEmpty)
    }

    func testIsEmpty_prose_isNotEmpty() {
        XCTAssertFalse(AnswerDraft(text: "use Debug").isEmpty)
    }

    func testIsEmpty_attachmentWithNoProse_isNotEmpty() throws {
        XCTAssertFalse(AnswerDraft(attachments: [try attachment()]).isEmpty,
                       "A dropped file with no words is still a reply in progress")
    }

    func testIsEmpty_clipWithNoProse_isNotEmpty() {
        XCTAssertFalse(AnswerDraft(clippedTexts: ["pasted"]).isEmpty)
    }

    func testIsEmpty_halfFilledForm_isNotEmpty() {
        XCTAssertFalse(AnswerDraft(inquiry: filledForm()).isEmpty,
                       "One option ticked and nothing typed is exactly the draft this step exists for")
    }

    func testIsEmpty_formOpenedButUndecided_isEmpty() {
        // A card that rendered and was left alone mints an answer with no decisions in it.
        // Counting that as content would park a phantom draft on every question the human read.
        let untouched = SupervisorInquiryDraft(
            inquiry: sampleInquiry,
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: [], freeText: "  ")
            ]))
        XCTAssertTrue(AnswerDraft(inquiry: untouched).isEmpty)
    }

    // MARK: - Store — take and return

    func testSaveThenTake_handsTheDraftBackAndLeavesNothingBehind() {
        let key = AnswerDraftKey.taskChat(1)
        sut.save(AnswerDraft(text: "half a sentence"), for: key)

        XCTAssertEqual(sut.take(for: key)?.text, "half a sentence")
        XCTAssertNil(sut.peek(for: key),
                     "take REMOVES — otherwise the live fields and the store hold it twice")
        XCTAssertEqual(sut._testDraftCount, 0)
    }

    func testSave_emptyDraft_removesTheEntryRatherThanStoringABlank() {
        // RED without the removal arm: emptying the composer and switching away leaves a
        // stored blank, so the chip keeps its "unfinished reply" mark forever.
        let key = AnswerDraftKey.taskChat(1)
        sut.save(AnswerDraft(text: "typed"), for: key)
        sut.save(AnswerDraft(text: "   "), for: key)

        XCTAssertNil(sut.peek(for: key))
        XCTAssertEqual(sut._testDraftCount, 0)
    }

    func testTake_branchWithNoDraft_returnsNil() {
        XCTAssertNil(sut.take(for: .taskChat(42)))
    }

    func testPeek_leavesTheDraftInPlace() {
        let key = AnswerDraftKey.taskChat(1)
        sut.save(AnswerDraft(text: "keep me"), for: key)

        XCTAssertEqual(sut.peek(for: key)?.text, "keep me")
        XCTAssertEqual(sut.peek(for: key)?.text, "keep me", "peek is a read, not a withdrawal")
    }

    func testDiscard_dropsOnlyThatBranch() {
        let mine = AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "pm"))
        let other = AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "tl"))
        sut.save(AnswerDraft(text: "for the PM"), for: mine)
        sut.save(AnswerDraft(text: "for the TL"), for: other)

        sut.discard(for: mine)

        XCTAssertNil(sut.peek(for: mine))
        XCTAssertEqual(sut.peek(for: other)?.text, "for the TL")
    }

    func testFormRidesWithTheProse_throughSaveAndTake() {
        let key = AnswerDraftKey.role(TaskStepKey(taskID: 1, stepID: "planner"))
        sut.save(AnswerDraft(text: "and keep the diff tight", inquiry: filledForm()), for: key)

        let taken = sut.take(for: key)
        XCTAssertEqual(taken?.text, "and keep the diff tight")
        XCTAssertEqual(taken?.inquiry?.answer.byQuestionID["scheme"]?.selectedOptionIDs, ["debug"],
                       "A half-filled questionnaire survives everything the text survives")
    }

    // MARK: - Store — what the per-task map could not represent

    func testTwoRolesOfOneTask_holdIndependentDrafts() {
        // The shape the old `[Int: AnswerDraft]` collapsed: parallel roles park at once
        // (CLAUDE.md #45), and answering one used to overwrite the other's half-typed reply.
        let pm = AnswerDraftKey.role(TaskStepKey(taskID: 5, stepID: "pm"))
        let tl = AnswerDraftKey.role(TaskStepKey(taskID: 5, stepID: "tl"))
        sut.save(AnswerDraft(text: "ship it"), for: pm)
        sut.save(AnswerDraft(text: "rework the plan"), for: tl)

        XCTAssertEqual(sut.peek(for: pm)?.text, "ship it")
        XCTAssertEqual(sut.peek(for: tl)?.text, "rework the plan")
    }

    func testKeys_forTask_listOnlyThatTasksBranches() {
        sut.save(AnswerDraft(text: "a"), for: .role(TaskStepKey(taskID: 1, stepID: "pm")))
        sut.save(AnswerDraft(text: "b"), for: .role(TaskStepKey(taskID: 1, stepID: "tl")))
        sut.save(AnswerDraft(text: "c"), for: .taskChat(2))

        XCTAssertEqual(sut.keys(forTask: 1).count, 2)
        XCTAssertEqual(sut.keys(forTask: 2), [.taskChat(2)])
        XCTAssertEqual(sut.keys(forTask: 3), [])
    }

    func testKeys_areOrderedStablyRatherThanByDictionaryChance() {
        // The parked-draft rows are a `ForEach`; an unspecified `Dictionary.keys` order
        // reshuffles them between body passes.
        sut.save(AnswerDraft(text: "z"), for: .role(TaskStepKey(taskID: 1, stepID: "zeta")))
        sut.save(AnswerDraft(text: "a"), for: .role(TaskStepKey(taskID: 1, stepID: "alpha")))
        sut.save(AnswerDraft(text: "m"), for: .role(TaskStepKey(taskID: 1, stepID: "mu")))

        let expected: [AnswerDraftKey] = [
            .role(TaskStepKey(taskID: 1, stepID: "alpha")),
            .role(TaskStepKey(taskID: 1, stepID: "mu")),
            .role(TaskStepKey(taskID: 1, stepID: "zeta")),
        ]
        XCTAssertEqual(sut.keys(forTask: 1), expected)
        XCTAssertEqual(sut.keys(forTask: 1), expected, "and the same order on the next pass")
    }

    func testAChatTeamWithManyRoles_parksOneDraftPerRole() {
        // Quest Party is a CHAT team with five roles, each with its own step and its own
        // question. An earlier key collapsed every recipient of a chat task onto
        // `.taskChat(t)`, so the second parked reply overwrote the first with no signal but a
        // changed one-line preview.
        //
        // RED: key a chat task's recipients by the task → one entry, "for the NPC" only.
        let lore = AnswerDraftKey.role(TaskStepKey(taskID: 3, stepID: "lore"))
        let npc = AnswerDraftKey.role(TaskStepKey(taskID: 3, stepID: "npc"))
        sut.save(AnswerDraft(text: "for the Lore Master"), for: lore)
        sut.save(AnswerDraft(text: "for the NPC"), for: npc)

        XCTAssertEqual(sut.peek(for: lore)?.text, "for the Lore Master")
        XCTAssertEqual(sut.peek(for: npc)?.text, "for the NPC")
        XCTAssertEqual(sut.keys(forTask: 3).count, 2)
    }

    func testDiscardAll_dropsEveryTask() {
        sut.save(AnswerDraft(text: "a"), for: .taskChat(1))
        sut.save(AnswerDraft(text: "b"), for: .role(TaskStepKey(taskID: 2, stepID: "pm")))

        sut.discardAll()

        XCTAssertEqual(sut._testDraftCount, 0)
    }
}
