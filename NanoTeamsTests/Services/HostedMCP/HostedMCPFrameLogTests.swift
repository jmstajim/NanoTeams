import Foundation
import XCTest

@testable import NanoTeams

/// Refusal rate limiting in `HostedMCPFrameLog` (§7.1, §10.2 п.6).
///
/// A refusal reason is spelled `class` or `class:detail`, and the detail is often supplied by
/// the request — a forbidden `Origin` verbatim, a method token. Coalescing keyed on the WHOLE
/// reason let every distinct detail bypass the one-second window and leave a bookkeeping entry
/// behind for good, so an unauthenticated client could grow the log's state without bound.
final class HostedMCPFrameLogTests: XCTestCase {

    private static let base = Date(timeIntervalSince1970: 1_759_971_200)

    private func refuse(
        _ log: HostedMCPFrameLog,
        at offset: TimeInterval,
        agent: AgentIdentity? = nil,
        status: Int,
        reason: String?
    ) {
        log.record(
            timestamp: Self.base.addingTimeInterval(offset),
            agent: agent,
            method: "HTTP",
            statusCode: status,
            durationMs: 0,
            refusalReason: reason,
            agentTextVersion: "test-agent-text-version"
        )
    }

    func testRefusalsCoalesceByReasonClassAndKeepTheFirstDetailVerbatim() {
        let log = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 1)
        for index in 0..<1000 {
            refuse(log, at: 0, status: 403, reason: "forbidden_origin:https://evil-\(index).example")
        }
        XCTAssertEqual(log.entries().map(\.refusalReason), ["forbidden_origin:https://evil-0.example"])
        XCTAssertEqual(log._testTrackedRefusalKeyCount, 1)

        let agent = AgentIdentity(id: UUID(), label: "Claude Code")
        refuse(log, at: 0.5, status: 421, reason: "invalid_host")
        refuse(log, at: 0.5, agent: agent, status: 403, reason: "forbidden_origin:https://agent.example")
        refuse(log, at: 0.5, status: 405, reason: "forbidden_origin:https://other-status.example")
        refuse(log, at: 0.9, status: 403, reason: "forbidden_origin:https://inside-window.example")
        refuse(log, at: 0.9, status: 403, reason: "forbidden_origin")
        refuse(log, at: 1.0, status: 403, reason: "forbidden_origin:https://window-elapsed.example")
        refuse(log, at: 1.0, status: 400, reason: nil)
        refuse(log, at: 1.0, status: 400, reason: nil)
        refuse(log, at: 1.0, status: 200, reason: nil)
        refuse(log, at: 1.0, status: 200, reason: nil)

        XCTAssertEqual(log.entries().map(\.refusalReason), [
            "forbidden_origin:https://evil-0.example",
            "invalid_host",
            "forbidden_origin:https://agent.example",
            "forbidden_origin:https://other-status.example",
            "forbidden_origin:https://window-elapsed.example",
            nil, nil, nil, nil,
        ])
        XCTAssertEqual(log.entries().map(\.statusCode), [403, 421, 403, 405, 403, 400, 400, 200, 200])
        XCTAssertEqual(log.entries()[2].agentID, agent.id)
    }

    func testRefusalBookkeepingStaysBoundedWhenEveryRefusalIsANewClass() {
        let log = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 1)
        for index in 0..<10_000 {
            refuse(log, at: TimeInterval(index) * 2, status: 400, reason: "class_\(index)")
        }
        XCTAssertLessThanOrEqual(log._testTrackedRefusalKeyCount, HostedMCPFrameLog.maxTrackedRefusalKeys)
        XCTAssertEqual(log.entries().count, HostedMCPConstants.frameLogRingCapacity, "every one of them was logged")
        XCTAssertEqual(log.entries().last?.refusalReason, "class_9999")
    }

    func testRefusalBookkeepingStaysBoundedEvenWhileEveryKeyIsInsideItsWindow() {
        let log = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 3600)
        for index in 0..<10_000 {
            refuse(log, at: 0, status: 400, reason: "class_\(index)")
        }
        XCTAssertEqual(log._testTrackedRefusalKeyCount, HostedMCPFrameLog.maxTrackedRefusalKeys)

        // The newest key survived the eviction and still coalesces.
        let countBefore = log.entries().count
        refuse(log, at: 1, status: 400, reason: "class_9999:again")
        XCTAssertEqual(log.entries().count, countBefore)
    }

    func testClearForgetsTheCoalescingState() {
        let log = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 60)
        refuse(log, at: 0, status: 401, reason: "invalid_token")
        refuse(log, at: 1, status: 401, reason: "invalid_token")
        XCTAssertEqual(log.entries().count, 1)

        log.clear()
        XCTAssertEqual(log._testTrackedRefusalKeyCount, 0)
        refuse(log, at: 2, status: 401, reason: "invalid_token")
        XCTAssertEqual(log.entries().map(\.refusalReason), ["invalid_token"])
    }

    func testZeroWindowLogsEveryRefusal() {
        let log = HostedMCPFrameLog(refusalCoalesceWindowSeconds: 0)
        for index in 0..<5 {
            refuse(log, at: 0, status: 403, reason: "forbidden_origin:https://evil-\(index).example")
        }
        XCTAssertEqual(log.entries().count, 5)
        XCTAssertEqual(log._testTrackedRefusalKeyCount, 0)
    }
}
