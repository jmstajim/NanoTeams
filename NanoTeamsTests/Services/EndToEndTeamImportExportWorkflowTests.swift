import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **"Export Team to JSON / Import Team from
/// JSON"** — Supervisor wants to share a team configuration with a
/// colleague, or restore a previously-exported team.
///
/// User scenarios covered:
/// 1. Export → file content is decodable as a valid TeamExportFormat.
/// 2. Export → round-trip back to a team preserves name, roles, artifacts.
/// 3. Import through orchestrator's mutateWorkFolder surface — imported
///    team is added to the teams list.
/// 4. Import generates a new human-readable ID (no collisions with
///    existing templates).
/// 5. Import generates fresh role IDs (so two imports of the same JSON
///    don't collide on role.id).
/// 6. Imported team can be set as active.
/// 7. Custom newName is respected at import time.
/// 8. Round-trip through JSON is lossless for prompts + tool IDs.
/// 9. Unsupported version throws an error.
@MainActor
final class EndToEndTeamImportExportWorkflowTests: NTMSOrchestratorTestBase {

    private func anyCustomTeam() -> Team {
        Team(
            id: "my_custom_team",
            name: "My Custom Team",
            templateID: nil,
            systemPromptTemplate: "System template body",
            consultationPromptTemplate: "Consultation template body",
            meetingPromptTemplate: "Meeting template body",
            roles: [
                TeamRoleDefinition(
                    id: "my_custom_team_architect",
                    name: "Architect",
                    prompt: "Design systems",
                    toolIDs: ["read_file", "list_files"],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies(
                        requiredArtifacts: ["Supervisor Task"],
                        producesArtifacts: ["Architecture Doc"]
                    )
                ),
                TeamRoleDefinition(
                    id: "my_custom_team_reviewer",
                    name: "Reviewer",
                    prompt: "Review outputs",
                    toolIDs: ["read_file"],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies(
                        requiredArtifacts: ["Architecture Doc"],
                        producesArtifacts: ["Review Notes"]
                    )
                ),
            ],
            artifacts: [
                TeamArtifact(id: "supervisor_task", name: "Supervisor Task",
                             icon: "person.fill", mimeType: "text/markdown",
                             description: "User brief", isSystemArtifact: true),
                TeamArtifact(id: "architecture_doc", name: "Architecture Doc",
                             icon: "doc.text", mimeType: "text/markdown",
                             description: "High-level design"),
                TeamArtifact(id: "review_notes", name: "Review Notes",
                             icon: "doc.text", mimeType: "text/markdown",
                             description: "QA feedback"),
            ],
            settings: .default,
            graphLayout: .default
        )
    }

    // MARK: - Scenario 1: Export → decodable

    func testExport_producesValidJSON() throws {
        let team = anyCustomTeam()
        let data = try TeamImportExportService.exportTeam(team)
        XCTAssertFalse(data.isEmpty)

        // Decodable as a JSON object
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertNotNil(obj?["version"], "Export must carry a version number")
        XCTAssertNotNil(obj?["team"], "Export must embed the team payload")
    }

    // MARK: - Scenario 2: Round-trip preserves name, prompts, tool IDs

    func testRoundTrip_preservesStructure() throws {
        let original = anyCustomTeam()
        let data = try TeamImportExportService.exportTeam(original)

        let imported = try TeamImportExportService.importTeam(from: data)

        XCTAssertTrue(imported.name.contains("My Custom Team"),
                      "Name preserved (with optional '(Imported)' suffix)")
        XCTAssertEqual(imported.roles.count, original.roles.count)
        XCTAssertEqual(imported.artifacts.count, original.artifacts.count)

        // Prompt templates preserved
        XCTAssertEqual(imported.systemPromptTemplate, "System template body")
        XCTAssertEqual(imported.consultationPromptTemplate, "Consultation template body")
        XCTAssertEqual(imported.meetingPromptTemplate, "Meeting template body")

        // Role-level fields preserved (by matching role name rather than ID —
        // IDs are regenerated at import)
        for originalRole in original.roles {
            guard let importedRole = imported.roles.first(where: { $0.name == originalRole.name })
            else {
                XCTFail("Role \(originalRole.name) missing after round-trip"); continue
            }
            XCTAssertEqual(importedRole.prompt, originalRole.prompt)
            XCTAssertEqual(Set(importedRole.toolIDs), Set(originalRole.toolIDs))
        }
    }

    // MARK: - Scenario 3: Import through orchestrator adds to teams list

