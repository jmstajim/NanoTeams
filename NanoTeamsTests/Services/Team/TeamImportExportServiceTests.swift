import XCTest
@testable import NanoTeams

final class TeamImportExportServiceTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Role Export/Import

    func testExportRole_roundTrip_preservesData() throws {
        let role = TeamRoleDefinition(
            id: "test_backend_engineer",
            name: "Backend Engineer",
            prompt: "You build server-side APIs.",
            toolIDs: ["read_file", "write_file", "git_status"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Implementation Plan"],
                producesArtifacts: ["Engineering Notes"]
            ),
            isSystemRole: true,
            systemRoleID: "softwareEngineer"
        )

        let data = try TeamImportExportService.exportRole(role)
        XCTAssertFalse(data.isEmpty)

        // Decode the export format to verify structure
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportFormat = try decoder.decode(RoleExportFormat.self, from: data)

        XCTAssertEqual(exportFormat.version, 1)
        XCTAssertEqual(exportFormat.role.name, "Backend Engineer")
        XCTAssertEqual(exportFormat.role.prompt, "You build server-side APIs.")
        XCTAssertEqual(exportFormat.role.toolIDs, ["read_file", "write_file", "git_status"])
        XCTAssertTrue(exportFormat.role.usePlanningPhase)
        XCTAssertEqual(exportFormat.role.dependencies.requiredArtifacts, ["Implementation Plan"])
        XCTAssertEqual(exportFormat.role.dependencies.producesArtifacts, ["Engineering Notes"])
        XCTAssertTrue(exportFormat.role.isSystemRole)
        XCTAssertEqual(exportFormat.role.systemRoleID, "softwareEngineer")
    }

    func testImportRole_generatesNewID() throws {
        let originalID = "original-role-id-123"
        let role = TeamRoleDefinition(
            id: originalID,
            name: "Test Role",
            prompt: "A test role.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )

        let data = try TeamImportExportService.exportRole(role)
        var team = Team(name: "Test Team")

        try TeamImportExportService.importRole(from: data, into: &team)

        XCTAssertEqual(team.roles.count, 1)
        XCTAssertNotEqual(team.roles[0].id, originalID)
        XCTAssertFalse(team.roles[0].id.isEmpty)
    }

    func testImportRole_setsIsSystemRoleFalse() throws {
        let role = TeamRoleDefinition(
            id: "test_system_role",
            name: "System Role",
            prompt: "A system role.",
            toolIDs: ["read_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(),
            isSystemRole: true,
            systemRoleID: "productManager"
        )

        let data = try TeamImportExportService.exportRole(role)
        var team = Team(name: "Test Team")

        try TeamImportExportService.importRole(from: data, into: &team)

        XCTAssertEqual(team.roles.count, 1)
        XCTAssertFalse(team.roles[0].isSystemRole)
        XCTAssertNil(team.roles[0].systemRoleID)
    }

    func testImportRole_nameConflict_addsSuffix() throws {
        let existingRole = TeamRoleDefinition(
            id: "test_designer",
            name: "Designer",
            prompt: "Existing designer.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        var team = Team(name: "Test Team")
        team.roles.append(existingRole)

        let importedRole = TeamRoleDefinition(
            id: "test_designer_imported",
            name: "Designer",
            prompt: "Imported designer.",
            toolIDs: ["read_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies()
        )
        let data = try TeamImportExportService.exportRole(importedRole)

        try TeamImportExportService.importRole(from: data, into: &team)

        XCTAssertEqual(team.roles.count, 2)
        XCTAssertEqual(team.roles[0].name, "Designer")
        XCTAssertEqual(team.roles[1].name, "Designer (Imported)")
    }

    func testImportRole_noConflict_keepsName() throws {
        var team = Team(name: "Test Team")

        let role = TeamRoleDefinition(
            id: "test_unique_role",
            name: "Unique Role",
            prompt: "A unique role.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let data = try TeamImportExportService.exportRole(role)

        try TeamImportExportService.importRole(from: data, into: &team)

        XCTAssertEqual(team.roles.count, 1)
        XCTAssertEqual(team.roles[0].name, "Unique Role")
    }

    func testImportRole_unsupportedVersion_throws() throws {
        // Manually craft JSON with version 99
        let json: [String: Any] = [
            "version": 99,
            "role": [
                "id": UUID().uuidString,
                "name": "Bad Role",
                "prompt": "Prompt",
                "toolIDs": [] as [String],
                "usePlanningPhase": false,
                "dependencies": [
                    "requiredArtifacts": [] as [String],
                    "producesArtifacts": [] as [String]
                ],
                "isSystemRole": false
            ],
            "exportedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        var team = Team(name: "Test Team")

        XCTAssertThrowsError(try TeamImportExportService.importRole(from: data, into: &team)) { error in
            guard case ImportExportError.unsupportedVersion(let version) = error else {
                XCTFail("Expected unsupportedVersion error, got \(error)")
                return
            }
            XCTAssertEqual(version, 99)
        }
    }

    // MARK: - Artifact Export/Import

    func testExportArtifact_roundTrip_preservesData() throws {
        let artifact = TeamArtifact(
            id: "test_api_specification",
            name: "API Specification",
            icon: "doc.badge.gearshape",
            mimeType: "application/json",
            description: "OpenAPI specification document",
            isSystemArtifact: true,
            systemArtifactName: "API Specification"
        )

        let data = try TeamImportExportService.exportArtifact(artifact)
        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportFormat = try decoder.decode(ArtifactExportFormat.self, from: data)

        XCTAssertEqual(exportFormat.version, 1)
        XCTAssertEqual(exportFormat.artifact.name, "API Specification")
        XCTAssertEqual(exportFormat.artifact.icon, "doc.badge.gearshape")
        XCTAssertEqual(exportFormat.artifact.mimeType, "application/json")
        XCTAssertEqual(exportFormat.artifact.description, "OpenAPI specification document")
        XCTAssertTrue(exportFormat.artifact.isSystemArtifact)
        XCTAssertEqual(exportFormat.artifact.systemArtifactName, "API Specification")
    }

    func testImportArtifact_generatesNewIDFromName() throws {
        let artifact = TeamArtifact(
            id: "original-artifact-id",
            name: "Design Spec",
            icon: "paintbrush",
            mimeType: "text/markdown",
            description: "Design specification"
        )

        let data = try TeamImportExportService.exportArtifact(artifact)
        var team = Team(name: "Test Team")

        try TeamImportExportService.importArtifact(from: data, into: &team)

        XCTAssertEqual(team.artifacts.count, 1)
        // ID should be slugified from the name, not the original ID
        XCTAssertEqual(team.artifacts[0].id, Artifact.slugify("Design Spec"))
        XCTAssertNotEqual(team.artifacts[0].id, "original-artifact-id")
    }

    func testImportArtifact_nameConflict_addsSuffix() throws {
        let existingArtifact = TeamArtifact(
            id: "test_product_requirements",
            name: "Product Requirements",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "Existing requirements"
        )
        var team = Team(name: "Test Team")
        team.artifacts.append(existingArtifact)

        let importedArtifact = TeamArtifact(
            id: "test_product_requirements_imported",
            name: "Product Requirements",
            icon: "doc.fill",
            mimeType: "text/markdown",
            description: "Imported requirements"
        )
        let data = try TeamImportExportService.exportArtifact(importedArtifact)

        try TeamImportExportService.importArtifact(from: data, into: &team)

        XCTAssertEqual(team.artifacts.count, 2)
        XCTAssertEqual(team.artifacts[0].name, "Product Requirements")
        XCTAssertEqual(team.artifacts[1].name, "Product Requirements (Imported)")
        // ID should be slugified from the renamed name
        XCTAssertEqual(team.artifacts[1].id, Artifact.slugify("Product Requirements (Imported)"))
    }

    func testImportArtifact_setsIsSystemArtifactFalse() throws {
        let artifact = TeamArtifact(
            id: "test_system_artifact",
            name: "System Artifact",
            icon: "gear",
            mimeType: "text/plain",
            description: "A system artifact",
            isSystemArtifact: true,
            systemArtifactName: "System Artifact"
        )

        let data = try TeamImportExportService.exportArtifact(artifact)
        var team = Team(name: "Test Team")

        try TeamImportExportService.importArtifact(from: data, into: &team)

        XCTAssertEqual(team.artifacts.count, 1)
        XCTAssertFalse(team.artifacts[0].isSystemArtifact)
        XCTAssertNil(team.artifacts[0].systemArtifactName)
    }

    // MARK: - Team Export/Import

    func testExportTeam_roundTrip_preservesName() throws {
        let role = TeamRoleDefinition(
            id: "test_engineer",
            name: "Engineer",
            prompt: "Build software.",
            toolIDs: ["read_file"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Engineering Notes"]
            )
        )
        var team = Team(name: "My Custom Team")
        team.roles.append(role)

        let data = try TeamImportExportService.exportTeam(team)
        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportFormat = try decoder.decode(TeamExportFormat.self, from: data)

        XCTAssertEqual(exportFormat.version, 1)
        XCTAssertEqual(exportFormat.team.name, "My Custom Team")
        XCTAssertEqual(exportFormat.team.roles.count, 1)
        XCTAssertEqual(exportFormat.team.roles[0].name, "Engineer")
    }

    func testImportTeam_generatesNewTeamID() throws {
        let team = Team(name: "Original Team")
        let originalID = team.id

        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data)

        XCTAssertNotEqual(imported.id, originalID)
    }

    func testImportTeam_regeneratesRoleIDs() throws {
        let role1 = TeamRoleDefinition(
            id: "role-aaa",
            name: "Role A",
            prompt: "Role A prompt.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let role2 = TeamRoleDefinition(
            id: "role-bbb",
            name: "Role B",
            prompt: "Role B prompt.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        var team = Team(name: "Test Team")
        team.roles = [role1, role2]

        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data)

        XCTAssertEqual(imported.roles.count, 2)
        XCTAssertNotEqual(imported.roles[0].id, "role-aaa")
        XCTAssertNotEqual(imported.roles[1].id, "role-bbb")
        // Each role should have a unique new ID
        XCTAssertNotEqual(imported.roles[0].id, imported.roles[1].id)
    }

    func testImportTeam_remapsGraphLayoutNodePositions() throws {
        let roleA = TeamRoleDefinition(
            id: "role-aaa",
            name: "Role A",
            prompt: "Prompt A.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let roleB = TeamRoleDefinition(
            id: "role-bbb",
            name: "Role B",
            prompt: "Prompt B.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        var team = Team(name: "Graph Test Team")
        team.roles = [roleA, roleB]
        team.graphLayout = TeamGraphLayout(
            nodePositions: [
                TeamNodePosition(roleID: "role-aaa", x: 100, y: 200),
                TeamNodePosition(roleID: "role-bbb", x: 300, y: 400)
            ]
        )

        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data)

        // Node positions should use the new role IDs
        XCTAssertEqual(imported.graphLayout.nodePositions.count, 2)

        let nodeRoleIDs = Set(imported.graphLayout.nodePositions.map(\.roleID))
        let importedRoleIDs = Set(imported.roles.map(\.id))
        XCTAssertEqual(nodeRoleIDs, importedRoleIDs)

        // Old IDs should not appear in node positions
        XCTAssertFalse(nodeRoleIDs.contains("role-aaa"))
        XCTAssertFalse(nodeRoleIDs.contains("role-bbb"))

        // Positions should be preserved
        let positionForA = imported.graphLayout.nodePositions.first(where: { $0.roleID == imported.roles[0].id })
        XCTAssertEqual(positionForA?.x, 100)
        XCTAssertEqual(positionForA?.y, 200)

        let positionForB = imported.graphLayout.nodePositions.first(where: { $0.roleID == imported.roles[1].id })
        XCTAssertEqual(positionForB?.x, 300)
        XCTAssertEqual(positionForB?.y, 400)
    }

    func testImportTeam_remapsHiddenRoleIDs() throws {
        let roleA = TeamRoleDefinition(
            id: "role-aaa",
            name: "Role A",
            prompt: "Prompt A.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let roleB = TeamRoleDefinition(
            id: "role-bbb",
            name: "Role B",
            prompt: "Prompt B.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        var team = Team(name: "Hidden Test Team")
        team.roles = [roleA, roleB]
        team.graphLayout = TeamGraphLayout(
            nodePositions: [
                TeamNodePosition(roleID: "role-aaa", x: 100, y: 200)
            ],
            hiddenRoleIDs: ["role-bbb"]
        )

        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data)

        // Hidden role IDs should be remapped to the new IDs
        XCTAssertEqual(imported.graphLayout.hiddenRoleIDs.count, 1)
        XCTAssertFalse(imported.graphLayout.hiddenRoleIDs.contains("role-bbb"))

        // The hidden role ID should be the new ID of roleB
        let newRoleBID = imported.roles[1].id
        XCTAssertTrue(imported.graphLayout.hiddenRoleIDs.contains(newRoleBID))
    }

    func testImportTeam_usesNewNameIfProvided() throws {
        let team = Team(name: "Original Name")

        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data, newName: "Custom Name")

        XCTAssertEqual(imported.name, "Custom Name")
    }

    func testImportTeam_defaultNameHasImportedSuffix() throws {
        let team = Team(name: "My Team")

        let data = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: data)

        XCTAssertEqual(imported.name, "My Team (Imported)")
    }

    func testImportTeam_unsupportedVersion_throws() throws {
        // Manually craft team JSON with version 42
        let teamJSON: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Bad Team",
            "roles": [] as [[String: Any]],
            "artifacts": [] as [[String: Any]],
            "settings": [
                "hierarchy": ["reportsTo": [:] as [String: String]],
                "invitableRoles": [] as [String],
                "supervisorCanBeInvited": false,
                "limits": [
                    "maxConsultationsPerStep": 5,
                    "maxMeetingsPerRun": 3,
                    "maxMeetingTurns": 10,
                    "maxSameTeammateAsks": 2,
                    "autoIterationLimit": 10000,
                    "maxMeetingToolIterationsPerTurn": 3,
                    "maxChangeRequestsPerRun": 3,
                    "maxAmendmentsPerStep": 2
                ],
                "defaultAcceptanceMode": "afterEachRole",
                "acceptanceCheckpoints": [] as [String]
            ],
            "graphLayout": [
                "nodePositions": [] as [[String: Any]],
                "hiddenRoleIDs": [] as [String]
            ]
        ]
        let json: [String: Any] = [
            "version": 42,
            "team": teamJSON,
            "exportedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try TeamImportExportService.importTeam(from: data)) { error in
            guard case ImportExportError.unsupportedVersion(let version) = error else {
                XCTFail("Expected unsupportedVersion error, got \(error)")
                return
            }
            XCTAssertEqual(version, 42)
        }
    }

    // MARK: - Suggested File Names

    func testSuggestedFileName_role_formatsCorrectly() {
        let role = TeamRoleDefinition(
            id: "test_software_engineer",
            name: "Software Engineer",
            prompt: "Build software.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )

        let fileName = TeamImportExportService.suggestedFileName(for: role)
        XCTAssertEqual(fileName, "software_engineer_role.json")
    }

    func testSuggestedFileName_artifact_formatsCorrectly() {
        let artifact = TeamArtifact(
            id: "test_product_requirements",
            name: "Product Requirements",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "Product requirements document"
        )

        let fileName = TeamImportExportService.suggestedFileName(for: artifact)
        XCTAssertEqual(fileName, "product_requirements_artifact.json")
    }

    func testSuggestedFileName_team_formatsCorrectly() {
        let team = Team(name: "FAANG Team")

        let fileName = TeamImportExportService.suggestedFileName(for: team)
        XCTAssertEqual(fileName, "faang_team_team.json")
    }
}
