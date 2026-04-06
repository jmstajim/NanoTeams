//
//  TeamRoleDefinitionTests.swift
//  NanoTeamsTests
//
//  Tests for TeamRoleDefinition model
//

import SwiftUI
import XCTest
@testable import NanoTeams

final class TeamRoleDefinitionTests: XCTestCase {

    // MARK: - Codable Tests

    func testCodable() throws {
        let role = TeamRoleDefinition(
            id: "test-role-id",
            name: "Test Engineer",
            prompt: "You are a test engineer.",
            toolIDs: ["read_file", "write_file"],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Product Requirements"],
                producesArtifacts: ["Test Report"]
            ),
            llmOverride: LLMOverride(
                baseURLString: "http://localhost:1234",
                modelName: "custom-model"
            ),
            isSystemRole: true,
            systemRoleID: "testEngineer"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(role)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TeamRoleDefinition.self, from: data)

        XCTAssertEqual(decoded.id, role.id)
        XCTAssertEqual(decoded.name, role.name)
        XCTAssertEqual(decoded.prompt, role.prompt)
        XCTAssertEqual(decoded.toolIDs, role.toolIDs)
        XCTAssertEqual(decoded.usePlanningPhase, role.usePlanningPhase)
        XCTAssertEqual(decoded.dependencies, role.dependencies)
        XCTAssertEqual(decoded.llmOverride, role.llmOverride)
        XCTAssertEqual(decoded.isSystemRole, role.isSystemRole)
        XCTAssertEqual(decoded.systemRoleID, role.systemRoleID)
    }

    func testCodableWithDefaults() throws {
        let minimalJSON = """
        {
            "id": "test-id",
            "name": "Test Role",
            "prompt": "Test prompt",
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let role = try decoder.decode(TeamRoleDefinition.self, from: minimalJSON)

        XCTAssertEqual(role.id, "test-id")
        XCTAssertEqual(role.name, "Test Role")
        XCTAssertEqual(role.prompt, "Test prompt")
        XCTAssertTrue(role.toolIDs.isEmpty, "Should default to empty array")
        XCTAssertTrue(role.usePlanningPhase, "Should default to true")
        XCTAssertTrue(role.dependencies.requiredArtifacts.isEmpty)
        XCTAssertTrue(role.dependencies.producesArtifacts.isEmpty)
        XCTAssertNil(role.llmOverride)
        XCTAssertFalse(role.isSystemRole, "Should default to false")
        XCTAssertNil(role.systemRoleID)
    }

    // MARK: - Helper Method Tests

    func testWithUpdatedTimestamp() {
        let role = TeamRoleDefinition(
            id: "test_test_role",
            name: "Test Role",
            prompt: "Test prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )

        let originalUpdatedAt = role.updatedAt

        // Wait a tiny bit to ensure timestamp changes
        Thread.sleep(forTimeInterval: 0.001)

        let updated = role.withUpdatedTimestamp()

        XCTAssertEqual(updated.id, role.id)
        XCTAssertEqual(updated.name, role.name)
        XCTAssertGreaterThan(updated.updatedAt, originalUpdatedAt, "Updated timestamp should be newer")
    }

    func testIsIndependent() {
        let independentRole = TeamRoleDefinition(
            id: "test_supervisor",
            name: "Supervisor",
            prompt: "Supervisor prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: [SystemTemplates.supervisorTaskArtifactName]
            )
        )

        XCTAssertTrue(independentRole.isIndependent, "Role with no required artifacts should be independent")

        let dependentRole = TeamRoleDefinition(
            id: "test_pm",
            name: "PM",
            prompt: "PM prompt",
            toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: [SystemTemplates.supervisorTaskArtifactName],
                producesArtifacts: ["Product Requirements"]
            )
        )

        XCTAssertFalse(dependentRole.isIndependent, "Role with required artifacts should not be independent")
    }

    func testProducesArtifacts() {
        let producerRole = TeamRoleDefinition(
            id: "test_pm_producer",
            name: "PM",
            prompt: "PM prompt",
            toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Product Requirements"]
            )
        )

        XCTAssertTrue(producerRole.producesArtifacts, "Role with produced artifacts should return true")

        let nonProducerRole = TeamRoleDefinition(
            id: "test_non_producer",
            name: "Test Role",
            prompt: "Test prompt",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: []
            )
        )

        XCTAssertFalse(nonProducerRole.producesArtifacts, "Role with no produced artifacts should return false")
    }

    // MARK: - LLM Override Tests

    func testLLMOverrideEmpty() {
        let emptyOverride = LLMOverride(baseURLString: nil, modelName: nil)
        XCTAssertTrue(emptyOverride.isEmpty, "Override with all nil values should be empty")

        let partialOverride1 = LLMOverride(baseURLString: "http://localhost:1234", modelName: nil)
        XCTAssertFalse(partialOverride1.isEmpty, "Override with base URL should not be empty")

        let partialOverride2 = LLMOverride(baseURLString: nil, modelName: "custom-model")
        XCTAssertFalse(partialOverride2.isEmpty, "Override with model name should not be empty")

        let fullOverride = LLMOverride(baseURLString: "http://localhost:1234", modelName: "custom-model")
        XCTAssertFalse(fullOverride.isEmpty, "Override with both values should not be empty")
    }

    // MARK: - Icon Color Tests

    func testCodableWithIconColors() throws {
        let role = TeamRoleDefinition(
            id: "colored-role",
            name: "Colored Role",
            prompt: "Test",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            iconColor: "#FF5733",
            iconBackground: "#33FF57"
        )

        let data = try JSONEncoder().encode(role)
        let decoded = try JSONDecoder().decode(TeamRoleDefinition.self, from: data)

        XCTAssertEqual(decoded.iconColor, "#FF5733")
        XCTAssertEqual(decoded.iconBackground, "#33FF57")
    }

    func testCodableWithoutIconColors_MigrationDefaults() throws {
        let json = """
        {
            "id": "test-id",
            "name": "Test Role",
            "prompt": "P",
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TeamRoleDefinition.self, from: json)
        XCTAssertEqual(decoded.iconColor, "#FFFFFF", "Should default to white")
        XCTAssertEqual(decoded.iconBackground, RoleColorDefaults.defaultHex, "Should default to defaultHex for non-system roles")
    }

    func testCodableWithoutIconColors_SystemRoleMigration() throws {
        let json = """
        {
            "id": "test-id",
            "name": "PM",
            "prompt": "P",
            "systemRoleID": "productManager",
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TeamRoleDefinition.self, from: json)
        XCTAssertEqual(decoded.iconColor, "#FFFFFF")
        XCTAssertEqual(decoded.iconBackground, RoleColorDefaults.defaultBackgroundHex(for: "productManager"), "Should default to productManager color")
    }

    func testResolvedTintColor_CustomBackground() {
        let role = TeamRoleDefinition(
            id: "test_custom",
            name: "Custom",
            prompt: "P",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            iconBackground: "#FF0000"
        )
        XCTAssertEqual(role.iconBackground, "#FF0000")
        let _ = role.resolvedTintColor
    }

    func testResolvedTintColor_DefaultBackground() {
        let role = TeamRoleDefinition(
            id: "test_pm_default",
            name: "PM",
            prompt: "P",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        XCTAssertEqual(role.iconColor, "#FFFFFF")
        XCTAssertEqual(role.iconBackground, "#007AFF")
        let _ = role.resolvedTintColor
    }

    func testResolvedIconColor_CustomForeground() {
        let role = TeamRoleDefinition(
            id: "test_custom_fg",
            name: "Custom",
            prompt: "P",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            iconColor: "#00FF00"
        )
        XCTAssertEqual(role.iconColor, "#00FF00")
        let _ = role.resolvedIconColor
    }

    func testDefaultBackgroundHex_SystemRoles() {
        XCTAssertEqual(RoleColorDefaults.defaultBackgroundHex(for: "supervisor"), "#6D76E2")
        XCTAssertEqual(RoleColorDefaults.defaultBackgroundHex(for: "softwareEngineer"), "#4FB985")
        XCTAssertEqual(RoleColorDefaults.defaultBackgroundHex(for: nil), RoleColorDefaults.defaultHex)
        XCTAssertEqual(RoleColorDefaults.defaultBackgroundHex(for: "unknownRole"), RoleColorDefaults.defaultHex)
    }

    // MARK: - Hex Conversion Tests

    func testHexToColor_Valid() {
        XCTAssertNotNil(Color(hex: "#FF5733"))
        XCTAssertNotNil(Color(hex: "#000000"))
        XCTAssertNotNil(Color(hex: "#FFFFFF"))
    }

    func testHexToColor_WithoutHash() {
        XCTAssertNotNil(Color(hex: "FF5733"))
    }

    func testHexToColor_Invalid() {
        XCTAssertNil(Color(hex: "invalid"))
        XCTAssertNil(Color(hex: "#GGG"))
        XCTAssertNil(Color(hex: "#FF"))
        XCTAssertNil(Color(hex: ""))
    }

    // MARK: - Hashable Tests

    func testHashable() {
        let role1 = TeamRoleDefinition(
            id: "same-id",
            name: "Role 1",
            prompt: "Prompt 1",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )

        let role2 = TeamRoleDefinition(
            id: "same-id",
            name: "Role 1",
            prompt: "Prompt 1",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )

        XCTAssertEqual(role1, role2, "Roles with same content should be equal")

        var set = Set<TeamRoleDefinition>()
        set.insert(role1)
        set.insert(role2)

        XCTAssertEqual(set.count, 1, "Set should contain only one role since they are equal")
    }

    // MARK: - Role Completion Type Tests

    func testIsAdvisory_HasInputsNoOutputs() {
        let role = TeamRoleDefinition(
            id: "test_reviewer",
            name: "Reviewer",
            prompt: "Review code",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Implementation Plan"],
                producesArtifacts: []
            )
        )
        XCTAssertTrue(role.isAdvisory)
        XCTAssertFalse(role.isObserver)
        XCTAssertFalse(role.producesArtifacts)
    }

    func testIsObserver_NoInputsNoOutputs() {
        let role = TeamRoleDefinition(
            id: "test_stakeholder",
            name: "Stakeholder",
            prompt: "Observe",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: []
            )
        )
        XCTAssertTrue(role.isObserver)
        XCTAssertFalse(role.isAdvisory)
        XCTAssertFalse(role.producesArtifacts)
    }

    func testProducingRole_NotAdvisoryNorObserver() {
        let role = TeamRoleDefinition(
            id: "test_pm_producing",
            name: "PM",
            prompt: "Plan",
            toolIDs: [],
            usePlanningPhase: true,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"],
                producesArtifacts: ["Product Requirements"]
            )
        )
        XCTAssertFalse(role.isAdvisory)
        XCTAssertFalse(role.isObserver)
        XCTAssertTrue(role.producesArtifacts)
    }

    func testSupervisor_NotAdvisoryNorObserver() {
        let role = TeamRoleDefinition(
            id: "supervisor",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: [SystemTemplates.supervisorTaskArtifactName]
            ),
            systemRoleID: "supervisor"
        )
        XCTAssertFalse(role.isAdvisory)
        XCTAssertFalse(role.isObserver)
    }

    // MARK: - completionType (Round 3)

    func testCompletionType_producingForSupervisor() {
        let role = TeamRoleDefinition(
            id: "supervisor",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            systemRoleID: "supervisor"
        )
        XCTAssertEqual(role.completionType, .producing)
    }

    // MARK: - artifactSummary (Round 3)

    func testArtifactSummary_needsAndProduces() {
        let role = TeamRoleDefinition(
            id: "swe",
            name: "Engineer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Plan"],
                producesArtifacts: ["Code", "Tests"]
            )
        )
        XCTAssertEqual(role.artifactSummary, "Needs: Plan \u{2192} produces: Code, Tests")
    }

    func testArtifactSummary_producesOnly() {
        let role = TeamRoleDefinition(
            id: "pm",
            name: "PM",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Report"]
            )
        )
        XCTAssertEqual(role.artifactSummary, "Produces: Report")
    }
}