    func testImport_viaOrchestrator_addsToTeamsList() async throws {
        await sut.openWorkFolder(tempDir)
        let originalCount = sut.workFolder?.teams.count ?? 0

        let team = anyCustomTeam()
        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data)

        await sut.mutateWorkFolder { proj in proj.addTeam(imported) }

        let newCount = sut.workFolder?.teams.count ?? 0
        XCTAssertEqual(newCount, originalCount + 1,
                       "Imported team must be added to the teams list")
        XCTAssertNotNil(sut.workFolder?.teams.first { $0.id == imported.id })
    }

    // MARK: - Scenario 4: Fresh role IDs on import

    /// Two imports of the same JSON must produce non-colliding role IDs
    /// (if they collided, the second import would overwrite the first's
    /// roles in the graph layout).
    func testImport_twice_producesDistinctTeamIDs() throws {
        let team = anyCustomTeam()
        let data = try TeamImportExportService.exportTeam(team)

        let first = try TeamImportExportService.importTeam(from: data, newName: "Copy One")
        let second = try TeamImportExportService.importTeam(from: data, newName: "Copy Two")

        XCTAssertNotEqual(first.id, second.id,
                          "Two imports with different names must have different team IDs")

        // Each team's roles must have IDs scoped to its team name — no cross-talk
        let firstRoleIDs = Set(first.roles.map(\.id))
        let secondRoleIDs = Set(second.roles.map(\.id))
        XCTAssertTrue(firstRoleIDs.isDisjoint(with: secondRoleIDs),
                      "Two imports must produce disjoint role-ID sets")
    }

    // MARK: - Scenario 5: Imported team can be set as active

    func testImport_canBecomeActiveTeam() async throws {
        await sut.openWorkFolder(tempDir)
        let team = anyCustomTeam()
        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data)

        await sut.mutateWorkFolder { proj in
            proj.addTeam(imported)
            proj.setActiveTeam(imported.id)
        }

        XCTAssertEqual(sut.workFolder?.activeTeamID, imported.id)
        XCTAssertEqual(sut.workFolder?.activeTeam?.id, imported.id)
    }

    // MARK: - Scenario 6: Custom newName

    func testImport_customNewName_isRespected() throws {
        let team = anyCustomTeam()
        let data = try TeamImportExportService.exportTeam(team)

        let imported = try TeamImportExportService.importTeam(from: data,
                                                               newName: "My Renamed Team")
        XCTAssertEqual(imported.name, "My Renamed Team")
        XCTAssertEqual(imported.id, NTMSID.from(name: "My Renamed Team"),
                       "ID derived deterministically from the new name")
    }

    // MARK: - Scenario 7: Team survives full round-trip via orchestrator + reopen

    func testImport_persistsAcrossReopen() async throws {
        await sut.openWorkFolder(tempDir)
        let team = anyCustomTeam()
        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data,
                                                               newName: "Persistent Import")
        await sut.mutateWorkFolder { proj in proj.addTeam(imported) }

        // Reopen
        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)

        XCTAssertNotNil(sut.workFolder?.teams.first { $0.id == imported.id },
                        "Imported team must persist to teams.json and be reloaded")
    }

    // MARK: - Scenario 8: Unsupported version throws

    func testImport_unsupportedVersion_throws() throws {
        let invalidJSON = #"{"version":999,"team":{"id":"x","name":"X","roles":[],"artifacts":[]}}"#
        let data = invalidJSON.data(using: .utf8)!

        XCTAssertThrowsError(try TeamImportExportService.importTeam(from: data)) { error in
            // Any thrown error is fine — we're pinning "it does NOT
            // silently succeed with a corrupted team".
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Scenario 9: Export + re-import preserves role dependency graph

    func testRoundTrip_preservesRoleDependencies() throws {
        let original = anyCustomTeam()
        let data = try TeamImportExportService.exportTeam(original)
        let imported = try TeamImportExportService.importTeam(from: data)

        // Reviewer requires Architecture Doc (produced by Architect).
        // Post-import, the artifact NAMES are preserved — dependency
        // resolution happens by name, not role ID, so downstream roles
        // still find their producers.
        let reviewer = imported.roles.first { $0.name == "Reviewer" }
        XCTAssertEqual(reviewer?.dependencies.requiredArtifacts, ["Architecture Doc"])
        XCTAssertEqual(reviewer?.dependencies.producesArtifacts, ["Review Notes"])

        let architect = imported.roles.first { $0.name == "Architect" }
        XCTAssertEqual(architect?.dependencies.requiredArtifacts, ["Supervisor Task"])
        XCTAssertEqual(architect?.dependencies.producesArtifacts, ["Architecture Doc"])
    }
}
