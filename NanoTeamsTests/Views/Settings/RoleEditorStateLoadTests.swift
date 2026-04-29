import XCTest
@testable import NanoTeams

/// Pins `RoleEditorState.load(from:)` field-seeding semantics.
///
/// The role editor no longer has a master "Custom LLM" toggle — fields
/// are always visible, and the override is computed at save time based
/// on field content (`isEmpty ⇒ nil`). These tests verify that load
/// correctly populates each individual field from a stored override
/// without depending on any aggregate "enabled" flag.
final class RoleEditorStateLoadTests: XCTestCase {

    private func makeRole(llmOverride: LLMOverride?) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "test-role",
            name: "Test",
            icon: "person.fill",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            llmOverride: llmOverride,
            isSystemRole: false,
            systemRoleID: nil,
            iconColor: "#FFFFFF",
            iconBackground: "#007AFF",
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testLoad_nilOverride_fieldsRemainEmpty() {
        var state = RoleEditorState()
        state.load(from: makeRole(llmOverride: nil))
        XCTAssertEqual(state.llmBaseURL, "")
        XCTAssertEqual(state.llmModelName, "")
        XCTAssertEqual(state.overrideMaxTokens, 0)
        XCTAssertNil(state.overrideTemperature)
    }

    func testLoad_emptyButNonNilOverride_fieldsRemainEmpty() {
        var state = RoleEditorState()
        state.load(from: makeRole(llmOverride: LLMOverride()))
        XCTAssertEqual(state.llmBaseURL, "")
        XCTAssertEqual(state.llmModelName, "")
        XCTAssertEqual(state.overrideMaxTokens, 0)
        XCTAssertNil(state.overrideTemperature)
    }

    func testLoad_modelOnlyOverride_seedsModelOnly() {
        var state = RoleEditorState()
        state.load(from: makeRole(llmOverride: LLMOverride(modelName: "qwen-14b")))
        XCTAssertEqual(state.llmModelName, "qwen-14b")
        XCTAssertEqual(state.llmBaseURL, "")
    }

    func testLoad_serverOnlyOverride_seedsURLOnly() {
        var state = RoleEditorState()
        state.load(from: makeRole(llmOverride: LLMOverride(baseURLString: "http://192.168.1.10:1234")))
        XCTAssertEqual(state.llmBaseURL, "http://192.168.1.10:1234")
        XCTAssertEqual(state.llmModelName, "")
    }

    func testLoad_fullOverride_seedsAllFields() {
        var state = RoleEditorState()
        let override = LLMOverride(
            baseURLString: "http://x:1234",
            modelName: "m",
            maxTokens: 8192,
            temperature: 0.42
        )
        state.load(from: makeRole(llmOverride: override))
        XCTAssertEqual(state.llmBaseURL, "http://x:1234")
        XCTAssertEqual(state.llmModelName, "m")
        XCTAssertEqual(state.overrideMaxTokens, 8192)
        XCTAssertEqual(state.overrideTemperature ?? .nan, 0.42, accuracy: 1e-9)
    }
}
