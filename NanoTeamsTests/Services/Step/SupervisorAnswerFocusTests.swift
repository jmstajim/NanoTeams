import XCTest

@testable import NanoTeams

/// The three decisions both answering surfaces make about a row of waiting questions.
final class SupervisorAnswerFocusTests: XCTestCase {

    private typealias Focus = SupervisorAnswerFocus

    // MARK: - resolve

    func testWithNoPreferenceTheLeadingQuestionIsTheOneOnScreen() {
        XCTAssertEqual(Focus.resolve(preferred: nil, among: ["a", "b", "c"]), "a")
    }

    func testAPreferenceThatIsStillWaitingIsHonoured() {
        XCTAssertEqual(Focus.resolve(preferred: "c", among: ["a", "b", "c"]), "c")
    }

    /// The case the rule exists for: the question this surface was pointing at got answered
    /// somewhere else. Pointing at it anyway renders a question nobody is being asked.
    func testAPreferenceThatStoppedWaitingFallsBackToTheLeadingQuestion() {
        XCTAssertEqual(Focus.resolve(preferred: "gone", among: ["a", "b"]), "a")
    }

    func testNothingWaitingIsNotQuestionZero() {
        XCTAssertNil(Focus.resolve(preferred: nil, among: []))
        XCTAssertNil(Focus.resolve(preferred: "a", among: []),
                     "a stale preference must not conjure a question out of an empty row")
    }

    // MARK: - next

    func testAnsweringTheOnlyQuestionAimsAtNothing() {
        XCTAssertNil(Focus.next(after: "a", among: ["a"]))
    }

    func testTheNextQuestionIsTheOneToTheRight() {
        XCTAssertEqual(Focus.next(after: "b", among: ["a", "b", "c"]), "c")
    }

    /// The whole reason this is not "just take the first one". A Supervisor working left to
    /// right who is bounced back to the question they deliberately skipped skips it again,
    /// and the row never empties.
    func testTheQuestionToTheRightWinsOverTheOneAlreadySkipped() {
        XCTAssertEqual(Focus.next(after: "b", among: ["a", "b", "c"]), "c")
        XCTAssertNotEqual(Focus.next(after: "b", among: ["a", "b", "c"]), "a")
    }

    func testAnsweringTheLastQuestionWrapsToTheLeftmost() {
        XCTAssertEqual(Focus.next(after: "c", among: ["a", "b", "c"]), "a")
    }

    func testWithTwoQuestionsEitherOneLeadsToTheOther() {
        XCTAssertEqual(Focus.next(after: "a", among: ["a", "b"]), "b")
        XCTAssertEqual(Focus.next(after: "b", among: ["a", "b"]), "a")
    }

    /// A second surface answered it first, so the list handed here has already dropped it.
    /// There is no position to measure "next" from, and the leading question is the honest
    /// answer — not nil, which would dismiss a panel with questions still in it.
    func testAQuestionMissingFromTheListStillYieldsTheLeadingOne() {
        XCTAssertEqual(Focus.next(after: "gone", among: ["a", "b"]), "a")
    }

    func testAnEmptyListYieldsNothingToAimAt() {
        XCTAssertNil(Focus.next(after: "a", among: []))
    }

    /// Answering the trailing question of a row whose leader was answered elsewhere in the
    /// same breath: the wrap must land on what is left, not on the vanished leader.
    func testTheWrapLandsOnAQuestionThatIsStillThere() {
        XCTAssertEqual(Focus.next(after: "c", among: ["b", "c"]), "b")
    }

    // MARK: - waitingBadge

    func testTheBadgeSaysNothingUntilThereAreTwoQuestions() {
        XCTAssertNil(Focus.waitingBadge(count: 0))
        XCTAssertNil(Focus.waitingBadge(count: 1),
                     "a badge that can only say `1 waiting` beside one chip is decoration")
    }

    func testTheBadgeCountsFromTwo() {
        XCTAssertEqual(Focus.waitingBadge(count: 2), "2 waiting")
        XCTAssertEqual(Focus.waitingBadge(count: 5), "5 waiting")
    }

    // MARK: - waitingBadgeCount

    func testTheNumericBadgeObeysTheSameThreshold() {
        XCTAssertNil(Focus.waitingBadgeCount(0))
        XCTAssertNil(Focus.waitingBadgeCount(1))
        XCTAssertEqual(Focus.waitingBadgeCount(2), 2)
        XCTAssertEqual(Focus.waitingBadgeCount(7), 7)
    }

    /// The two spellings share one threshold, so they can never disagree about whether a
    /// count is worth showing. RED: give `waitingBadge(count:)` its own `count >= 1` literal
    /// instead of delegating → the two spellings disagree at 1 and this fails.
    func testTheTwoSpellingsAgreeAtEveryCount() {
        for count in 0...6 {
            XCTAssertEqual(Focus.waitingBadge(count: count) == nil,
                           Focus.waitingBadgeCount(count) == nil,
                           "the word badge and the number badge disagree at \(count)")
        }
    }

    /// The sidebar reads its count off an index row, and a row written before the field
    /// knows nothing. Unknown must render as "no number" — never as `0`, which is an
    /// assertion that nobody is waiting.
    func testUnknownCountShowsNoNumber() {
        XCTAssertNil(Focus.waitingBadgeCount(nil))
    }

    /// Guards the one arithmetic mistake this shape invites: a negative count is not
    /// "below the threshold by a lot", it is nonsense — and it must not print.
    func testNegativeCountIsSilent() {
        XCTAssertNil(Focus.waitingBadgeCount(-1))
    }
}
