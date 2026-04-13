import XCTest
@testable import NanoTeams

/// Regression guards for the encapsulated `generatedTeam` / `isChatMode` lifecycle
/// on `NTMSTask`, plus Codable back-compat for legacy task.json files written
/// before this PR (no `generatedTeam` / `isChatMode` keys).
@MainActor
final class NTMSTaskGeneratedTeamTests: XCTestCase {

    // MARK: - Helpers

    private func makeTeam(isChatMode: Bool) -> Team {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: isChatMode ? [] : ["Final"],
                producesArtifacts: ["Supervisor Task"]
            )
        )
        return Team(
            id: "t", name: "T", roles: [supervisor], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    // MARK: - isChatMode getter precedence

    func testIsChatMode_storedDefault_whenNoGeneratedTeam() {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G", isChatMode: false)
        XCTAssertFalse(task.isChatMode)
        task.setStoredChatMode(true)
        XCTAssertTrue(task.isChatMode)
    }

    func testIsChatMode_generatedTeamDominates() {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G", isChatMode: false)
        XCTAssertFalse(task.isChatMode)

        // Adopting a chat-mode team flips observed isChatMode without touching the stored value.
        task.adoptGeneratedTeam(makeTeam(isChatMode: true))
        XCTAssertTrue(task.isChatMode)

        // Setter no-ops the observed value while a team is present (the footgun the
        // encapsulation prevents being able to write through carelessly).
        task.setStoredChatMode(false)
        XCTAssertTrue(task.isChatMode, "Generated team's isChatMode should still dominate")

        // Clearing restores the stored default.
        task.clearGeneratedTeam()
        XCTAssertFalse(task.isChatMode)
    }

    // MARK: - Mutators

    func testAdoptGeneratedTeam_setsTeam() {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G")
        XCTAssertNil(task.generatedTeam)
        let team = makeTeam(isChatMode: false)
        task.adoptGeneratedTeam(team)
        XCTAssertEqual(task.generatedTeam?.id, team.id)
    }

    func testClearGeneratedTeam_unsetsTeam() {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G")
        task.adoptGeneratedTeam(makeTeam(isChatMode: false))
        XCTAssertNotNil(task.generatedTeam)
        task.clearGeneratedTeam()
        XCTAssertNil(task.generatedTeam)
    }

    // MARK: - Codable back-compat

    func testDecode_legacyTaskJSON_withoutGeneratedTeamOrIsChatMode() throws {
        // A task.json written before this PR — no `generatedTeam`, no `isChatMode` keys.
        let legacy = """
        {
            "id": 7,
            "title": "Legacy",
            "supervisorTask": "Do work",
            "clippedTexts": [],
            "status": "running",
            "createdAt": 758000000,
            "updatedAt": 758000000,
            "runs": [],
            "attachmentPaths": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let task = try decoder.decode(NTMSTask.self, from: legacy)

        XCTAssertEqual(task.id, 7)
        XCTAssertEqual(task.title, "Legacy")
        XCTAssertNil(task.generatedTeam, "Missing key should default to nil")
        XCTAssertFalse(task.isChatMode, "Missing isChatMode should default to false")
    }

    func testEncodeDecode_preservesGeneratedTeam() throws {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "G")
        task.adoptGeneratedTeam(makeTeam(isChatMode: true))

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(NTMSTask.self, from: data)

        XCTAssertNotNil(decoded.generatedTeam)
        XCTAssertEqual(decoded.generatedTeam?.id, task.generatedTeam?.id)
        XCTAssertTrue(decoded.isChatMode)
    }

    func testEncodeDecode_storedChatMode_persistsAcrossRoundTrip() throws {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "G", isChatMode: true)
        XCTAssertTrue(task.isChatMode)
        task.setStoredChatMode(true)

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(NTMSTask.self, from: data)

        XCTAssertTrue(decoded.isChatMode)
    }
}
