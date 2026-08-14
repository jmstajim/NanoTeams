import XCTest
@testable import NanoTeams

/// Pins `ConversationInformationBoundary` — the committed-history counterpart of
/// `ToolCallTracker.TrackedCall.informationEpoch`. It answers one question for the
/// loop scanners: when did the model last learn something it did not produce itself?
final class ConversationInformationBoundaryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func msg(
        _ context: MessageSourceContext?,
        at offset: TimeInterval,
        role: LLMRole = .user
    ) -> LLMMessage {
        LLMMessage(
            createdAt: t0.addingTimeInterval(offset),
            role: role,
            content: "x",
            sourceContext: context
        )
    }

    // MARK: - Absence

    func testEmptyConversation_hasNoBoundary() {
        XCTAssertNil(ConversationInformationBoundary.lastArrival(in: []))
    }

    /// The initial task brief is a `.user` turn with NO context. It must not open a
    /// boundary: it precedes every tool call in the step, so it could only ever mask,
    /// never rescue.
    func testContextlessTurns_haveNoBoundary() {
        let conversation = [
            msg(nil, at: 0),
            LLMMessage(createdAt: t0.addingTimeInterval(1), role: .assistant, content: "working"),
        ]
        XCTAssertNil(ConversationInformationBoundary.lastArrival(in: conversation))
    }

    /// RED: classify `.retryNudge` / `.loopCorrection` as external information → this
    /// returns a boundary, and every repetition warning would move the detector's own
    /// floor forward past the run it just flagged.
    func testAppSteeringTurnsAlone_haveNoBoundary() {
        let conversation = [
            msg(.retryNudge, at: 1),
            msg(.loopCorrection, at: 2),
            msg(.serverError, at: 3),
        ]
        XCTAssertNil(
            ConversationInformationBoundary.lastArrival(in: conversation),
            "App-authored steering must not reset the detector"
        )
    }

    // MARK: - Selection

    func testSupervisorMessage_opensABoundaryAtItsOwnTimestamp() {
        let conversation = [msg(nil, at: 0), msg(.supervisorMessage, at: 7)]
        XCTAssertEqual(
            ConversationInformationBoundary.lastArrival(in: conversation),
            t0.addingTimeInterval(7)
        )
    }

    /// RED: take `.first` instead of the max → this returns t0+2, and every call made
    /// after the SECOND arrival stays countable against calls made before it.
    func testMultipleArrivals_takesTheMostRecent() {
        let conversation = [
            msg(.supervisorMessage, at: 2),
            msg(.retryNudge, at: 5),
            msg(.supervisorMessage, at: 9),
            msg(nil, at: 11),
        ]
        XCTAssertEqual(
            ConversationInformationBoundary.lastArrival(in: conversation),
            t0.addingTimeInterval(9)
        )
    }

    /// The helper takes any `[LLMMessage]`, so its answer must not depend on the order it
    /// is handed. `llmConversation` is append-ordered today; a caller passing a filtered or
    /// re-sorted slice must still get the true latest arrival.
    ///
    /// RED: replace `.max()` with `.last(where:)` → the shuffled case returns t0+2.
    func testOutOfOrderInput_stillReturnsTheLatestArrival() {
        let conversation = [
            msg(.supervisorMessage, at: 9),
            msg(.supervisorMessage, at: 2),
        ]
        XCTAssertEqual(
            ConversationInformationBoundary.lastArrival(in: conversation),
            t0.addingTimeInterval(9)
        )
    }

    /// Classification is by CONTEXT, not role — every producer writes `.user` today, but
    /// the question is where the content came from, and a role check would silently drop a
    /// future producer that files the same arrival differently.
    func testRoleIsNotTheDiscriminator() {
        let conversation = [msg(.supervisorMessage, at: 4, role: .assistant)]
        XCTAssertEqual(
            ConversationInformationBoundary.lastArrival(in: conversation),
            t0.addingTimeInterval(4)
        )
    }

    // MARK: - The self-immunizing set

    /// The four contexts appended as the ANSWER to a tool call the model made. Each is
    /// stamped strictly AFTER that call in the same conversation, so if any opened a
    /// boundary, a model spinning on that very tool would refresh its own cutoff with every
    /// repeat and the committed scan would never see more than one call.
    ///
    /// RED: flip any of them to `true` in `carriesUnsolicitedInformation` → this fails
    /// naming it, and in production that tool becomes permanently un-detectable.
    func testAnswersToTheModelsOwnCalls_openNoBoundary() {
        for context: MessageSourceContext in [
            .consultation, .meeting, .changeRequest, .supervisorAnswer,
        ] {
            XCTAssertNil(
                ConversationInformationBoundary.lastArrival(in: [msg(context, at: 3)]),
                "\(context.rawValue) is solicited — it must not move the detector's floor"
            )
        }
    }

    /// Stamped into the PARENT's conversation by a delegated CHILD, at a cadence the parent
    /// does not control — they would mask a parent looping on `delegate_to_team`.
    func testDelegationChatter_opensNoBoundary() {
        for context: MessageSourceContext in [.delegatedQuestion, .delegationEscalation] {
            XCTAssertNil(
                ConversationInformationBoundary.lastArrival(in: [msg(context, at: 3)]),
                "\(context.rawValue) arrives on the child's schedule, not as news for this role"
            )
        }
    }

    /// Anti-vacuity: the ONE context that is a boundary must actually be pickable through
    /// the helper, or every negative test above would pass against a predicate stuck at
    /// `false`.
    func testTheBoundaryContext_isPickable() {
        XCTAssertEqual(
            ConversationInformationBoundary.lastArrival(in: [msg(.supervisorMessage, at: 3)]),
            t0.addingTimeInterval(3)
        )
    }
}
