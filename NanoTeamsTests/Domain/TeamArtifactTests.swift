//
//  TeamArtifactTests.swift
//  NanoTeamsTests
//
//  Tests for TeamArtifact model
//

import XCTest
@testable import NanoTeams

final class TeamArtifactTests: XCTestCase {

    // MARK: - Codable Tests

    func testCodable() throws {
        let artifact = TeamArtifact(
            id: "test-artifact-id",
            name: "Test Artifact",
            icon: "doc.fill",
            mimeType: "text/markdown",
            description: "A test artifact",
            isSystemArtifact: true,
            systemArtifactName: "Test Artifact"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(artifact)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TeamArtifact.self, from: data)

        XCTAssertEqual(decoded.id, artifact.id)
        XCTAssertEqual(decoded.name, artifact.name)
        XCTAssertEqual(decoded.icon, artifact.icon)
        XCTAssertEqual(decoded.mimeType, artifact.mimeType)
        XCTAssertEqual(decoded.description, artifact.description)
        XCTAssertEqual(decoded.isSystemArtifact, artifact.isSystemArtifact)
        XCTAssertEqual(decoded.systemArtifactName, artifact.systemArtifactName)
    }

    func testCodableWithDefaults() throws {
        let minimalJSON = """
        {
            "id": "test-id",
            "name": "Test Artifact",
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let artifact = try decoder.decode(TeamArtifact.self, from: minimalJSON)

        XCTAssertEqual(artifact.id, "test-id")
        XCTAssertEqual(artifact.name, "Test Artifact")
        XCTAssertEqual(artifact.icon, "doc.text", "Should default to doc.text")
        XCTAssertEqual(artifact.mimeType, "text/markdown", "Should default to text/markdown")
        XCTAssertEqual(artifact.description, "", "Should default to empty string")
        XCTAssertFalse(artifact.isSystemArtifact, "Should default to false")
        XCTAssertNil(artifact.systemArtifactName)
    }

    // MARK: - Helper Method Tests

    func testWithUpdatedTimestamp() {
        let artifact = TeamArtifact(
            id: "test_test_artifact",
            name: "Test Artifact",
            icon: "doc",
            mimeType: "text/plain",
            description: "Test"
        )

        let originalUpdatedAt = artifact.updatedAt

        // Wait a tiny bit to ensure timestamp changes
        Thread.sleep(forTimeInterval: 0.001)

        let updated = artifact.withUpdatedTimestamp()

        XCTAssertEqual(updated.id, artifact.id)
        XCTAssertEqual(updated.name, artifact.name)
        XCTAssertGreaterThan(updated.updatedAt, originalUpdatedAt, "Updated timestamp should be newer")
    }

    func testIsMarkdown() {
        let markdownArtifact = TeamArtifact(
            id: "test_markdown_doc",
            name: "Markdown Doc",
            icon: "doc",
            mimeType: "text/markdown",
            description: ""
        )
        XCTAssertTrue(markdownArtifact.isMarkdown)

        let plainTextArtifact = TeamArtifact(
            id: "test_plain_text",
            name: "Plain Text",
            icon: "doc",
            mimeType: "text/plain",
            description: ""
        )
        XCTAssertFalse(plainTextArtifact.isMarkdown)
    }

    func testIsPlainText() {
        let plainTextArtifact = TeamArtifact(
            id: "test_plain_text_2",
            name: "Plain Text",
            icon: "doc",
            mimeType: "text/plain",
            description: ""
        )
        XCTAssertTrue(plainTextArtifact.isPlainText)

        let markdownArtifact = TeamArtifact(
            id: "test_markdown_doc_2",
            name: "Markdown Doc",
            icon: "doc",
            mimeType: "text/markdown",
            description: ""
        )
        XCTAssertFalse(markdownArtifact.isPlainText)
    }

    func testIsJSON() {
        let jsonArtifact = TeamArtifact(
            id: "test_json_data",
            name: "JSON Data",
            icon: "doc",
            mimeType: "application/json",
            description: ""
        )
        XCTAssertTrue(jsonArtifact.isJSON)

        let markdownArtifact = TeamArtifact(
            id: "test_markdown_doc_3",
            name: "Markdown Doc",
            icon: "doc",
            mimeType: "text/markdown",
            description: ""
        )
        XCTAssertFalse(markdownArtifact.isJSON)
    }

    func testSlugify() {
        XCTAssertEqual(TeamArtifact.slugify("Product Requirements"), "product_requirements")
        XCTAssertEqual(TeamArtifact.slugify("Design Spec"), "design_spec")
        XCTAssertEqual(TeamArtifact.slugify(SystemTemplates.supervisorTaskArtifactName), "supervisor_task")
        XCTAssertEqual(TeamArtifact.slugify("Hello World 123"), "hello_world_123")
        XCTAssertEqual(TeamArtifact.slugify("Special!@#Characters"), "specialcharacters")
        XCTAssertEqual(TeamArtifact.slugify("Multiple   Spaces"), "multiple_spaces")
    }

    func testDefaultIconForName() {
        // Test known system artifact
        XCTAssertEqual(TeamArtifact.defaultIconForName("Product Requirements"), "doc.text")

        // Test unknown artifact (should return default)
        XCTAssertEqual(TeamArtifact.defaultIconForName("Unknown Artifact"), "doc.text")
    }

    // MARK: - Hashable Tests

    func testHashable() {
        let artifact1 = TeamArtifact(
            id: "same-id",
            name: "Artifact 1",
            icon: "doc",
            mimeType: "text/markdown",
            description: "Description 1"
        )

        let artifact2 = TeamArtifact(
            id: "same-id",
            name: "Artifact 1",
            icon: "doc",
            mimeType: "text/markdown",
            description: "Description 1"
        )

        XCTAssertEqual(artifact1, artifact2, "Artifacts with same content should be equal")

        var set = Set<TeamArtifact>()
        set.insert(artifact1)
        set.insert(artifact2)

        XCTAssertEqual(set.count, 1, "Set should contain only one artifact since they are equal")
    }
}
