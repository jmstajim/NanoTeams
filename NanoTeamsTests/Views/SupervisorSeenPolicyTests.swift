import XCTest
@testable import NanoTeams

/// The decision table that replaced an `onChange(of: TaskStatus?)` closure.
///
/// Two of these cases are the restart bug itself: a cold launch and an active-task
/// switch both used to look like "this task's state changed", and the not-viewing
/// branch then cleared a seen flag that had just been read from disk.
final class SupervisorSeenPolicyTests: XCTestCase {

    private let q1 = UUID()
    private let q2 = UUID()

    // MARK: - Non-transitions must never clear

    /// Cold launch: `activeTaskID` goes nil → T once the async bootstrap lands, and the
    /// app is sitting on the Watchtower. The old code took this for "T just started
    /// waiting while you were elsewhere" and deleted T's persisted seen flag.
    func testColdLaunch_noPreviousObservation_isNoOp() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: nil, current: obs(1, [q1]), isViewing: false)
        XCTAssertEqual(decision, .none)
    }

    func testColdLaunchWhileViewingTheTask_isStillNoOp() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: nil, current: obs(1, [q1]), isViewing: true)
        XCTAssertEqual(decision, .none,
                       "a first observation carries no transition — the open path marks seen")
    }

    /// Switching the active task from A to B changes the observed value wholesale.
    func testTaskSwitch_isNoOpInEveryCombination() {
        for viewing in [true, false] {
            for (before, after) in [([q1], [q2]), ([], [q2]), ([q1], [])] as [([UUID], [UUID])] {
                let decision = SupervisorSeenPolicy.onChange(
                    previous: obs(1, Set(before)), current: obs(2, Set(after)), isViewing: viewing)
                XCTAssertEqual(decision, .none, "switch \(before)->\(after) viewing=\(viewing)")
            }
        }
    }

    func testNilCurrent_isNoOp() {
        XCTAssertEqual(
            SupervisorSeenPolicy.onChange(previous: obs(1, [q1]), current: nil, isViewing: true),
            .none)
    }

    func testUnchangedQuestions_isNoOp() {
        XCTAssertEqual(
            SupervisorSeenPolicy.onChange(
                previous: obs(1, [q1]), current: obs(1, [q1]), isViewing: true),
            .none)
    }

    // MARK: - Genuine transitions

    func testNewQuestionWhileViewing_marksSeenAndDismissesIt() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: obs(1, []), current: obs(1, [q1]), isViewing: true)
        XCTAssertEqual(decision.seen, .mark(taskID: 1))
        XCTAssertEqual(decision.dismissQuestionIDs, [q1])
    }

    func testNewQuestionWhileElsewhere_clearsSeenAndDismissesNothing() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: obs(1, []), current: obs(1, [q1]), isViewing: false)
        XCTAssertEqual(decision.seen, .clear(taskID: 1))
        XCTAssertTrue(decision.dismissQuestionIDs.isEmpty)
    }

    /// In chat mode EVERY assistant turn is another `ask_supervisor` call, so
    /// "waiting → waiting" is the common case, not an edge one. A boolean wait-state
    /// could not see this second reply at all, and it would stay in the inbox forever.
    func testSecondReplyWhileViewing_dismissesOnlyTheNewOne() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: obs(1, [q1]), current: obs(1, [q1, q2]), isViewing: true)
        XCTAssertEqual(decision.seen, .mark(taskID: 1))
        XCTAssertEqual(decision.dismissQuestionIDs, [q2])
    }

    /// One round answered and the next asked inside a single observation window.
    func testAnsweredAndReasked_dismissesTheReplacement() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: obs(1, [q1]), current: obs(1, [q2]), isViewing: true)
        XCTAssertEqual(decision.seen, .mark(taskID: 1))
        XCTAssertEqual(decision.dismissQuestionIDs, [q2])
    }

    func testAnswered_clearsSeenSoTheNextQuestionRelights() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: obs(1, [q1]), current: obs(1, []), isViewing: true)
        XCTAssertEqual(decision.seen, .clear(taskID: 1))
        XCTAssertTrue(decision.dismissQuestionIDs.isEmpty)
    }

    func testStayedQuiet_isNoOp() {
        XCTAssertEqual(
            SupervisorSeenPolicy.onChange(
                previous: obs(1, []), current: obs(1, []), isViewing: false),
            .none)
    }

    // MARK: - Opening a task

    /// Opening returns only a SeenAction: the navigation path retires EVERY banner
    /// of the opened task itself, so a per-question dismiss set here would be an
    /// unwired half — computed, tested, and discarded at the only call site.
    func testOpenWaitingTask_marksSeen() {
        XCTAssertEqual(
            SupervisorSeenPolicy.onOpen(taskID: 4, questionIDs: [q1, q2], isWaiting: true),
            .mark(taskID: 4))
    }

    /// A flag-only escalation is a question with no identity: the ID set is empty
    /// but the task IS asking, and opening it is seeing it. Clearing here would
    /// relight the dot for a question the user is currently reading.
    func testOpenEscalationOnlyTask_marksSeen() {
        XCTAssertEqual(
            SupervisorSeenPolicy.onOpen(taskID: 4, questionIDs: [], isWaiting: true),
            .mark(taskID: 4))
    }

    /// Marking a QUIET task seen freezes its flag: the sweep only clears tasks that are
    /// not waiting, so once it finally asks something the flag is already set and the
    /// sidebar dot never appears for that question.
    func testOpenQuietTask_clearsInsteadOfFreezingTheFlag() {
        XCTAssertEqual(
            SupervisorSeenPolicy.onOpen(taskID: 4, questionIDs: [], isWaiting: false),
            .clear(taskID: 4))
    }

    // MARK: - Flag-only escalation transitions

    /// Drift / refusal-loop caps flip `needsSupervisorInput` without appending an
    /// ask call: waiting rises with no new question ID. The ID-set rules alone read
    /// this as "nothing happened" and the dot never reacts to the escalation.
    func testEscalationWhileViewing_marksSeen() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: obs(1, [], waiting: false),
            current: obs(1, [], waiting: true),
            isViewing: true)
        XCTAssertEqual(decision.seen, .mark(taskID: 1))
        XCTAssertTrue(decision.dismissQuestionIDs.isEmpty,
                      "an identity-less question has no banner key to retire")
    }

    func testEscalationWhileElsewhere_clearsSoTheDotLights() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: obs(1, [], waiting: false),
            current: obs(1, [], waiting: true),
            isViewing: false)
        XCTAssertEqual(decision.seen, .clear(taskID: 1))
    }

    func testEscalationAnswered_waitingDrops_clears() {
        let decision = SupervisorSeenPolicy.onChange(
            previous: obs(1, [], waiting: true),
            current: obs(1, [], waiting: false),
            isViewing: true)
        XCTAssertEqual(decision.seen, .clear(taskID: 1))
    }

    /// `isWaiting` defaults to "has identified questions"; pass it explicitly for
    /// the flag-only escalation shapes, where the task waits with an empty ID set.
    private func obs(
        _ taskID: Int, _ ids: Set<UUID>, waiting: Bool? = nil
    ) -> SupervisorSeenPolicy.Observation {
        SupervisorSeenPolicy.Observation(
            taskID: taskID, questionIDs: ids, isWaiting: waiting ?? !ids.isEmpty)
    }
}
