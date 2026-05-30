import XCTest

@testable import NanoTeams

/// Codable migration + summary propagation for the recurrence/timeout fields
/// added to `NTMSTask` / `TaskSummary` / `Run`.
final class NTMSTaskRecurrenceCodableTests: XCTestCase {

    func testLegacyTaskJSON_withoutNewKeys_decodesWithNilDefaults() throws {
        // A task.json written before this feature — only the always-present keys.
        let json = """
        {"id": 7, "title": "Legacy", "supervisorTask": "do it"}
        """.data(using: .utf8)!
        let task = try JSONCoderFactory.makeDateDecoder().decode(NTMSTask.self, from: json)
        XCTAssertEqual(task.id, 7)
        XCTAssertNil(task.recurrence, "Missing recurrence key → nil (no migration crash)")
        XCTAssertNil(task.runTimeoutSeconds, "Missing timeout key → nil")
    }

    func testRoundTrip_preservesRecurrenceAndTimeout() throws {
        var task = NTMSTask(id: 3, title: "T", supervisorTask: "x")
        task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: Date().addingTimeInterval(3_600))
        task.runTimeoutSeconds = 1_800

        let data = try JSONCoderFactory.makePersistenceEncoder().encode(task)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(NTMSTask.self, from: data)

        XCTAssertEqual(decoded.recurrence?.rule, task.recurrence?.rule)
        XCTAssertEqual(decoded.recurrence?.isEnabled, true)
        XCTAssertEqual(decoded.runTimeoutSeconds, 1_800)
    }

    func testToSummary_propagatesNextFireWhenEnabled() {
        let fire = Date().addingTimeInterval(3_600)
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "x")
        task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: fire)
        XCTAssertEqual(task.toSummary().nextRecurrenceFireAt, fire)
    }

    func testToSummary_nilWhenDisabledOrAbsent() {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "x")
        XCTAssertNil(task.toSummary().nextRecurrenceFireAt, "No recurrence → nil")

        task.recurrence = TaskRecurrence(rule: .interval(seconds: 60), isEnabled: false, nextFireAt: Date().addingTimeInterval(60))
        XCTAssertNil(task.toSummary().nextRecurrenceFireAt, "Disabled recurrence → nil (no sidebar badge)")
    }

    func testRun_timedOutAt_roundTrips() throws {
        let stamp = Date()
        var run = Run(id: 0)
        run.timedOutAt = stamp
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(run)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(Run.self, from: data)
        XCTAssertNotNil(decoded.timedOutAt)
    }

    func testRun_legacyJSON_withoutTimedOutAt_decodesNil() throws {
        let json = """
        {"id": 0, "steps": [], "meetings": [], "changeRequests": [], "consultationChats": {}, "roleStatuses": {}}
        """.data(using: .utf8)!
        let run = try JSONCoderFactory.makeDateDecoder().decode(Run.self, from: json)
        XCTAssertNil(run.timedOutAt)
    }

    func testTaskSummary_nextRecurrenceFireAt_roundTrips() throws {
        // The summary itself must persist the next-fire (not just NTMSTask) — the
        // index is reloaded from disk on app open and the scheduler/sidebar scan it.
        var task = NTMSTask(id: 9, title: "T", supervisorTask: "x")
        task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), isEnabled: true, nextFireAt: Date().addingTimeInterval(3_600))
        let summary = task.toSummary()

        let data = try JSONCoderFactory.makePersistenceEncoder().encode(summary)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(TaskSummary.self, from: data)

        XCTAssertNotNil(decoded.nextRecurrenceFireAt, "TaskSummary persists the next-fire across an app restart")
    }

    func testTaskSummary_noRecurrence_roundTripsNil() throws {
        // encodeIfPresent omits the key; decodeIfPresent defaults nil — a plain
        // task's summary round-trips without a phantom next-fire.
        let summary = NTMSTask(id: 4, title: "Plain", supervisorTask: "x").toSummary()
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(summary)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(TaskSummary.self, from: data)
        XCTAssertNil(decoded.nextRecurrenceFireAt)
    }
}
