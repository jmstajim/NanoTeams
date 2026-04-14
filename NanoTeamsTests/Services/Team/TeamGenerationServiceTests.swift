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

    func testDecodeTeamConfig_outerWithMixedEscapingInTools_extractedViaTeamConfigScan() throws {
        // Real gpt-oss-20b regression: model emits properly-escaped JSON for most
        // of the inner config but leaves `"tools":[ "raw","raw"]` un-escaped,
        // which corrupts the outer string boundary. Strict outer parse fails;
        // fallback `extractInnerTeamConfig` walks by brace depth and recovers.
        let arguments = "{\"name\":\"create_team\",\"arguments\":{\"team_config\":\"{\\\"name\\\":\\\"Mixed Escape Team\\\",\\\"description\\\":\\\"d\\\",\\\"roles\\\":[{\\\"name\\\":\\\"Eng\\\",\\\"prompt\\\":\\\"p\\\",\\\"produces_artifacts\\\":[\\\"X\\\"],\\\"requires_artifacts\\\":[\\\"Supervisor Task\\\"],\\\"tools\\\":[\"read_file\",\"write_file\"]}],\\\"artifacts\\\":[{\\\"name\\\":\\\"X\\\",\\\"description\\\":\\\"d\\\"}],\\\"supervisor_requires\\\":[\\\"X\\\"]}\"}}"
        // Sanity: outer strict parse fails because of the bare `"read_file"` quotes.
        XCTAssertNil(JSONUtilities.parseJSONDictionary(arguments))
        let result = try TeamGenerationService.decodeTeamConfig(from: arguments)
        XCTAssertEqual(result.team.name, "Mixed Escape Team")
        let eng = result.team.roles.first { $0.name == "Eng" }
        XCTAssertEqual(eng?.toolIDs, ["read_file", "write_file"])
    }

    func testRepairUnescapedQuotes_innerQuotesEscaped_validJSONUntouched() {
        // Valid JSON should pass through unchanged (quote followed by structural char).
        let valid = "{\"key\":\"value\",\"k2\":[\"a\",\"b\"]}"
        XCTAssertEqual(TeamGenerationService.repairUnescapedInteriorQuotes(valid), valid)
    }

    func testRepairUnescapedQuotes_interiorQuotesGetEscaped() {
        // The model wrote "Produce a "Decision Memo" artifact." with raw interior quotes.
        let bad = "{\"prompt\":\"Produce a \"Decision Memo\" artifact.\"}"
        // After outer JSON decode, the value would contain literal interior quotes:
        // simulate the post-outer-decode form directly here.
        let postDecoded = "{\"prompt\":\"Produce a \"Decision Memo\" artifact.\"}"
        // Re-parse strict will fail; repair, then parse.
        XCTAssertNil(JSONUtilities.parseJSONDictionary(postDecoded))
        let repaired = TeamGenerationService.repairUnescapedInteriorQuotes(postDecoded)
        let parsed = JSONUtilities.parseJSONDictionary(repaired)
        XCTAssertEqual(parsed?["prompt"] as? String, "Produce a \"Decision Memo\" artifact.")
        _ = bad // Suppress unused-warning
    }

    func testDecodeTeamConfig_innerJSONWithUnescapedQuotes_repairsAndDecodes() throws {
        // End-to-end: inner team_config has a role prompt with interior quotes.
        // Outer JSON is well-formed; inner string contains a JSON whose `prompt`
        // value has unescaped `"`. The repair pass should recover it.
        let innerJSON = "{\"name\":\"Quote Repair Team\",\"description\":\"d\",\"roles\":[{\"name\":\"Eng\",\"prompt\":\"Produce a \"Decision Memo\" artifact.\",\"produces_artifacts\":[\"X\"],\"requires_artifacts\":[\"Supervisor Task\"],\"tools\":[]}],\"artifacts\":[{\"name\":\"X\",\"description\":\"d\"}],\"supervisor_requires\":[\"X\"]}"
        // Embed as team_config string. Escape quotes for outer JSON.
        let escaped = innerJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let outer = "{\"team_config\":\"\(escaped)\"}"
        let result = try TeamGenerationService.decodeTeamConfig(from: outer)
        XCTAssertEqual(result.team.name, "Quote Repair Team")
        let eng = result.team.roles.first { $0.name == "Eng" }
        XCTAssertEqual(eng?.prompt, "Produce a \"Decision Memo\" artifact.")
    }

    func testDecodeTeamConfig_innerJSONWithTrailingBrace_stripsAndDecodes() throws {
        // gpt-oss-20b observed appending an extra `}` after the inner JSON
        // legitimately closed. Outer JSON is valid; inner string has one-char
        // trailing junk. The strip-to-balanced pass should recover it.
        let innerWithExtraBrace = "{\"name\":\"Trailing Junk Team\",\"description\":\"d\",\"roles\":[{\"name\":\"Eng\",\"prompt\":\"p\",\"produces_artifacts\":[\"X\"],\"requires_artifacts\":[\"Supervisor Task\"],\"tools\":[]}],\"artifacts\":[{\"name\":\"X\",\"description\":\"d\"}],\"supervisor_requires\":[\"X\"]}}"
        // Embed as team_config value (outer escape `"` and `\`).
        let escaped = innerWithExtraBrace
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"team_config\":\"\(escaped)\"}"
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Trailing Junk Team")
    }

    func testExtractJSON_shallowTruncation_salvagedWithSyntheticClose() {
        // Shallow unbalanced object (depth=1) is now salvaged by appending
        // a synthetic `}` — handles LLM stream truncation.
        let salvaged = TeamGenerationService.extractJSONObject(from: "{\"name\": \"X\"")
        XCTAssertEqual(salvaged, "{\"name\": \"X\"}")
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

    // MARK: - wrapper-shape unwrapping (regression for vague-short parsing failure)

    func testDecodeTeamConfig_createTeamWrapper_unwrapsAndDecodes() throws {
        // Observed from gemma-4-26b-a4b as `<|call|>{"create_team":{"team_config":{...}}}`
        let json = """
        {
            "create_team": {
                "team_config": {
                    "name": "Wrapped Team",
                    "description": "test",
                    "roles": [{"name": "Eng", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
                    "artifacts": [{"name": "X", "description": "code"}],
                    "supervisor_requires": ["X"]
                }
            }
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Wrapped Team")
    }

    func testDecodeTeamConfig_rawToolCallShape_unwrapsAndDecodes() throws {
        // Standard OpenAI tool-call JSON emitted as plain content.
        let json = """
        {
            "name": "create_team",
            "arguments": {
                "team_config": {
                    "name": "Raw Call Team",
                    "description": "test",
                    "roles": [{"name": "Eng", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
                    "artifacts": [{"name": "X", "description": "code"}],
                    "supervisor_requires": ["X"]
                }
            }
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Raw Call Team")
    }

    // MARK: - lenient role-field decoding (regression for `producent_artifacts` typo)

    func testDecodeTeamConfig_roleMissingProducesArtifacts_defaultsToEmpty() throws {
        // Role has the `producent_artifacts` typo → `produces_artifacts` is missing.
        // Should decode successfully and treat the role as advisory, not throw.
        let json = """
        {
            "name": "Typo Team",
            "description": "test",
            "roles": [
                {"name": "Dev", "prompt": "p", "requires_artifacts": ["Supervisor Task"], "tools": [], "producent_artifacts": ["Ignored"]}
            ],
            "artifacts": [],
            "supervisor_requires": []
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        // Supervisor + Dev
        XCTAssertEqual(result.team.roles.count, 2)
        let dev = result.team.roles.first { $0.name == "Dev" }
        XCTAssertEqual(dev?.dependencies.producesArtifacts, [])
    }

    func testDecodeTeamConfig_doublyEscapedInnerJSON_recoversViaUnescape() throws {
        // gpt-oss-20b observed double-escaping nested JSON: after the outer JSON
        // parse, `team_config` still contains literal `\n` and `\"` escape
        // sequences. One more unescape pass makes it parseable.
        // Build: outer JSON where team_config's VALUE (post-outer-parse) will
        // contain `{\n  \"name\": \"T\", ...}` as literal 2-char escape sequences.
        let literalEscapedInner = "{\\n  \\\"name\\\": \\\"Double Escaped Team\\\",\\n  \\\"description\\\": \\\"d\\\",\\n  \\\"roles\\\": [{\\\"name\\\": \\\"Eng\\\", \\\"prompt\\\": \\\"p\\\", \\\"produces_artifacts\\\": [\\\"X\\\"], \\\"requires_artifacts\\\": [\\\"Supervisor Task\\\"], \\\"tools\\\": []}],\\n  \\\"artifacts\\\": [{\\\"name\\\": \\\"X\\\", \\\"description\\\": \\\"d\\\"}],\\n  \\\"supervisor_requires\\\": [\\\"X\\\"]\\n}"
        let json = "{\"team_config\":\"\(literalEscapedInner)\"}"
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Double Escaped Team")
    }

    func testExtractJSON_truncatedOneBraceShort_salvagedWithSyntheticClose() throws {
        // Observed on gpt-oss-20b: stream truncates one `}` short, leaving the
        // content ending with `…]}"}` at final depth 1. The salvage path should
        // append a synthetic close so the inner team config is decodable.
        let truncated = "{\"name\":\"create_team\",\"arguments\":{\"team_config\":\"{\\\"name\\\":\\\"Salvaged Team\\\",\\\"description\\\":\\\"d\\\",\\\"roles\\\":[{\\\"name\\\":\\\"Eng\\\",\\\"prompt\\\":\\\"p\\\",\\\"produces_artifacts\\\":[\\\"X\\\"],\\\"requires_artifacts\\\":[\\\"Supervisor Task\\\"],\\\"tools\\\":[]}],\\\"artifacts\\\":[{\\\"name\\\":\\\"X\\\",\\\"description\\\":\\\"d\\\"}],\\\"supervisor_requires\\\":[\\\"X\\\"]}\"}"
        let extracted = TeamGenerationService.extractJSONObject(from: truncated)
        XCTAssertNotNil(extracted, "Should salvage one missing outer brace")
        let result = try TeamGenerationService.decodeTeamConfig(from: extracted!)
        XCTAssertEqual(result.team.name, "Salvaged Team")
    }

    func testExtractJSON_truncatedDeeperThanSalvageCap_returnsNil() {
        // 4-deep unbalanced object (beyond maxSalvageDepth=3) should NOT be salvaged
        // — that much missing content signals genuinely garbled input.
        let badlyBroken = "{\"a\":{\"b\":{\"c\":{\"d\":\"x\""
        XCTAssertNil(TeamGenerationService.extractJSONObject(from: badlyBroken))
    }

    func testDecodeTeamConfig_artifactWithNullName_droppedNotFatal() throws {
        // gemma-4-26b-a4b under tight timeout sometimes emits a partial artifact
        // with `"name": null` (truncated mid-element). Tolerant per-element
        // decode should drop it and keep the rest of the team.
        let json = """
        {
            "name": "Tolerant Team",
            "description": "d",
            "roles": [
                {"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}
            ],
            "artifacts": [
                {"name": "X", "description": "valid"},
                {"name": null, "description": "broken artifact"}
            ],
            "supervisor_requires": ["X"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        // Only the valid X artifact remains (Supervisor Task auto-added by builder).
        let names = Set(result.team.artifacts.map(\.name))
        XCTAssertTrue(names.contains("X"))
        XCTAssertEqual(names.count, 2, "Expected Supervisor Task + X only; got \(names)")
    }

    func testDecodeTeamConfig_orphanProduced_autoAddedToSupervisorRequires() throws {
        // Role produces an artifact nobody consumes and the model omitted from
        // supervisor_requires. Auto-promote it so the work isn't silently lost.
        let json = """
        {
            "name": "Lonely Producer",
            "description": "d",
            "roles": [
                {"name": "A", "prompt": "p", "produces_artifacts": ["X","Y"], "requires_artifacts": ["Supervisor Task"], "tools": []}
            ],
            "artifacts": [
                {"name": "X", "description": "the consumed one"},
                {"name": "Y", "description": "the orphan"}
            ],
            "supervisor_requires": ["X"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(Set(result.team.supervisorRequiredArtifacts), Set(["X", "Y"]))
    }

    func testDecodeTeamConfig_synthesizedArtifactDescription_borrowsFromProducerPrompt() throws {
        // When the model omits the artifacts list, descriptions are auto-derived
        // from the producing role's prompt (first sentence).
        let json = """
        {
            "name": "Synth",
            "description": "d",
            "roles": [
                {"name": "Researcher", "prompt": "Investigate vector databases and produce a comparison report. Cover throughput and cost.", "produces_artifacts": ["Comparison Report"], "requires_artifacts": ["Supervisor Task"], "tools": []}
            ]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        let art = result.team.artifacts.first { $0.name == "Comparison Report" }
        XCTAssertNotNil(art)
        XCTAssertTrue(art!.description.contains("Investigate vector databases"), "description should borrow from prompt, got: \(art?.description ?? "nil")")
    }

    func testDecodeTeamConfig_translatedSupervisorTask_autoRewritten() throws {
        // qwen3.5-9b-mlx (and other multilingual models) translates the literal
        // "Supervisor Task" identifier when the task language is non-English.
        // The decoder should auto-rewrite phantom requires_artifacts entries
        // (no producer in the team) to "Supervisor Task".
        let json = """
        {
            "name": "Команда исследования",
            "description": "Russian team",
            "roles": [
                {"name": "Researcher", "prompt": "p", "produces_artifacts": ["Report"], "requires_artifacts": ["Задача Супервизора"], "tools": []}
            ],
            "artifacts": [{"name": "Report", "description": "d"}],
            "supervisor_requires": ["Report"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        let role = result.team.roles.first { $0.name == "Researcher" }
        XCTAssertEqual(role?.dependencies.requiredArtifacts, ["Supervisor Task"])
    }

    func testDecodeTeamConfig_validUpstreamProducer_notRewritten() throws {
        // Sanity check: an upstream-produced artifact must NOT be rewritten to
        // "Supervisor Task" — only phantom (no producer) entries get rewritten.
        let json = """
        {
            "name": "Chain",
            "description": "d",
            "roles": [
                {"name": "A", "prompt": "p", "produces_artifacts": ["Mid"], "requires_artifacts": ["Supervisor Task"], "tools": []},
                {"name": "B", "prompt": "p", "produces_artifacts": ["Final"], "requires_artifacts": ["Mid"], "tools": []}
            ],
            "artifacts": [
                {"name": "Mid", "description": "d"},
                {"name": "Final", "description": "d"}
            ],
            "supervisor_requires": ["Final"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        let b = result.team.roles.first { $0.name == "B" }
        XCTAssertEqual(b?.dependencies.requiredArtifacts, ["Mid"], "Upstream-produced artifact must be preserved verbatim")
    }

    func testDecodeTeamConfig_argumentsWrapperWithoutName_unwraps() throws {
        // gpt-oss-20b on multilingual tasks emits `{"arguments":{"team_config":...}}`
        // with no `name` field. Should still unwrap via the partial-tool-call path.
        let inner = """
        {"name":"Команда","description":"d","roles":[{"name":"Разработчик","prompt":"p","produces_artifacts":["Код"],"requires_artifacts":["Supervisor Task"],"tools":[]}],"artifacts":[{"name":"Код","description":"d"}],"supervisor_requires":["Код"]}
        """
        let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"arguments\":{\"team_config\":\"\(escaped)\"}}"
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Команда")
    }

    func testDecodeTeamConfig_teamConfigAsEncodedString_parsesAndUnwraps() throws {
        // Observed from gpt-oss-20b: the model emits `team_config` as a JSON-encoded
        // string instead of a nested object. `CreateTeamTool` handles this at runtime;
        // `TeamGenerationService` now unwraps it here for the bypass path.
        let encodedInner = """
        {"name":"GptOss Team","description":"d","roles":[{"name":"Eng","prompt":"p","produces_artifacts":["X"],"requires_artifacts":["Supervisor Task"],"tools":[]}],"artifacts":[{"name":"X","description":"d"}],"supervisor_requires":["X"]}
        """
        let envelope: [String: Any] = [
            "name": "create_team",
            "arguments": ["team_config": encodedInner],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let json = String(data: data, encoding: .utf8)!
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "GptOss Team")
    }

    func testHarmonyPipeline_gptOssEncodedStringEnvelope_decodesEndToEnd() throws {
        // Full gpt-oss-20b Harmony shape observed in training run (NO <|end|> terminator,
        // matching the real stream from openai/gpt-oss-20b).
        let inner = """
        {"name":"Meal Plan Team","description":"d","supervisor_mode":"manual","roles":[{"name":"Brainstormer","prompt":"p","produces_artifacts":[],"requires_artifacts":["Supervisor Task"],"tools":["ask_supervisor"]}],"artifacts":[],"supervisor_requires":[]}
        """
        // Escape inner JSON as a JSON string value (the way gpt-oss emits it).
        let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let rawContent = "<|channel|>final <|constrain|>create_team<|message|>{\"name\":\"create_team\",\"arguments\":{\"team_config\":\"\(escaped)\"}}"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: rawContent)
        XCTAssertEqual(calls.count, 1, "Harmony parser should extract one call")
        guard let call = calls.first else { return }
        XCTAssertEqual(call.name, "create_team")
        let result = try TeamGenerationService.decodeTeamConfig(from: call.argumentsJSON)
        XCTAssertEqual(result.team.name, "Meal Plan Team")
        XCTAssertTrue(result.team.isChatMode, "empty supervisor_requires + empty produces → chat mode")
    }

    func testDecodeTeamConfig_topLevelArtifactsMissing_defaultsToEmpty() throws {
        // Chat team that omits `artifacts` / `supervisor_requires`.
        let json = """
        {
            "name": "Chat Team",
            "description": "test",
            "roles": [{"name": "Assistant", "prompt": "chat", "requires_artifacts": ["Supervisor Task"], "tools": ["ask_supervisor"]}]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "Chat Team")
        XCTAssertTrue(result.team.supervisorRequiredArtifacts.isEmpty)
    }

    func testDecodeTeamConfig_missingName_synthesizedFromDescription() throws {
        // Real gemma-4-26b-a4b regression: valid team_config with no `name` field.
        // Previously threw keyNotFound → "data couldn't be read because it is missing".
        // Now synthesizes the name from the first sentence of the description.
        let json = """
        {
            "description": "Team to implement a Settings screen in an iOS SwiftUI app with persistence and testing.",
            "roles": [{"name": "Dev", "prompt": "build it", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": ["write_file"]}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        // First-sentence is 88 chars, so the synthesizer clips to 60 chars.
        XCTAssertEqual(
            result.team.name,
            "Team to implement a Settings screen in an iOS SwiftUI app wi"
        )
        XCTAssertEqual(result.team.name.count, 60)
        // Ensure the rest of the team decoded correctly — the synthesis shouldn't perturb roles/artifacts.
        XCTAssertEqual(result.team.roles.count, 2) // Supervisor + Dev
    }

    func testDecodeTeamConfig_missingName_synthesizedFromShortSentence() throws {
        let json = """
        {
            "description": "A specialist team for evaluating vector databases.",
            "roles": [{"name": "Researcher", "prompt": "research", "produces_artifacts": ["Memo"], "requires_artifacts": ["Supervisor Task"], "tools": ["read_file"]}],
            "artifacts": [{"name": "Memo", "description": "d"}],
            "supervisor_requires": ["Memo"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        XCTAssertEqual(result.team.name, "A specialist team for evaluating vector databases")
    }

    func testRepairMissingArrayClose_insertsBracket() {
        // qwen3.5-35b-a3b regression: model drops the inner array's `]` and
        // writes `}]` (role-close + array-close) where it needs `]}]` (tools-
        // close + role-close + array-close).
        let input = #"{"roles":[{"tools":["a","ask_supervisor"}]}"#
        let repaired = TeamGenerationService.repairMissingArrayClose(input)
        XCTAssertEqual(repaired, #"{"roles":[{"tools":["a","ask_supervisor"]}]}"#)
    }

    func testRepairMissingArrayClose_noPattern_returnsNil() {
        XCTAssertNil(TeamGenerationService.repairMissingArrayClose(#"{"a":"b"}"#))
    }

    func testDecodeTeamConfig_qwenMissingArrayClose_recoversViaRepair() throws {
        // Verbatim payload shape from qwen3.5-35b-a3b session 11: the tools
        // array is never closed; the role's `}` immediately follows the last
        // string. Strict parse fails at "Expecting ',' delimiter"; the repair
        // inserts the missing `]` and the config decodes.
        let arguments = """
        {"name":"create_team","arguments":{"team_config":{"name":"Speed Team","description":"d","supervisor_mode":"manual","acceptance_mode":"finalOnly","roles":[{"name":"Strategist","prompt":"p","produces_artifacts":[],"requires_artifacts":["Supervisor Task"],"tools":["read_file","ask_supervisor"}],"artifacts":[],"supervisor_requires":[]}}}
        """
        XCTAssertNil(JSONUtilities.parseJSONDictionary(arguments), "strict parse should fail on the raw payload")
        let result = try TeamGenerationService.decodeTeamConfig(from: arguments)
        XCTAssertEqual(result.team.name, "Speed Team")
        XCTAssertEqual(result.team.isChatMode, true)
    }

    func testDecodeTeamConfig_declaredButUnproducedArtifact_consumerRewrittenToSupervisorTask() throws {
        // Real gemma-4-26b-a4b regression (sessions 8 & 9 `vague-short`/`non-engineering-production`):
        // model declares an artifact in `artifacts[]` AND as a consumer's `requires_artifacts`,
        // but NO role produces it. Previously passed validation (declared = "known") and the
        // engine would stall forever. Fix: narrow the phantom-rewrite producer set to ROLES
        // only, so any un-produced dependency gets redirected to Supervisor Task.
        let json = """
        {
            "name": "Unproduced Artifact Team",
            "description": "d",
            "roles": [
                {"name": "Producer", "prompt": "p1", "produces_artifacts": ["Real Output"], "requires_artifacts": ["Supervisor Task"], "tools": []},
                {"name": "Consumer", "prompt": "p2", "produces_artifacts": ["Final"], "requires_artifacts": ["Unproduced Artifact"], "tools": []}
            ],
            "artifacts": [
                {"name": "Real Output", "description": "d1"},
                {"name": "Unproduced Artifact", "description": "d2"},
                {"name": "Final", "description": "d3"}
            ],
            "supervisor_requires": ["Final"]
        }
        """
        let result = try TeamGenerationService.decodeTeamConfig(from: json)
        let consumer = result.team.roles.first { $0.name == "Consumer" }
        XCTAssertEqual(
            consumer?.dependencies.requiredArtifacts,
            ["Supervisor Task"],
            "Unproduced artifact dependency must be redirected to Supervisor Task to avoid runtime deadlock."
        )
    }

    func testDecodeTeamConfig_missingNameAndDescription_throws() {
        // With neither name nor a description to synthesize from, decoding fails
        // loudly instead of producing a blank team. (The decode error is wrapped
        // by GenerationError.invalidResponse, so we only check that it throws.)
        let json = """
        {
            "roles": [{"name": "Dev", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """
        XCTAssertThrowsError(try TeamGenerationService.decodeTeamConfig(from: json))
    }
}
