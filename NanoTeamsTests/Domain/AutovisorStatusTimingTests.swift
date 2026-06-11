import XCTest
@testable import NanoTeams

/// Pins the pure timing helpers on `AutovisorStatus` that feed `task_status` and the
/// stuck-detector. Their precedence/clamp logic is load-bearing: a regression here
/// silently mis-reports idle/elapsed to the manager LLM or flips a hang verdict.
final class AutovisorStatusTimingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func step(
        createdAt: Date,
        completedAt: Date? = nil,
        status: StepStatus = .running,
        messages: [StepMessage] = [],
        toolCalls: [StepToolCall] = [],
        llm: [LLMMessage] = []
    ) -> StepExecution {
        StepExecution(
            id: "r", role: .codingAgent, title: "r",
            status: status, createdAt: createdAt, updatedAt: createdAt, completedAt: completedAt,
            messages: messages, toolCalls: toolCalls, llmConversation: llm
        )
    }

    // MARK: - lastActivity precedence

    func testLastActivity_picksLatestSource() {
        let s = step(
            createdAt: now.addingTimeInterval(-100),
            messages: [StepMessage(createdAt: now.addingTimeInterval(-40), role: .codingAgent, content: "m")],
            toolCalls: [StepToolCall(createdAt: now.addingTimeInterval(-20), name: "read_file", argumentsJSON: "{}")]
        )
        // Live stream signal is the newest → wins.
        XCTAssertEqual(
            AutovisorStatus.lastActivity(step: s, lastStreamActivityAt: now.addingTimeInterval(-5)),
            now.addingTimeInterval(-5))
        // No live signal → newest persisted (the tool call at -20) wins over message (-40)/createdAt (-100).
        XCTAssertEqual(
            AutovisorStatus.lastActivity(step: s, lastStreamActivityAt: nil),
            now.addingTimeInterval(-20))
    }

    func testLastActivity_ignoresLLMConversation() {
        // A very recent llmConversation entry (pre-created at response START) must NOT
        // count as activity — only finalized `messages` / `toolCalls` do.
        let s = step(
            createdAt: now.addingTimeInterval(-300),
            llm: [LLMMessage(createdAt: now, role: .assistant, content: "")]
        )
        XCTAssertEqual(
            AutovisorStatus.lastActivity(step: s, lastStreamActivityAt: nil),
            now.addingTimeInterval(-300),
            "llmConversation must not float lastActivity to now")
    }

    // MARK: - hasToolInFlight

    func testHasToolInFlight_nilResult_true() {
        let s = step(createdAt: now, toolCalls: [
            StepToolCall(createdAt: now, name: "run_xcodebuild", argumentsJSON: "{}", resultJSON: nil)
        ])
        XCTAssertTrue(AutovisorStatus.hasToolInFlight(step: s))
    }

    func testHasToolInFlight_interimPlaceholderResult_false() {
        // analyze_image / create_team placeholders carry a NON-nil interim resultJSON,
        // so they read as "done" (not in-flight) and must not suppress a hang.
        let s = step(createdAt: now, toolCalls: [
            StepToolCall(createdAt: now, name: "analyze_image", argumentsJSON: "{}",
                         resultJSON: #"{"status":"analyzing"}"#)
        ])
        XCTAssertFalse(AutovisorStatus.hasToolInFlight(step: s))
    }

    func testHasToolInFlight_noCalls_false() {
        XCTAssertFalse(AutovisorStatus.hasToolInFlight(step: step(createdAt: now)))
    }

    // MARK: - roleElapsedSeconds

    func testRoleElapsed_running_usesNow() {
        let s = step(createdAt: now.addingTimeInterval(-90))
        XCTAssertEqual(AutovisorStatus.roleElapsedSeconds(step: s, now: now), 90)
    }

    func testRoleElapsed_done_usesCompletedAt() {
        let s = step(createdAt: now.addingTimeInterval(-90),
                     completedAt: now.addingTimeInterval(-30), status: .done)
        // Frozen at completion (30s before now) → 60s, not 90s.
        XCTAssertEqual(AutovisorStatus.roleElapsedSeconds(step: s, now: now), 60)
    }

    // MARK: - taskElapsedSeconds

    func testTaskElapsed_nilRun_nil() {
        XCTAssertNil(AutovisorStatus.taskElapsedSeconds(run: nil, now: now))
    }

    func testTaskElapsed_usesRunCreatedAt() {
        let run = Run(id: 0, createdAt: now.addingTimeInterval(-120))
        XCTAssertEqual(AutovisorStatus.taskElapsedSeconds(run: run, now: now), 120)
    }
}
