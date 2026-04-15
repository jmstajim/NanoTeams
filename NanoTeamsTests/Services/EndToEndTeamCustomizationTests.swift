import XCTest

@testable import NanoTeams

/// End-to-end tests for per-team roles and artifacts customization.
/// Tests the full user journey of creating custom teams, roles, and artifacts.
final class EndToEndTeamCustomizationTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Custom Role Creation and Editing

    func testCustomRole_CreateAndEdit() throws {
        // Create a custom team
        var team = Team(name: "Custom Team")

        // Create a custom role
        let customRole = TeamRoleDefinition(
            id: "test_devops_engineer",
            name: "DevOps Engineer",
            prompt: "You are a DevOps engineer responsible for deployment.",
            toolIDs: ["git_status", "run_xcodebuild"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Engineering Notes"],
                producesArtifacts: ["Deployment Plan"]
            )
        )

        team.addRole(customRole)

        // Verify role was added
        XCTAssertEqual(team.roles.count, 1)
        XCTAssertEqual(team.roles[0].name, "DevOps Engineer")
        XCTAssertTrue(team.roles[0].usePlanningPhase)
        XCTAssertEqual(team.roles[0].toolIDs.count, 2)
        XCTAssertEqual(team.roles[0].dependencies.requiredArtifacts, ["Engineering Notes"])
        XCTAssertEqual(team.roles[0].dependencies.producesArtifacts, ["Deployment Plan"])
        XCTAssertFalse(team.roles[0].isSystemRole)
        XCTAssertNil(team.roles[0].systemRoleID)

        // Edit the role
        var updated = team.roles[0]
        updated.name = "Senior DevOps Engineer"
        updated.prompt = "You are a senior DevOps engineer."
        updated.toolIDs.append("git_commit")
        team.updateRole(updated)

        // Verify role was updated
        XCTAssertEqual(team.roles[0].name, "Senior DevOps Engineer")
        XCTAssertEqual(team.roles[0].prompt, "You are a senior DevOps engineer.")
        XCTAssertEqual(team.roles[0].toolIDs.count, 3)
        XCTAssertTrue(team.roles[0].toolIDs.contains("git_commit"))
    }

    func testCustomRole_WithLLMOverride() throws {
        var team = Team(name: "Custom Team")

        let roleWithOverride = TeamRoleDefinition(
            id: "test_ai_researcher",
            name: "AI Researcher",
            prompt: "Research AI topics.",
            toolIDs: ["read_file", "search"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [], producesArtifacts: ["Research Notes"]),
            llmOverride: LLMOverride(
                baseURLString: "http://localhost:1235", modelName: "deepseek-r1")
        )

        team.addRole(roleWithOverride)

        XCTAssertNotNil(team.roles[0].llmOverride)
        XCTAssertEqual(team.roles[0].llmOverride?.baseURLString, "http://localhost:1235")
        XCTAssertEqual(team.roles[0].llmOverride?.modelName, "deepseek-r1")
        XCTAssertFalse(team.roles[0].llmOverride?.isEmpty ?? true)
    }

    func testSupervisorRole_FullyEditable() throws {
        // Get FAANG team from bootstrap
        let teams = Team.defaultTeams
        guard var faangTeam = teams.first(where: { $0.name == "FAANG Team" }) else {
            XCTFail("FAANG team not found")
            return
        }

        // Find Supervisor role
        guard let supervisorRoleIndex = faangTeam.roles.firstIndex(where: \.isSupervisor) else {
            XCTFail("Supervisor role not found")
            return
        }

        // Verify Supervisor is in roles array
        XCTAssertTrue(faangTeam.roles[supervisorRoleIndex].isSystemRole)
        XCTAssertEqual(faangTeam.roles[supervisorRoleIndex].systemRoleID, "supervisor")

        // Edit Supervisor name
        var supervisorRole = faangTeam.roles[supervisorRoleIndex]
        let originalName = supervisorRole.name
        supervisorRole.name = "Founder"
        faangTeam.updateRole(supervisorRole)

        XCTAssertEqual(faangTeam.roles[supervisorRoleIndex].name, "Founder")
        XCTAssertNotEqual(faangTeam.roles[supervisorRoleIndex].name, originalName)

        // Edit Supervisor artifact dependencies
        supervisorRole = faangTeam.roles[supervisorRoleIndex]
        supervisorRole.dependencies = RoleDependencies(
            requiredArtifacts: [],
            producesArtifacts: [SystemTemplates.supervisorTaskArtifactName, "Strategic Vision"]
        )
        faangTeam.updateRole(supervisorRole)

        XCTAssertEqual(faangTeam.roles[supervisorRoleIndex].dependencies.producesArtifacts.count, 2)
        XCTAssertTrue(
            faangTeam.roles[supervisorRoleIndex].dependencies.producesArtifacts.contains(
                "Strategic Vision"))
    }

    func testSupervisorRole_CanBeDeleted() throws {
        var team = Team(name: "Custom Team")

        // Add Supervisor and another role
        let supervisorRole = TeamRoleDefinition(
            id: "test_supervisor",
            name: "Supervisor",
            prompt: "Supervisor prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [], producesArtifacts: [SystemTemplates.supervisorTaskArtifactName])
        )
        let engineerRole = TeamRoleDefinition(
            id: "test_engineer",
            name: "Engineer",
            prompt: "Engineer prompt",
            toolIDs: ["write_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: [SystemTemplates.supervisorTaskArtifactName],
                producesArtifacts: ["Code"])
        )

        team.addRole(supervisorRole)
        team.addRole(engineerRole)

        XCTAssertEqual(team.roles.count, 2)

        // Remove Supervisor (should work since there's another role)
        team.removeRole(supervisorRole.id)

        XCTAssertEqual(team.roles.count, 1)
        XCTAssertEqual(team.roles[0].name, "Engineer")
    }

    // MARK: - Custom Artifact Creation and Editing

    func testCustomArtifact_CreateAndEdit() throws {
        var team = Team(name: "Custom Team")

        // Create a custom artifact
        let customArtifact = TeamArtifact(
            id: "test_api_documentation",
            name: "API Documentation",
            icon: "doc.richtext",
            mimeType: "text/markdown",
            description: "Comprehensive API documentation"
        )

        team.addArtifact(customArtifact)

        // Verify artifact was added
        XCTAssertEqual(team.artifacts.count, 1)
        XCTAssertEqual(team.artifacts[0].name, "API Documentation")
        XCTAssertEqual(team.artifacts[0].icon, "doc.richtext")
        XCTAssertEqual(team.artifacts[0].mimeType, "text/markdown")
        XCTAssertFalse(team.artifacts[0].isSystemArtifact)
        XCTAssertNil(team.artifacts[0].systemArtifactName)

        // Verify ID is a UUID string (not empty)
        XCTAssertFalse(team.artifacts[0].id.isEmpty)
        let originalID = team.artifacts[0].id

        // Edit the artifact
        var updated = team.artifacts[0]
        updated.name = "REST API Documentation"
        updated.description = "Updated description"
        team.updateArtifact(updated)

        // Verify artifact was updated
        XCTAssertEqual(team.artifacts[0].name, "REST API Documentation")
        XCTAssertEqual(team.artifacts[0].description, "Updated description")

        // ID should remain the same (it's a stored UUID, not computed from name)
        XCTAssertEqual(team.artifacts[0].id, originalID)
    }

    func testCustomArtifact_UsedByRoles() throws {
        var team = Team(name: "Custom Team")

        // Create artifact
        let artifact = TeamArtifact(
            id: "test_security_audit",
            name: "Security Audit",
            icon: "shield",
            mimeType: "text/plain",
            description: "Security audit report"
        )
        team.addArtifact(artifact)

        // Create roles that produce and consume this artifact
        let producerRole = TeamRoleDefinition(
            id: "test_security_analyst",
            name: "Security Analyst",
            prompt: "Analyze security",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Security Audit"]
            )
        )

        let consumerRole = TeamRoleDefinition(
            id: "test_devops_engineer",
            name: "DevOps Engineer",
            prompt: "Deploy securely",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Security Audit"],
                producesArtifacts: ["Deployment Plan"]
            )
        )

        team.addRole(producerRole)
        team.addRole(consumerRole)

        // Verify usage
        let producers = team.roles.filter {
            $0.dependencies.producesArtifacts.contains("Security Audit")
        }
        let consumers = team.roles.filter {
            $0.dependencies.requiredArtifacts.contains("Security Audit")
        }

        XCTAssertEqual(producers.count, 1)
        XCTAssertEqual(producers[0].name, "Security Analyst")
        XCTAssertEqual(consumers.count, 1)
        XCTAssertEqual(consumers[0].name, "DevOps Engineer")
    }

    // MARK: - Role Import/Export

    func testRoleExport_RoundTrip() throws {
        let role = TeamRoleDefinition(
            id: "test_backend_engineer",
            name: "Backend Engineer",
            prompt: "Build backend services",
            toolIDs: ["read_file", "write_file", "git_commit"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["API Spec"],
                producesArtifacts: ["Backend Code"]
            ),
            llmOverride: LLMOverride(baseURLString: "http://localhost:1234", modelName: "codellama")
        )

        // Export role
        let exportedData = try TeamImportExportService.exportRole(role)

        // Verify export data is valid JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportFormat = try decoder.decode(RoleExportFormat.self, from: exportedData)
        XCTAssertEqual(exportFormat.version, 1)
        XCTAssertEqual(exportFormat.role.name, "Backend Engineer")
        XCTAssertNotNil(exportFormat.exportedAt)

        // Import role into new team
        var team = Team(name: "Target Team")
        try TeamImportExportService.importRole(from: exportedData, into: &team)

        // Verify imported role
        XCTAssertEqual(team.roles.count, 1)
        let imported = team.roles[0]

        XCTAssertEqual(imported.name, "Backend Engineer")
        XCTAssertEqual(imported.prompt, "Build backend services")
        XCTAssertEqual(imported.toolIDs.count, 3)
        XCTAssertTrue(imported.usePlanningPhase)
        XCTAssertEqual(imported.dependencies.requiredArtifacts, ["API Spec"])
        XCTAssertEqual(imported.dependencies.producesArtifacts, ["Backend Code"])
        XCTAssertNotNil(imported.llmOverride)
        XCTAssertEqual(imported.llmOverride?.baseURLString, "http://localhost:1234")
        XCTAssertEqual(imported.llmOverride?.modelName, "codellama")

        // Imported role should have new ID and be marked as custom
        XCTAssertNotEqual(imported.id, role.id)
        XCTAssertFalse(imported.isSystemRole)
        XCTAssertNil(imported.systemRoleID)
    }

    func testRoleImport_NameConflictResolution() throws {
        var team = Team(name: "Team")

        // Add existing role
        let existingRole = TeamRoleDefinition(
            id: "test_engineer",
            name: "Engineer",
            prompt: "Existing engineer",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        team.addRole(existingRole)

        // Create role with same name to import
        let roleToImport = TeamRoleDefinition(
            id: "test_engineer_import",
            name: "Engineer",
            prompt: "Imported engineer",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )

        let exportedData = try TeamImportExportService.exportRole(roleToImport)
        try TeamImportExportService.importRole(from: exportedData, into: &team)

        // Should have 2 roles, with imported one renamed
        XCTAssertEqual(team.roles.count, 2)
        XCTAssertTrue(team.roles.contains { $0.name == "Engineer" })
        XCTAssertTrue(team.roles.contains { $0.name == "Engineer (Imported)" })
    }

    // MARK: - Artifact Import/Export

    func testArtifactExport_RoundTrip() throws {
        let artifact = TeamArtifact(
            id: "test_performance_metrics",
            name: "Performance Metrics",
            icon: "chart.bar",
            mimeType: "application/json",
            description: "System performance metrics"
        )

        // Export artifact
        let exportedData = try TeamImportExportService.exportArtifact(artifact)

        // Verify export data
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportFormat = try decoder.decode(ArtifactExportFormat.self, from: exportedData)
        XCTAssertEqual(exportFormat.version, 1)
        XCTAssertEqual(exportFormat.artifact.name, "Performance Metrics")

        // Import artifact
        var team = Team(name: "Target Team")
        try TeamImportExportService.importArtifact(from: exportedData, into: &team)

        // Verify imported artifact
        XCTAssertEqual(team.artifacts.count, 1)
        let imported = team.artifacts[0]

        XCTAssertEqual(imported.name, "Performance Metrics")
        XCTAssertEqual(imported.icon, "chart.bar")
        XCTAssertEqual(imported.mimeType, "application/json")
        XCTAssertEqual(imported.description, "System performance metrics")

        // Imported artifact should be marked as custom
        XCTAssertFalse(imported.isSystemArtifact)
        XCTAssertNil(imported.systemArtifactName)

        // ID should be computed from name via Artifact.slugify (import regenerates IDs)
        XCTAssertEqual(imported.id, "performance_metrics")
    }

    func testArtifactImport_NameConflictResolution() throws {
        var team = Team(name: "Team")

        // Add existing artifact
        let existingArtifact = TeamArtifact(
            id: "test_metrics",
            name: "Metrics",
            icon: "doc",
            mimeType: "text/plain",
            description: "Existing"
        )
        team.addArtifact(existingArtifact)

        // Import artifact with same name
        let artifactToImport = TeamArtifact(
            id: "test_metrics_import",
            name: "Metrics",
            icon: "chart",
            mimeType: "application/json",
            description: "Imported"
        )

        let exportedData = try TeamImportExportService.exportArtifact(artifactToImport)
        try TeamImportExportService.importArtifact(from: exportedData, into: &team)

        // Should have 2 artifacts, with imported one renamed
        XCTAssertEqual(team.artifacts.count, 2)
        XCTAssertTrue(team.artifacts.contains { $0.name == "Metrics" })
        XCTAssertTrue(team.artifacts.contains { $0.name == "Metrics (Imported)" })
    }

    // MARK: - Team Import/Export

    func testTeamExport_RoundTrip() throws {
        // Create custom team with roles and artifacts
        var team = Team(name: "DevOps Team")

        let artifact = TeamArtifact(
            id: "test_infrastructure_plan",
            name: "Infrastructure Plan",
            icon: "server.rack",
            mimeType: "text/markdown",
            description: "Infrastructure architecture"
        )
        team.addArtifact(artifact)

        let role = TeamRoleDefinition(
            id: "test_platform_engineer",
            name: "Platform Engineer",
            prompt: "Manage infrastructure",
            toolIDs: ["read_file", "write_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Infrastructure Plan"]
            )
        )
        team.addRole(role)

        // Export team
        let exportedData = try TeamImportExportService.exportTeam(team)

        // Verify export
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportFormat = try decoder.decode(TeamExportFormat.self, from: exportedData)
        XCTAssertEqual(exportFormat.version, 1)
        XCTAssertEqual(exportFormat.team.name, "DevOps Team")

        // Import team
        let imported = try TeamImportExportService.importTeam(from: exportedData)

        // Verify imported team
        XCTAssertEqual(imported.name, "DevOps Team (Imported)")
        XCTAssertNotEqual(imported.id, team.id)
        XCTAssertEqual(imported.roles.count, 1)
        XCTAssertEqual(imported.artifacts.count, 1)

        // Verify all IDs are regenerated
        XCTAssertNotEqual(imported.roles[0].id, team.roles[0].id)
        XCTAssertEqual(imported.roles[0].name, "Platform Engineer")

        XCTAssertEqual(imported.artifacts[0].name, "Infrastructure Plan")
        XCTAssertEqual(imported.artifacts[0].id, "infrastructure_plan")
    }

    func testTeamExport_WithCustomName() throws {
        let team = Team(name: "Original Team")

        let exportedData = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(
            from: exportedData, newName: "Custom Name")

        XCTAssertEqual(imported.name, "Custom Name")
    }

    // MARK: - File Name Suggestions

    func testSuggestedFileName_Role() {
        let role = TeamRoleDefinition(
            id: "test_backend_engineer",
            name: "Backend Engineer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )

        let fileName = TeamImportExportService.suggestedFileName(for: role)

        XCTAssertEqual(fileName, "backend_engineer_role.json")
    }

    func testSuggestedFileName_Artifact() {
        let artifact = TeamArtifact(
            id: "test_api_documentation",
            name: "API Documentation",
            icon: "doc",
            mimeType: "text/plain",
            description: ""
        )

        let fileName = TeamImportExportService.suggestedFileName(for: artifact)

        XCTAssertEqual(fileName, "api_documentation_artifact.json")
    }

    func testSuggestedFileName_Team() {
        let team = Team(name: "DevOps Team")

        let fileName = TeamImportExportService.suggestedFileName(for: team)

        XCTAssertEqual(fileName, "devops_team_team.json")
    }

    // MARK: - Bootstrap Defaults Integration

    func testBootstrapDefaults_AllTeamsHaveSupervisor() {
        let teams = Team.defaultTeams

        XCTAssertEqual(teams.count, 6)

        for team in teams {
            // Each team should have Supervisor as first role
            let supervisorRoles = team.roles.filter(\.isSupervisor)
            XCTAssertEqual(
                supervisorRoles.count, 1, "Team '\(team.name)' should have exactly one Supervisor role")

            // Supervisor should produce "Supervisor Task" artifact
            let supervisorDeps = supervisorRoles[0].dependencies
            XCTAssertTrue(
                supervisorDeps.producesArtifacts.contains(SystemTemplates.supervisorTaskArtifactName),
                "Team '\(team.name)' Supervisor should produce 'Supervisor Task'")
        }
    }

    func testBootstrapDefaults_ArtifactsMatchRoleDependencies() {
        let teams = Team.defaultTeams

        for team in teams {
            let artifactNames = Set(team.artifacts.map(\.name))

            // Print debug info for failures
            var missingArtifacts: Set<String> = []

            for role in team.roles {
                // All required artifacts should exist in team
                for requiredArtifact in role.dependencies.requiredArtifacts {
                    if !artifactNames.contains(requiredArtifact) {
                        missingArtifacts.insert(requiredArtifact)
                        print(
                            "Team '\(team.name)' role '\(role.name)' requires missing artifact '\(requiredArtifact)'"
                        )
                    }
                }

                // All produced artifacts should exist in team
                for producedArtifact in role.dependencies.producesArtifacts {
                    if !artifactNames.contains(producedArtifact) {
                        missingArtifacts.insert(producedArtifact)
                        print(
                            "Team '\(team.name)' role '\(role.name)' produces missing artifact '\(producedArtifact)'"
                        )
                    }
                }
            }

            // Print available artifacts for debugging
            if !missingArtifacts.isEmpty {
                print("Team '\(team.name)' available artifacts: \(artifactNames.sorted())")
            }

            XCTAssertTrue(
                missingArtifacts.isEmpty,
                "Team '\(team.name)' has missing artifacts: \(missingArtifacts.sorted())")
        }
    }

    // MARK: - Complex Scenarios

    func testComplexScenario_BuildCustomTeamFromScratch() throws {
        // Build a custom team with multiple roles and artifacts
        var team = Team(name: "Mobile Team")

        // Add artifacts first
        let artifacts = [
            TeamArtifact(
                id: "test_app_requirements",
                name: "App Requirements", icon: "doc.text", mimeType: "text/markdown",
                description: ""),
            TeamArtifact(
                id: "test_ui_design",
                name: "UI Design", icon: "paintbrush", mimeType: "text/plain", description: ""),
            TeamArtifact(
                id: "test_ios_code",
                name: "iOS Code", icon: "swift", mimeType: "text/plain", description: ""),
            TeamArtifact(
                id: "test_android_code",
                name: "Android Code", icon: "android", mimeType: "text/plain", description: ""),
            TeamArtifact(
                id: "test_test_results",
                name: "Test Results", icon: "checkmark", mimeType: "text/plain", description: ""),
        ]

        for artifact in artifacts {
            team.addArtifact(artifact)
        }

        // Add roles with dependencies
        let productOwner = TeamRoleDefinition(
            id: "test_product_owner",
            name: "Product Owner",
            prompt: "Define app requirements",
            toolIDs: ["read_file", "write_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["App Requirements"]
            )
        )

        let designer = TeamRoleDefinition(
            id: "test_ui_designer",
            name: "UI Designer",
            prompt: "Design mobile UI",
            toolIDs: ["read_file", "write_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["App Requirements"],
                producesArtifacts: ["UI Design"]
            )
        )

        let iOSEngineer = TeamRoleDefinition(
            id: "test_ios_engineer",
            name: "iOS Engineer",
            prompt: "Build iOS app",
            toolIDs: ["read_file", "write_file", "git_commit"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["UI Design"],
                producesArtifacts: ["iOS Code"]
            )
        )

        let androidEngineer = TeamRoleDefinition(
            id: "test_android_engineer",
            name: "Android Engineer",
            prompt: "Build Android app",
            toolIDs: ["read_file", "write_file", "git_commit"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["UI Design"],
                producesArtifacts: ["Android Code"]
            )
        )

        let qaEngineer = TeamRoleDefinition(
            id: "test_qa_engineer",
            name: "QA Engineer",
            prompt: "Test mobile apps",
            toolIDs: ["read_file", "run_xcodetests"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["iOS Code", "Android Code"],
                producesArtifacts: ["Test Results"]
            )
        )

        team.addRole(productOwner)
        team.addRole(designer)
        team.addRole(iOSEngineer)
        team.addRole(androidEngineer)
        team.addRole(qaEngineer)

        // Verify team structure
        XCTAssertEqual(team.roles.count, 5)
        XCTAssertEqual(team.artifacts.count, 5)

        // Verify dependency chain
        XCTAssertTrue(team.roles[0].dependencies.producesArtifacts.contains("App Requirements"))
        XCTAssertTrue(team.roles[1].dependencies.requiredArtifacts.contains("App Requirements"))
        XCTAssertTrue(team.roles[1].dependencies.producesArtifacts.contains("UI Design"))
        XCTAssertTrue(team.roles[2].dependencies.requiredArtifacts.contains("UI Design"))
        XCTAssertTrue(team.roles[3].dependencies.requiredArtifacts.contains("UI Design"))
        XCTAssertTrue(team.roles[4].dependencies.requiredArtifacts.contains("iOS Code"))
        XCTAssertTrue(team.roles[4].dependencies.requiredArtifacts.contains("Android Code"))

        // Export and re-import team
        let exportedData = try TeamImportExportService.exportTeam(team)
        let imported = try TeamImportExportService.importTeam(from: exportedData)

        // Verify structure is preserved
        XCTAssertEqual(imported.roles.count, 5)
        XCTAssertEqual(imported.artifacts.count, 5)
        XCTAssertEqual(imported.roles.map(\.name).sorted(), team.roles.map(\.name).sorted())
        XCTAssertEqual(imported.artifacts.map(\.name).sorted(), team.artifacts.map(\.name).sorted())
    }
}
