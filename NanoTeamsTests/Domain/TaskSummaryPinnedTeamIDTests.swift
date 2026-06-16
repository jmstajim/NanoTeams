import XCTest

@testable import NanoTeams

/// Corner-case coverage for the `TaskSummary.pinnedTeamID` field: how
/// `NTMSTask.toSummary()` populates it from `runs.last?.teamID`, and how it
/// round-trips / tolerates missing keys through Codable. Pure value types —
/// sync tests, no orchestrator.
final class TaskSummaryPinnedTeamIDTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - toSummary population

    func testToSummary_noRuns_pinnedTeamIDNil() {
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "x")
        XCTAssertNil(
            task.toSummary().pinnedTeamID,
            "A task with no runs has no pinned team — pinnedTeamID must be nil"
        )
    }

    func testToSummary_singleRunWithTeamID_pinnedToThatID() {
        let run = Run(id: 0, teamID: "team_alpha")
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "x", runs: [run])
        XCTAssertEqual(
            task.toSummary().pinnedTeamID,
            "team_alpha",
            "One run with a teamID → pinnedTeamID mirrors it"
        )
    }

    func testToSummary_multipleRuns_pinnedToLastRunTeamID() {
        let firstRun = Run(id: 0, teamID: "team_X")
        let lastRun = Run(id: 1, teamID: "team_Y")
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "x", runs: [firstRun, lastRun])
        XCTAssertEqual(
            task.toSummary().pinnedTeamID,
            "team_Y",
            "pinnedTeamID reads runs.last — the most recent run's team, not the first"
        )
    }

    func testToSummary_lastRunNilTeamID_pinnedTeamIDNil() {
        let run = Run(id: 0, teamID: nil)
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "x", runs: [run])
        XCTAssertNil(
            task.toSummary().pinnedTeamID,
            "A run whose teamID is nil yields a nil pinnedTeamID"
        )
    }

    // MARK: - Codable round-trip

    func testCodable_nonNilPinnedTeamID_survivesRoundTrip() throws {
        let summary = TaskSummary(id: 5, title: "T", status: .running, pinnedTeamID: "team_persist")
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(summary)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(TaskSummary.self, from: data)
        XCTAssertEqual(
            decoded.pinnedTeamID,
            "team_persist",
            "A non-nil pinnedTeamID must survive encode → decode unchanged"
        )
    }

    // MARK: - Legacy decode (missing key)

    func testLegacyDecode_missingPinnedTeamIDKey_decodesNilWithoutThrow() throws {
        // A tasks_index.json TaskSummary written before the pinnedTeamID field
        // existed — the key is absent entirely. decodeIfPresent must tolerate it.
        let json = """
        {"id":0,"title":"t","status":"running","isChatMode":false}
        """.data(using: .utf8)!
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(TaskSummary.self, from: json)
        XCTAssertNil(
            decoded.pinnedTeamID,
            "A legacy summary with no pinnedTeamID key decodes to nil (decodeIfPresent, no throw)"
        )
    }
}
