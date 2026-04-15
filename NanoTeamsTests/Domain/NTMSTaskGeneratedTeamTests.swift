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
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
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

        task.adoptGeneratedTeam(makeTeam(isChatMode: true))
        XCTAssertTrue(task.isChatMode, "Adopted team's isChatMode should drive the observed value")
    }

    /// `setStoredChatMode` is the escape hatch for editing the pre-generation default.
    /// While a generated team is attached, it must not be able to flip the observed
    /// `isChatMode` out from under the generated team.
    func testSetStoredChatMode_isNoOpOnObservedWhileGeneratedAttached() {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G", isChatMode: false)
        task.adoptGeneratedTeam(makeTeam(isChatMode: true))
        XCTAssertTrue(task.isChatMode)

        task.setStoredChatMode(false)
        XCTAssertTrue(task.isChatMode, "Generated team should still dominate after stored override")
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

    /// Regression for the "generated team is treated as chat after Save Team" bug.
    /// The task is created under the Generated Team placeholder (chat-mode stored default),
    /// then adopts a real LLM-generated team with a Supervisor deliverable. Clearing the
    /// transient team — what `saveGeneratedTeam` does — must not snap `isChatMode` back to
    /// the stale creation-time default.
    func testAdoptGeneratedTeam_syncsStoredIsChatMode_soClearRestoresCorrectValue() {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G", isChatMode: true)
        task.adoptGeneratedTeam(makeTeam(isChatMode: false))
        XCTAssertFalse(task.isChatMode, "Generated team dominates while attached")

        task.clearGeneratedTeam()
        XCTAssertFalse(task.isChatMode, "Stored mode should have been synced at adopt time")
    }

    /// Mirror of the above: adopting a chat-mode team over a non-chat stored default
    /// must also survive `clearGeneratedTeam`. Guards against someone "optimizing"
    /// `adoptGeneratedTeam` to skip the sync when `team.isChatMode == storedIsChatMode`
    /// appears redundant — the symmetric path would regress silently.
    func testAdoptGeneratedTeam_syncsStoredIsChatMode_symmetricChatCase() {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G", isChatMode: false)
        task.adoptGeneratedTeam(makeTeam(isChatMode: true))
        XCTAssertTrue(task.isChatMode)

        task.clearGeneratedTeam()
        XCTAssertTrue(task.isChatMode, "Stored mode should have been synced to chat=true at adopt")
    }

    /// `retryTeamGeneration` can call `adoptGeneratedTeam` a second time after a prior
    /// attempt. The last adopted team's `isChatMode` must win on `clearGeneratedTeam`.
    func testAdoptGeneratedTeam_secondAdoptionOverridesFirst() {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G", isChatMode: true)
        task.adoptGeneratedTeam(makeTeam(isChatMode: true))
        task.adoptGeneratedTeam(makeTeam(isChatMode: false))
        XCTAssertFalse(task.isChatMode, "Second adoption's team drives observed")

        task.clearGeneratedTeam()
        XCTAssertFalse(task.isChatMode, "Stored mode should reflect the last adoption, not the first")
    }
}
