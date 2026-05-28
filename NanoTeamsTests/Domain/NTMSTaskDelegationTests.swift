import XCTest
@testable import NanoTeams

/// Codable back-compat + lifecycle guards for the `parentTaskID` / `parentRoleID` /
/// `delegationDepth` fields added for role-driven team delegation.
@MainActor
final class NTMSTaskDelegationTests: XCTestCase {

    // MARK: - Codable round-trip

    func testRoundTrip_preservesAllDelegationFields() throws {
        let task = NTMSTask(
            id: 7,
            title: "Delegated · Engineering",
            supervisorTask: "Build a calculator",
            parentTaskID: 3,
            parentRoleID: "pm",
            delegationDepth: 2
        )
        let encoded = try JSONCoderFactory.makePersistenceEncoder().encode(task)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(NTMSTask.self, from: encoded)
        XCTAssertEqual(decoded.parentTaskID, 3)
        XCTAssertEqual(decoded.parentRoleID, "pm")
        XCTAssertEqual(decoded.delegationDepth, 2)
    }

    // MARK: - Legacy decode (task.json without delegation fields)

    func testDecode_legacyTaskJSON_defaultsAreSensible() throws {
        // Minimal legacy task.json shape — no parent fields, no delegationDepth.
        let legacyJSON = """
        {
            "id": 1,
            "title": "Legacy",
            "supervisorTask": "Old task",
            "clippedTexts": [],
            "status": "running",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
            "runs": [],
            "attachmentPaths": [],
            "isChatMode": false
        }
        """
        let decoder = JSONCoderFactory.makeDateDecoder()
        let task = try decoder.decode(NTMSTask.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(task.parentTaskID)
        XCTAssertNil(task.parentRoleID)
        XCTAssertEqual(task.delegationDepth, 0, "delegationDepth must default to 0 for legacy tasks")
    }

    // MARK: - TaskSummary

    func testTaskSummary_carriesParentTaskID() {
        let parentTask = NTMSTask(id: 1, title: "Parent", supervisorTask: "")
        let childTask = NTMSTask(
            id: 2,
            title: "Child",
            supervisorTask: "",
            parentTaskID: 1,
            parentRoleID: "pm",
            delegationDepth: 1
        )
        XCTAssertNil(parentTask.toSummary().parentTaskID)
        XCTAssertEqual(childTask.toSummary().parentTaskID, 1)
    }

    func testTaskSummary_legacyDecodeWithoutParentTaskID() throws {
        let legacyJSON = """
        {
            "id": 5,
            "title": "Legacy summary",
            "status": "running",
            "updatedAt": "2026-01-01T00:00:00Z",
            "isChatMode": false
        }
        """
        let summary = try JSONCoderFactory.makeDateDecoder()
            .decode(TaskSummary.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(summary.parentTaskID)
    }

    // MARK: - Depth invariants

    func testMaxDelegationDepth_isThree() {
        XCTAssertEqual(DelegationConstants.maxDelegationDepth, 3,
            "Hard-cap shipped at 3; changing this requires updating tests + handler logic.")
    }

    func testGeneratedTeamSentinel_isFixed() {
        XCTAssertEqual(DelegationConstants.generatedTeamSentinel, "generated")
    }
}
