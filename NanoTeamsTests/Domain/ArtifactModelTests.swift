import XCTest
@testable import NanoTeams

final class ArtifactModelTests: XCTestCase {

    // MARK: - Computed ID

    func testID_computedFromSlugifiedName() {
        let artifact = Artifact(name: "Product Requirements")
        XCTAssertEqual(artifact.id, "product_requirements")
    }

    func testID_lowercasedAndUnderscored() {
        let artifact = Artifact(name: "Design Spec")
        XCTAssertEqual(artifact.id, "design_spec")
    }

    // MARK: - slugify

    func testSlugify_spacesToUnderscores() {
        XCTAssertEqual(Artifact.slugify("Hello World"), "hello_world")
    }

    func testSlugify_filtersSpecialCharacters() {
        XCTAssertEqual(Artifact.slugify("Test (v2)!"), "test_v2")
    }

    func testSlugify_emptyString() {
        XCTAssertEqual(Artifact.slugify(""), "")
    }

    func testSlugify_preservesNumbers() {
        XCTAssertEqual(Artifact.slugify("Version 2 Release"), "version_2_release")
    }

    func testSlugify_multipleSpaces() {
        XCTAssertEqual(Artifact.slugify("A   B"), "a___b")
    }

    // MARK: - Codable roundtrip

    func testCodable_roundtrip() throws {
        let artifact = Artifact(
            name: "Test Artifact",
            icon: "star",
            mimeType: "application/json",
            description: "A test"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(artifact)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Artifact.self, from: data)

        XCTAssertEqual(decoded.name, artifact.name)
        XCTAssertEqual(decoded.icon, artifact.icon)
        XCTAssertEqual(decoded.mimeType, artifact.mimeType)
        XCTAssertEqual(decoded.description, artifact.description)
        XCTAssertEqual(decoded.id, artifact.id)
    }

    // MARK: - Decoder defaults

    func testDecoder_missingOptionalFields_usesDefaults() throws {
        let json = """
        {"name": "Minimal"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let artifact = try decoder.decode(Artifact.self, from: json)
        XCTAssertEqual(artifact.name, "Minimal")
        XCTAssertEqual(artifact.icon, "doc.text")
        XCTAssertEqual(artifact.mimeType, "text/markdown")
        XCTAssertEqual(artifact.description, "")
        XCTAssertNil(artifact.relativePath)
        XCTAssertFalse(artifact.isSystem)
    }

    // MARK: - defaultIconForName

    func testDefaultIconForName_knownArtifact() {
        // SystemTemplates.artifacts contains known artifact templates
        let icon = Artifact.defaultIconForName("Supervisor Task")
        // Should return a non-default icon from templates
        XCTAssertFalse(icon.isEmpty)
    }

    func testDefaultIconForName_unknownArtifact() {
        XCTAssertEqual(Artifact.defaultIconForName("totally_unknown_artifact_xyz"), "doc.text")
    }

    // MARK: - Hashable / Equatable

    func testHashable_sameFields_equal() {
        let date = Date(timeIntervalSince1970: 1000)
        let a = Artifact(name: "Test", createdAt: date, updatedAt: date)
        let b = Artifact(name: "Test", createdAt: date, updatedAt: date)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testHashable_differentName_notEqual() {
        let date = Date(timeIntervalSince1970: 1000)
        let a = Artifact(name: "Alpha", createdAt: date, updatedAt: date)
        let b = Artifact(name: "Beta", createdAt: date, updatedAt: date)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Init defaults

    func testInit_defaultValues() {
        let artifact = Artifact(name: "Simple")
        XCTAssertEqual(artifact.icon, "doc.text")
        XCTAssertEqual(artifact.mimeType, "text/markdown")
        XCTAssertEqual(artifact.description, "")
        XCTAssertNil(artifact.relativePath)
        XCTAssertFalse(artifact.isSystem)
    }

    // MARK: - llmReadablePath

    func testLLMReadablePath_normalPath_prependsNanoteamsPrefix() {
        let artifact = Artifact(
            name: "Design Spec",
            relativePath: "tasks/1/runs/0/roles/x/artifact_y.md"
        )
        XCTAssertEqual(
            artifact.llmReadablePath,
            ".nanoteams/tasks/1/runs/0/roles/x/artifact_y.md",
            "A persisted artifact's read path must carry the .nanoteams/ prefix the file tools resolve against."
        )
    }

    func testLLMReadablePath_nilRelativePath_returnsNil() {
        let artifact = Artifact(name: "Draft", relativePath: nil)
        XCTAssertNil(artifact.llmReadablePath, "No persisted file → no readable path.")
    }

    func testLLMReadablePath_emptyRelativePath_returnsNil() {
        let artifact = Artifact(name: "Draft", relativePath: "")
        XCTAssertNil(artifact.llmReadablePath, "Empty relativePath → no readable path.")
    }

    func testLLMReadablePath_internalPath_returnsNil() {
        // Build Diagnostics et al. persist under .nanoteams/internal/, which the sandbox
        // blocks. A non-nil return is a promise of readability, so internal paths must be nil.
        let artifact = Artifact(
            name: "Build Diagnostics",
            relativePath: "internal/tasks/7/runs/0/roles/x/build_diagnostics.json"
        )
        XCTAssertNil(
            artifact.llmReadablePath,
            "Internal artifacts are sandbox-blocked — read path must be nil, not an unreadable reference."
        )
    }

    func testLLMReadablePath_whitespaceOnlyRelativePath_returnsNil() {
        let artifact = Artifact(name: "Draft", relativePath: "   \n")
        XCTAssertNil(
            artifact.llmReadablePath,
            "Whitespace-only relativePath is not a persisted file — must not become .nanoteams/<spaces>."
        )
    }

    func testLLMReadablePath_bareFilename_returnsNil() {
        // A persisted artifact always lives nested (tasks/…/roles/…/artifact_*.md). A bare
        // filename (no "/") can only come from a malformed relativePath; ".nanoteams/<bare>"
        // does not exist on disk, so honoring the readability promise means returning nil.
        let artifact = Artifact(name: "Stray", relativePath: "artifact_stray.md")
        XCTAssertNil(
            artifact.llmReadablePath,
            "A non-nested relativePath is not a real artifact location — must not be advertised."
        )
    }
}
