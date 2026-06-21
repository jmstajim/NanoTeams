import XCTest

@testable import NanoTeams

/// Exhaustive truth-table coverage for the two pure boolean policy seams in
/// `TeamActivityFeedView+Logic` — `allowsRoleFallback` and `shouldShowComposer`.
/// Iterates `TeamEngineState.allCases` (+ the `nil` state) so EVERY engine state
/// is asserted, and future-proofs the table against new `TeamEngineState` cases
/// (a new case forces this test to encode its expected policy).
@MainActor
final class TeamActivityFeedPolicyExhaustiveTests: XCTestCase {

    private let closed = Date(timeIntervalSince1970: 0)

    // MARK: - allowsRoleFallback

    /// Non-chat: fallback allowed iff the run is resumable-by-send.
    private let fallbackStates: Set<TeamEngineState> = [.paused, .pending, .failed]

    func testAllowsRoleFallback_chatMode_alwaysTrue_forEveryState() {
        for state in TeamEngineState.allCases {
            XCTAssertTrue(
                TeamActivityFeedView.allowsRoleFallback(isChatMode: true, engineState: state),
                "chat mode must always allow fallback (state=\(state))")
        }
        XCTAssertTrue(TeamActivityFeedView.allowsRoleFallback(isChatMode: true, engineState: nil))
    }

    func testAllowsRoleFallback_nonChat_onlyResumableStates() {
        for state in TeamEngineState.allCases {
            XCTAssertEqual(
                TeamActivityFeedView.allowsRoleFallback(isChatMode: false, engineState: state),
                fallbackStates.contains(state),
                "non-chat fallback policy mismatch for state=\(state)")
        }
        // nil (no engine) is NOT resumable-by-send.
        XCTAssertFalse(TeamActivityFeedView.allowsRoleFallback(isChatMode: false, engineState: nil))
    }

    // MARK: - shouldShowComposer

    func testShouldShowComposer_readOnly_alwaysHidden_forEveryState() {
        for state in TeamEngineState.allCases {
            XCTAssertFalse(
                TeamActivityFeedView.shouldShowComposer(
                    isReadOnly: true, activeTaskID: 1, closedAt: nil,
                    isChatMode: true, engineState: state),
                "read-only must always hide the composer (state=\(state))")
        }
    }

    func testShouldShowComposer_noActiveTask_hidden() {
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: nil, closedAt: nil,
            isChatMode: true, engineState: .running))
    }

    func testShouldShowComposer_closedTask_hidden_forEveryState() {
        for state in TeamEngineState.allCases {
            XCTAssertFalse(
                TeamActivityFeedView.shouldShowComposer(
                    isReadOnly: false, activeTaskID: 1, closedAt: closed,
                    isChatMode: true, engineState: state),
                "a closed task must hide the composer (state=\(state))")
        }
    }

    func testShouldShowComposer_chatModeLive_alwaysShown_forEveryState() {
        for state in TeamEngineState.allCases {
            XCTAssertTrue(
                TeamActivityFeedView.shouldShowComposer(
                    isReadOnly: false, activeTaskID: 1, closedAt: nil,
                    isChatMode: true, engineState: state),
                "live chat task must always show the composer (state=\(state))")
        }
        XCTAssertTrue(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: true, engineState: nil))
    }

    func testShouldShowComposer_nonChatLive_hiddenOnlyOnDoneOrNil() {
        // Non-chat tasks hide the composer only when there's no live run to
        // message: `.done` or no engine (`nil`). `.failed` falls through → shown
        // (sending resumes the run).
        let hiddenStates: Set<TeamEngineState> = [.done]
        for state in TeamEngineState.allCases {
            XCTAssertEqual(
                TeamActivityFeedView.shouldShowComposer(
                    isReadOnly: false, activeTaskID: 1, closedAt: nil,
                    isChatMode: false, engineState: state),
                !hiddenStates.contains(state),
                "non-chat composer policy mismatch for state=\(state)")
        }
        // nil engine → hidden.
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: false, engineState: nil))
    }
}
