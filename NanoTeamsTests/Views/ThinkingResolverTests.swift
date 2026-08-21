import XCTest

@testable import NanoTeams

/// `ThinkingResolver` must be EXACTLY `last(where:)` — array-order-last, not
/// max-createdAt — for every input. The oracle is the verbatim production
/// expression the resolver replaced.
final class ThinkingResolverTests: XCTestCase {

    private func message(
        _ role: LLMRole, thinking: String?, at seconds: TimeInterval
    ) -> LLMMessage {
        LLMMessage(
            createdAt: Date(timeIntervalSinceReferenceDate: seconds),
            role: role, content: "c", thinking: thinking)
    }

    private func oracle(_ conversation: [LLMMessage], anchor: Date) -> String? {
        conversation.last(where: {
            $0.role == .assistant && $0.thinking != nil && $0.createdAt <= anchor
        })?.thinking
    }

    /// The load-bearing case: the conversation is OUT of time order (a
    /// re-stamped commit landed a later-created turn at an earlier array
    /// position), so array-order-last and max-createdAt DISAGREE. `last(where:)`
    /// answers "early" — the resolver must too.
    ///
    /// RED: implement the resolver as "max createdAt wins" (drop the prefix
    /// running-max) → it answers "late" and this test fails.
    func testOutOfOrderConversation_arrayOrderWins_notMaxCreatedAt() {
        let conversation = [
            message(.assistant, thinking: "late", at: 100),   // created later, sits EARLIER
            message(.assistant, thinking: "early", at: 50),   // created earlier, sits LATER
        ]
        let anchor = Date(timeIntervalSinceReferenceDate: 200)
        XCTAssertEqual(oracle(conversation, anchor: anchor), "early", "oracle sanity")
        XCTAssertEqual(
            ThinkingResolver(conversation: conversation).thinking(atOrBefore: anchor), "early")
    }

    func testAnchorBeforeEveryTurn_isNil() {
        let conversation = [message(.assistant, thinking: "t", at: 100)]
        XCTAssertNil(ThinkingResolver(conversation: conversation)
            .thinking(atOrBefore: Date(timeIntervalSinceReferenceDate: 50)))
    }

    func testAnchorEqualToCreatedAt_isIncluded() {
        let anchor = Date(timeIntervalSinceReferenceDate: 100)
        let conversation = [message(.assistant, thinking: "t", at: 100)]
        XCTAssertEqual(
            ThinkingResolver(conversation: conversation).thinking(atOrBefore: anchor), "t")
    }

    func testEqualTimestamps_laterArrayIndexWins() {
        let conversation = [
            message(.assistant, thinking: "first", at: 100),
            message(.assistant, thinking: "second", at: 100),
        ]
        XCTAssertEqual(
            ThinkingResolver(conversation: conversation)
                .thinking(atOrBefore: Date(timeIntervalSinceReferenceDate: 100)),
            "second")
    }

    func testNilThinkingAndNonAssistantTurns_areSkipped() {
        let conversation = [
            message(.assistant, thinking: "t", at: 50),
            message(.assistant, thinking: nil, at: 60),
            message(.user, thinking: "not assistant", at: 70),
        ]
        XCTAssertEqual(
            ThinkingResolver(conversation: conversation)
                .thinking(atOrBefore: Date(timeIntervalSinceReferenceDate: 200)),
            "t")
    }

    /// The filter is `thinking != nil`, NOT non-empty — a persisted `""`
    /// matches today and renders; re-binding to an older turn would change what
    /// is on screen.
    func testEmptyStringThinking_isACandidate() {
        let conversation = [
            message(.assistant, thinking: "older", at: 50),
            message(.assistant, thinking: "", at: 60),
        ]
        XCTAssertEqual(
            ThinkingResolver(conversation: conversation)
                .thinking(atOrBefore: Date(timeIntervalSinceReferenceDate: 200)),
            "")
    }

    /// Property parity against the verbatim oracle on deterministic pseudo-random
    /// conversations — shuffled timestamps, duplicate timestamps, nil gaps —
    /// probed at every message's own timestamp plus the extremes.
    func testParity_randomConversations() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % bound
        }

        for trial in 0..<30 {
            var conversation: [LLMMessage] = []
            let n = 1 + next(25)
            for i in 0..<n {
                let role: LLMRole = next(3) == 0 ? .user : .assistant
                let thinking: String? = next(4) == 0 ? nil : "t\(i)"
                conversation.append(message(
                    role, thinking: thinking, at: TimeInterval(next(10) * 10)))
            }
            let resolver = ThinkingResolver(conversation: conversation)
            var anchors = conversation.map(\.createdAt)
            anchors.append(Date(timeIntervalSinceReferenceDate: -1))
            anchors.append(Date(timeIntervalSinceReferenceDate: 10_000))
            for anchor in anchors {
                XCTAssertEqual(
                    resolver.thinking(atOrBefore: anchor),
                    oracle(conversation, anchor: anchor),
                    "parity broke in trial \(trial) at anchor \(anchor.timeIntervalSinceReferenceDate)")
            }
        }
    }
}
