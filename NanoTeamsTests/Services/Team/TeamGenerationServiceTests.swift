import XCTest
@testable import NanoTeams

final class TeamGenerationServiceTests: XCTestCase {

    // MARK: - extractJSONObject

    func testExtractJSON_rawObject() {
        let input = #"{"name": "Team", "roles": []}"#
        XCTAssertEqual(TeamGenerationService.extractJSONObject(from: input), input)
    }

    func testExtractJSON_codeFencedJSON() {
        let input = """
            Here is the team:
            ```json
            {"name": "Team"}
            ```
            That's it.
            """
        let result = TeamGenerationService.extractJSONObject(from: input)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), #"{"name": "Team"}"#)
    }

    func testExtractJSON_codeFencedNoLang() {
        let input = """
            ```
            {"name": "X"}
            ```
            """
        let result = TeamGenerationService.extractJSONObject(from: input)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), #"{"name": "X"}"#)
    }

    func testExtractJSON_proseWrapped() {
        let input = "I'll build a team. Here is the config: {\"name\":\"Alpha\",\"roles\":[]} — ready to use."
        let result = TeamGenerationService.extractJSONObject(from: input)
        XCTAssertEqual(result, #"{"name":"Alpha","roles":[]}"#)
    }

    func testExtractJSON_nestedObjects() {
        let input = #"{"name": "Team", "roles": [{"name": "A"}]}"#
        XCTAssertEqual(TeamGenerationService.extractJSONObject(from: input), input)
    }

    func testExtractJSON_stringContainingBraces() {
        let input = #"{"prompt": "Handle { and } chars", "name": "X"}"#
        XCTAssertEqual(TeamGenerationService.extractJSONObject(from: input), input)
    }

    func testExtractJSON_noJSON_returnsNil() {
        XCTAssertNil(TeamGenerationService.extractJSONObject(from: "No braces here at all."))
    }

    func testExtractJSON_unbalancedBraces_returnsNil() {
        XCTAssertNil(TeamGenerationService.extractJSONObject(from: "{\"name\": \"X\""))
    }

    func testExtractJSON_uppercaseJsonLangTag_handled() {
        // Some models emit ```JSON (capitalized).
        let input = """
            ```JSON
            {"name": "Upper"}
            ```
            """
        let result = TeamGenerationService.extractJSONObject(from: input)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), #"{"name": "Upper"}"#)
    }

    func testExtractJSON_multipleFencedBlocks_firstWins() {
        // First fenced block should win, not the second.
        let input = """
            Here's the team:
            ```json
            {"name": "First"}
            ```
            And another option:
            ```json
            {"name": "Second"}
            ```
            """
        let result = TeamGenerationService.extractJSONObject(from: input)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), #"{"name": "First"}"#)
    }

    func testExtractJSON_unclosedFencedBlock_fallsBackToRawScan() {
        // A model emits ```json but forgets the closing fence — we should still find
        // the raw JSON object via the final fallback scan.
        let input = """
            Here's it:
            ```json
            {"name": "Salvaged"}
            (no closing fence)
            """
        let result = TeamGenerationService.extractJSONObject(from: input)
        XCTAssertEqual(result, #"{"name": "Salvaged"}"#)
    }

    func testExtractJSON_escapedQuoteInString_doesNotConfuseScanner() {
        // The scanner must respect `\"` inside a string and not see it as a string boundary.
        let input = #"{"name": "He said \"hi\"", "x": 1}"#
        XCTAssertEqual(TeamGenerationService.extractJSONObject(from: input), input)
    }

    func testExtractJSON_emptyString_returnsNil() {
        XCTAssertNil(TeamGenerationService.extractJSONObject(from: ""))
    }

    func testExtractJSON_onlyWhitespace_returnsNil() {
        XCTAssertNil(TeamGenerationService.extractJSONObject(from: "   \n\t  "))
    }

    // MARK: - decodeTeamConfig: shape precedence

    func testDecodeTeamConfig_nestedShape_takesPrecedenceOverFlat() throws {
        // When BOTH a top-level "name" AND a nested "team_config.name" exist, the
        // nested value must win. The orchestrator passes the entire arguments dict
        // and the nested form is the canonical create_team contract.
        let json = """
        {
            "name": "DECOY_outer",
            "description": "outer",
            "team_config": {
                "name": "Real Team",
                "description": "inner",
                "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
                "artifacts": [{"name": "X", "description": "d"}],
                "supervisor_requires": ["X"]
            }
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Real Team",
                       "Nested team_config.name must take precedence over outer name")
    }

    func testDecodeTeamConfig_teamConfigAsString_fallsThroughToFlat() throws {
        // If team_config is a non-dict (here: a stringified JSON), the dict-cast fails
        // and we treat the outer object as flat. The decoder then fails because the
        // flat object lacks required fields — that's the expected behavior, not a crash.
        let json = """
        {
            "name": "Flat",
            "description": "d",
            "team_config": "this is a string, not an object",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """
        // Decoder reads outer fields, ignores `team_config` since it's not a dict.
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Flat")
    }

    // MARK: - Warnings surface from decode

    func testDecodeTeamConfig_droppedTools_surfacedAsWarnings() throws {
        let json = """
        {
            "name": "T",
            "description": "d",
            "roles": [{"name": "Eng", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": ["read_file", "made_up_tool"]}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.warnings.joined().contains("made_up_tool"))
    }

    // MARK: - GenerationError descriptions

    func testGenerationError_noResponse_hasUserFacingMessage() {
        let err = TeamGenerationService.GenerationError.noResponse
        XCTAssertNotNil(err.errorDescription)
        XCTAssertFalse(err.errorDescription?.isEmpty ?? true)
    }

    func testGenerationError_invalidResponse_includesUnderlyingMessage() {
        let err = TeamGenerationService.GenerationError.invalidResponse("my detail")
        XCTAssertTrue(err.errorDescription?.contains("my detail") ?? false)
    }

    // MARK: - decodeTeamConfig

    func testDecodeTeamConfig_validConfig_returnsTeam() throws {
        let json = """
        {
            "team_config": {
                "name": "Dev Team",
                "description": "test",
                "roles": [
                    {"name": "Eng", "prompt": "build", "produces_artifacts": ["Code"], "requires_artifacts": ["Supervisor Task"], "tools": []}
                ],
                "artifacts": [{"name": "Code", "description": "code"}],
                "supervisor_requires": ["Code"]
            }
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Dev Team")
        XCTAssertEqual(result.team.roles.count, 2) // Supervisor + Eng
    }

    func testDecodeTeamConfig_flatShape_returnsTeam() throws {
        let json = """
        {
            "name": "Flat Team",
            "description": "test",
            "roles": [
                {"name": "Eng", "prompt": "build", "produces_artifacts": ["Code"], "requires_artifacts": ["Supervisor Task"], "tools": []}
            ],
            "artifacts": [{"name": "Code", "description": "code"}],
            "supervisor_requires": ["Code"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Flat Team")
    }

    func testDecodeTeamConfig_emptyRoles_throws() {
        let json = """
        {"name": "Empty", "description": "no roles", "roles": [], "artifacts": [], "supervisor_requires": []}
        """
        XCTAssertThrowsError(try TeamGenerationService.decodeTeamConfig(from: json))
    }

    func testDecodeTeamConfig_invalidJSON_throws() {
        XCTAssertThrowsError(try TeamGenerationService.decodeTeamConfig(from: "not json"))
    }
}
