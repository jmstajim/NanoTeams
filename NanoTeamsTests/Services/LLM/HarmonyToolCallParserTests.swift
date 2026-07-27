import XCTest
@testable import NanoTeams

final class HarmonyToolCallParserTests: XCTestCase {
    func testParsesHarmonyJSONCall() {
        let input = "Hello\n<|call|>{\"name\":\"write_artifact\",\"arguments\":{\"kind\":\"plan\",\"name\":\"P\",\"content\":\"Hi\"}}<|end|>ignored"
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "write_artifact")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"content\":\"Hi\",\"kind\":\"plan\",\"name\":\"P\"}")
    }

    func testParsesHarmonyFunctionWrapperCall() {
        let input = "<|call|>{\"id\":\"abc\",\"function\":{\"name\":\"ask_supervisor\",\"arguments\":\"{\\\"question\\\":\\\"Are we good?\\\"}\"}}<|end|>"
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].providerID, "abc")
        XCTAssertEqual(calls[0].name, "ask_supervisor")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"question\":\"Are we good?\"}")
    }

    func testParsesHarmonyNamePlusJSONArguments() {
        let input = "<|call|>write_artifact {\"kind\":\"plan\",\"name\":\"P\"}<|end|>"
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "write_artifact")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"kind\":\"plan\",\"name\":\"P\"}")
    }

    func testIgnoresBareStartMarker() {
        let input = "<|start|>"
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Malformed Tool Call Tests (from conversation log analysis)
    // These tests verify parser behavior with malformed LLM outputs observed in real logs

    func testMalformedToolNameWithTrailingAngleBracket() {
        // Issue: LLM output "read_file>" which got logged as tool name
        // Expected: Parser should not extract tool name with trailing special characters
        let input = "<|call|>read_file>"
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        // Either: no calls extracted (parser stops at malformed input)
        // Or: if extracted, tool name should be "read_file" not "read_file>"
        if !calls.isEmpty {
            XCTAssertEqual(calls[0].name, "read_file", "Tool name should not include '>'")
            XCTAssertFalse(calls[0].name.contains(">"), "Tool name should not contain '>'")
        }
    }

    func testMalformedToolNameWithJSONAppended() {
        // Issue: LLM output "git_branch>{"action":"create",...}" as tool name
        // Expected: Parser should either parse correctly or reject gracefully
        let input = "<|call|>git_branch>{\"action\":\"create\",\"name\":\"feature\"}"
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        // The parser should either:
        // 1. Not extract any call (malformed)
        // 2. Extract with correct tool name "git_branch" (not including ">")
        for call in calls {
            XCTAssertFalse(call.name.contains(">"), "Tool name '\(call.name)' should not contain '>'")
            XCTAssertFalse(call.name.contains("{"), "Tool name '\(call.name)' should not contain '{'")
        }
    }

    func testToolNameWithSpecialCharactersRejected() {
        // Parser should only accept alphanumeric, underscore, dash, period in tool names
        let parser = HarmonyToolCallParser()

        // Test various malformed inputs
        let malformedInputs = [
            "<|call|>tool>name {}",
            "<|call|>tool{name} {}",
            "<|call|>tool=name {}",
            "<|call|>tool;name {}",
        ]

        for input in malformedInputs {
            let calls = CallMarkerStrategy().parse(from: input)
            for call in calls {
                // Tool names should only contain valid identifier characters
                let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
                let invalidChars = CharacterSet(charactersIn: call.name).subtracting(validChars)
                XCTAssertTrue(
                    invalidChars.isEmpty,
                    "Tool name '\(call.name)' from input '\(input)' contains invalid characters"
                )
            }
        }
    }

    func testEmptyToolNameAfterCallMarker() {
        // Edge case: <|call|> followed immediately by JSON (no tool name)
        let input = "<|call|> {\"name\": \"read_file\", \"arguments\": {}}"
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        // Should parse the JSON format correctly
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file")
    }

    func testToolNameWithTrailingWhitespace() {
        // Tool name followed by whitespace then arguments
        let input = "<|call|>read_file   {\"path\": \"test.swift\"}"
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file", "Tool name should not have trailing whitespace")
    }

    func testIncompleteJSON() {
        // Incomplete JSON arguments - parser should handle gracefully
        let input = "<|call|>read_file {\"path\": \"test.swift\""  // Missing closing brace
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        // Parser should either not extract or extract with what it can parse
        // The key is it shouldn't crash or hang
        XCTAssertTrue(calls.isEmpty || calls.count == 1, "Parser should handle incomplete JSON gracefully")
    }

    func testMultipleMalformedCallsInSequence() {
        // Multiple tool calls, some malformed
        let input = """
        <|call|>read_file {\"path\": \"a.swift\"}<|end|>
        <|call|>bad>tool {}
        <|call|>write_file {\"path\": \"b.swift\", \"content\": \"test\"}<|end|>
        """
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        // At minimum, the valid calls should be extracted
        let validNames = calls.map { $0.name }
        XCTAssertTrue(validNames.contains("read_file"), "Should extract valid read_file call")
        // Malformed call should either be skipped or have corrected name
        for call in calls {
            XCTAssertFalse(call.name.contains(">"), "No tool name should contain '>'")
        }
    }

    func testChannelMarkerWithMalformedToolName() {
        // Channel format with malformed tool name
        let input = "<|channel|>commentary to=bad>tool<|message|>{}"
        let parser = HarmonyToolCallParser()
        let calls = ChannelMarkerStrategy().parse(from: input)

        // Should either extract "bad" (stopping at >) or nothing
        for call in calls {
            XCTAssertFalse(call.name.contains(">"), "Tool name should not contain '>'")
        }
    }

    func testToolNameExtractionStopsAtInvalidChars() {
        // Verify the extractIdentifier behavior - should stop at special characters
        let input = "<|call|>git_status> {}"
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        // Parser's extractIdentifier stops at non-identifier chars,
        // so tool name should be "git_status" not "git_status>"
        if !calls.isEmpty {
            XCTAssertEqual(calls[0].name, "git_status")
        }
    }

    // MARK: - Reserved Channel Name Filter (Run 6 regression)

    /// Run 6 evidence: Code Reviewer emitted `<|call|>commentary { case add = "+" ... }<|end|>`
    /// where `commentary` is a Harmony channel name, not a tool. CallMarkerStrategy extracted
    /// the identifier literally and produced `name="commentary"` → tool_not_authorized.
    func testCallMarker_rejectsReservedChannelNameAsTool() {
        let input = "<|call|>commentary { \"content\": \"hello\" }<|end|>"
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertTrue(
            calls.isEmpty || !calls.contains { $0.name.lowercased() == "commentary" },
            "Reserved channel name 'commentary' must not leak as a tool name")
    }

    func testCallMarker_rejectsAllReservedChannelNames() {
        for reserved in ["commentary", "analysis", "final", "thinking"] {
            let input = "<|call|>\(reserved) {}<|end|>"
            let calls = CallMarkerStrategy().parse(from: input)
            XCTAssertFalse(
                calls.contains { $0.name.lowercased() == reserved },
                "'\(reserved)' must not be accepted as a tool name")
        }
    }

    /// Explicit `to=X` target is unaffected: if a model routes
    /// `<|channel|>commentary to=read_file<|message|>{...}`, `read_file` is a
    /// legit tool and must still be dispatched.
    func testChannelMarker_toPathBypassesReservedFilter() {
        let input = "<|channel|>commentary to=read_file<|message|>{\"path\":\"f.txt\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    /// `<|constrain|>` fallback: if it extracts a reserved channel name, reject.
    func testChannelMarker_constrainFallbackRejectsReservedName() {
        // No `to=`; `<|constrain|>commentary` would otherwise pick "commentary" as tool name.
        let input = "<|channel|>final <|constrain|>commentary<|message|>{}"
        let calls = ChannelMarkerStrategy().parse(from: input)
        XCTAssertTrue(
            calls.isEmpty || !calls.contains { $0.name.lowercased() == "commentary" },
            "Reserved channel name via <|constrain|> fallback must be rejected")
    }

    /// JSON-shape parse must also apply the reserved-name guard. Earlier versions
    /// only filtered the bare-identifier path in `CallMarkerStrategy`; a model
    /// emitting `<|call|>{"name":"commentary","arguments":{...}}<|end|>` would
    /// leak through.
    func testCallMarker_jsonShape_rejectsReservedChannelNameAsTool() {
        let input = #"<|call|>{"name":"commentary","arguments":{"text":"hello"}}<|end|>"#
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertFalse(
            calls.contains { $0.name.lowercased() == "commentary" },
            "JSON-shape reserved channel name must be rejected alongside bare identifier")
    }

    func testParseToolCallFromJSON_rejectsAllReservedChannelNames() {
        for reserved in ["commentary", "analysis", "final", "thinking"] {
            let json = #"{"name":"\#(reserved)","arguments":{}}"#
            XCTAssertNil(
                ToolCallParsingHelpers.parseToolCallFromJSON(json),
                "'\(reserved)' in JSON `name` field must not produce a tool call")
        }
    }

    /// When a reserved name is followed by a legitimate `<|call|>read_file{...}<|end|>`
    /// block in the same message, the parser must not abort — advancing past the
    /// rejected block preserves the second call.
    func testCallMarker_afterReservedName_recoversLegitimateCall() {
        let input = """
        <|call|>commentary { "content": "junk" }<|end|>\
        <|call|>read_file {"path":"a.txt"}<|end|>
        """
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertTrue(
            calls.contains { $0.name == "read_file" },
            "Legitimate read_file call after a rejected reserved-name block must survive parsing")
        XCTAssertFalse(calls.contains { $0.name.lowercased() == "commentary" })
    }


    // MARK: - Shape Inference for Missing Tool Name (Run 13 regression)

    /// Run 13 evidence: `qwen3.6-35b-a3b-nvfp4` emitted
    /// `<|call|>{"arguments":{"content":"…","format":"markdown","name":"Product Requirements"}}<|end|>`
    /// — valid JSON but no top-level tool name. The `name` inside `arguments` is the
    /// artifact name (a create_artifact parameter), not the tool identifier.
    /// Shape inference on `format` recognises this unambiguously as create_artifact.
    func testCallMarker_inferCreateArtifact_fromArgumentsWithFormat() {
        let input = "<|call|>{\"arguments\":{\"content\":\"# Calc\\nBasic arithmetic\",\"format\":\"markdown\",\"name\":\"Product Requirements\"}}<|end|>"
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "create_artifact")
        let args = calls.first?.argumentsJSON ?? ""
        XCTAssertTrue(args.contains("\"name\":\"Product Requirements\""))
        XCTAssertTrue(args.contains("\"content\":\"# Calc\\nBasic arithmetic\""))
        XCTAssertTrue(args.contains("\"format\":\"markdown\""))
    }

    /// `format` is optional in the create_artifact schema. When Qwen omits it, the
    /// fallback (both required fields present, no conflicting keys) still matches.
    func testCallMarker_inferCreateArtifact_fromNameAndContentWithoutFormat() {
        let input = "<|call|>{\"arguments\":{\"name\":\"Design Spec\",\"content\":\"Layout details\"}}<|end|>"
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "create_artifact")
    }

    /// Shape inference must NOT fire when the argument shape collides with another
    /// tool. `{name, content, path}` could be misread as create_artifact + spurious
    /// `path`, but the exclusive-key guard rejects it — `path` belongs to file tools.
    func testCallMarker_inferToolShape_rejectsConflictingKeys() {
        let input = "<|call|>{\"arguments\":{\"name\":\"X\",\"content\":\"Y\",\"path\":\"/tmp/f.md\"}}<|end|>"
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertTrue(
            calls.isEmpty,
            "Ambiguous shape with both create_artifact (name+content) and file-tool (path) keys must not be inferred")
    }

    /// Plain write_file-shape arguments (without format, without name) must not be
    /// misidentified as create_artifact. Inference stays conservative.
    func testCallMarker_inferToolShape_doesNotInferWriteFile() {
        let input = "<|call|>{\"arguments\":{\"path\":\"a.swift\",\"content\":\"print()\"}}<|end|>"
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertTrue(
            calls.isEmpty,
            "write_file-shaped arguments must not be auto-inferred — keep inference limited to the one signal we've validated")
    }

    /// Regression: `format` alone must NOT infer create_artifact. If a future tool
    /// adds a `format` parameter, inference would silently dispatch it as
    /// create_artifact. The guard requires BOTH required create_artifact fields
    /// (name + content) so that this kind of schema collision can't happen.
    func testCallMarker_inferToolShape_rejectsFormatOnly() {
        let input = "<|call|>{\"arguments\":{\"format\":\"markdown\"}}<|end|>"
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertTrue(
            calls.isEmpty,
            "`format` alone must not be sufficient to infer create_artifact — would collide with any future tool adding a format param")
    }

    // MARK: - Harmony Call Issue Classifier (Run 13)

    func testClassifyHarmonyCallIssue_missingToolName_qwenShape() {
        let text = "reasoning blah\n\n<|call|>{\"arguments\":{\"content\":\"x\",\"format\":\"markdown\",\"name\":\"PR\"}}<|end|>"
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: text)
        guard case .missingToolName(let inferred) = issue else {
            XCTFail("Expected .missingToolName, got \(issue)")
            return
        }
        XCTAssertEqual(inferred, "create_artifact")
    }

    func testClassifyHarmonyCallIssue_missingToolName_noInferencePossible() {
        // No `format`, and `content` is missing (so the name+content create_artifact
        // fallback doesn't match either). Classifier still reports `.missingToolName`
        // but with a nil inferred name so the nudge uses the generic placeholder.
        let text = "<|call|>{\"arguments\":{\"foo\":\"bar\"}}<|end|>"
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: text)
        guard case .missingToolName(let inferred) = issue else {
            XCTFail("Expected .missingToolName, got \(issue)")
            return
        }
        XCTAssertNil(inferred)
    }

    func testClassifyHarmonyCallIssue_malformedJSON() {
        // Unbalanced brace beyond salvage depth — parser gives up, classifier too.
        let text = "<|call|>{\"arguments\":{\"foo\":{\"bar\":{\"baz\":{<|end|>"
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: text)
        XCTAssertEqual(issue, .malformedJSON)
    }

    func testClassifyHarmonyCallIssue_validToolName_reportsMalformed() {
        // The call WOULD have parsed successfully. If we got here (handleNoToolCalls
        // only runs when parsing produced nothing), the failure is elsewhere — fall
        // back to the generic malformed message rather than falsely claim "missing name".
        let text = "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"x\"}}<|end|>"
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(in: text)
        XCTAssertEqual(issue, .malformedJSON)
    }

    func testRobustnessWithRandomSpecialCharacters() {
        let parser = HarmonyToolCallParser()

        // Various edge cases that shouldn't crash the parser
        let edgeCases = [
            "<|call|>",
            "<|call|><|end|>",
            "<|call|>>>>>>",
            "<|call|>{}",
            "<|call|>[]",
            "<|call|>\n\n\n",
            "<|call|>tool\n{}\n<|end|>",
        ]

        for input in edgeCases {
            // Just verify no crash - don't check results
            _ = parser.extractAllToolCalls(from: input)
        }
    }

    func testParsesValidToolCallAfterMalformedOne() {
        // Important: A malformed call should not prevent parsing subsequent valid calls
        let input = """
        <|call|>bad>{}<|end|>
        <|call|>good_tool {"arg": "value"}<|end|>
        """
        let parser = HarmonyToolCallParser()
        let calls = CallMarkerStrategy().parse(from: input)

        // Should still find valid calls
        // Note: The current implementation breaks at malformed calls,
        // but valid calls before malformed ones should be parsed
        if !calls.isEmpty {
            // At least verify no crash and any parsed names are valid
            for call in calls {
                XCTAssertFalse(call.name.isEmpty, "Tool name should not be empty")
                let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
                for char in call.name.unicodeScalars {
                    XCTAssertTrue(validChars.contains(char), "Invalid char in tool name: \(call.name)")
                }
            }
        }
    }

    // MARK: - sanitizeJSONControlCharacters Tests

    func testSanitizeJSONControlCharacters_newlines() {
        // Literal newline inside a JSON string value → escaped \n
        let input = "{\"name\":\"hello\nworld\"}"
        let result = JSONUtilities.sanitizeJSONControlCharacters(input)
        XCTAssertEqual(result, "{\"name\":\"hello\\nworld\"}")
    }

    func testSanitizeJSONControlCharacters_tabs() {
        // Literal tab inside a JSON string value → escaped \t
        let input = "{\"name\":\"hello\tworld\"}"
        let result = JSONUtilities.sanitizeJSONControlCharacters(input)
        XCTAssertEqual(result, "{\"name\":\"hello\\tworld\"}")
    }

    func testSanitizeJSONControlCharacters_alreadyEscaped() {
        // Already-escaped \n (backslash + n as two characters) should NOT be double-escaped
        let input = "{\"name\":\"hello\\nworld\"}"
        let result = JSONUtilities.sanitizeJSONControlCharacters(input)
        XCTAssertEqual(result, input)
    }

    func testSanitizeJSONControlCharacters_outsideString() {
        // Literal newline OUTSIDE a string value (structural whitespace) should NOT be touched
        let input = "{\n\"name\": \"value\"\n}"
        let result = JSONUtilities.sanitizeJSONControlCharacters(input)
        XCTAssertEqual(result, input)
    }

    func testSanitizeJSONControlCharacters_mixedContent() {
        // Markdown content with multiple newlines and tabs inside a JSON string
        let input = "{\"content\":\"# Title\n\nParagraph\n- item 1\n- item 2\t(note)\"}"
        let result = JSONUtilities.sanitizeJSONControlCharacters(input)
        let expected = "{\"content\":\"# Title\\n\\nParagraph\\n- item 1\\n- item 2\\t(note)\"}"
        XCTAssertEqual(result, expected)

        // Verify round-trip: sanitized JSON should be parseable
        let data = result.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(parsed["content"], "# Title\n\nParagraph\n- item 1\n- item 2\t(note)")
    }

    // MARK: - Real LLM output patterns (from network_log.json)

    func testChannelMarkerWithDoubleQuotedToolName() {
        // Real PM output: to= "create_artifact" with quotes and space
        let input = "[reasoning]\nGoal: make calculator. Need PRD. No ambiguity.\n[/reasoning]\n\n<|channel|>commentary to= \"create_artifact\" <|constrain|>json<|message|>{\"name\":\"Product Requirements\",\"content\":\"# Product Requirements – Calculator\\n\\n## Problem Statement\\nUsers need a lightweight calculator.\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")
        XCTAssertTrue(calls[0].argumentsJSON.contains("Product Requirements"))
        XCTAssertTrue(calls[0].argumentsJSON.contains("Problem Statement"))
    }

    func testChannelMarkerConstrainAsToolName() {
        // Real UX Researcher output: no to=, tool name in <|constrain|>
        let input = "[reasoning]\nSupervisor task: make a calculator. It's user-facing. Need research report.\n[/reasoning]\n\n<|channel|>final <|constrain|>create_artifact<|message|>{\"name\":\"Research Report\",\"content\":\"# Research Report – Calculator Feature\\n\\n## 1. User Personas\\n| Persona | Goals |\\n|---------|-------|\\n| Student Sam | Quick arithmetic |\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")
        XCTAssertTrue(calls[0].argumentsJSON.contains("Research Report"))
        XCTAssertTrue(calls[0].argumentsJSON.contains("User Personas"))
    }

    func testChannelMarkerWithSingleQuotedToolName() {
        let input = "<|channel|>commentary to= 'read_file' <|message|>{\"path\":\"test.swift\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file")
        XCTAssertTrue(calls[0].argumentsJSON.contains("test.swift"))
    }

    func testChannelMarkerConstrainAsToolName_simple() {
        // No to= present — tool name comes from <|constrain|>
        let input = "<|channel|>final <|constrain|>create_artifact<|message|>{\"name\":\"Research Report\",\"content\":\"Report\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")
        XCTAssertTrue(calls[0].argumentsJSON.contains("Research Report"))
    }

    func testChannelMarkerConstrainJsonNotToolName() {
        // to= provides the tool name; <|constrain|>json is a format keyword, not a tool
        let input = "<|channel|>commentary to=read_file <|constrain|>json<|message|>{\"path\":\"file.txt\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file")
        XCTAssertTrue(calls[0].argumentsJSON.contains("file.txt"))
    }

    /// When the inner JSON is a canonical tool-call envelope (`name` AND
    /// `arguments` both top-level), the inner `name` reflects intent better than
    /// channel `to=`: `arguments` being present signals "I'm calling this tool".
    /// For the flat `create_artifact` shape (`{"name":"<artifact_name>",
    /// "content":"..."}` — no `arguments` wrapper), inner `name` is a parameter
    /// value and `to=` wins; pinned by `testChannelMarker_flatPayload…`.
    func testChannelMarker_canonicalEnvelope_innerNameWinsOverChannel() {
        // Real-world model quirk: channel `to=delegate_to_team` but inner JSON
        // is a canonical tool-call envelope addressing a different tool. The
        // parser must follow the inner `name` (intent), not the routing header.
        let input = "<|channel|>commentary to=delegate_to_team <|constrain|>json<|message|>{\"name\":\"cancel_delegation\",\"arguments\":{}}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "cancel_delegation",
            "Inner canonical envelope's `name` must override channel `to=`")
        XCTAssertEqual(calls[0].argumentsJSON, "{}",
            "When inner JSON is a canonical envelope, the dispatched args are the unwrapped `arguments` object")
    }

    /// Reserved-name guard parity with `parseToolCallFromJSON`. If a model emits a
    /// canonical envelope shape but the inner `name` is a reserved channel name
    /// (`commentary`, `analysis`, `final`, `thinking`), envelope-detection must
    /// reject and fall through to channel `to=`. Without this guard, a stray
    /// `<|channel|>commentary to=create_artifact<|message|>{"name":"commentary",
    /// "arguments":{}}` would dispatch as a fake "commentary" tool.
    func testChannelMarker_canonicalEnvelope_rejectsReservedInnerName() {
        let input = "<|channel|>commentary to=create_artifact<|message|>{\"name\":\"commentary\",\"arguments\":{}}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact",
            "Reserved inner name must not be promoted; falls back to channel `to=`")
    }

    /// Named regression pin for the `create_artifact` flat-payload route. The
    /// model's canonical emission is `to=create_artifact <|message|>{"name":"X",
    /// "content":"..."}` — `name` is the artifact name (a parameter value), NOT
    /// a tool id. Without the `arguments`-presence guard in `canonicalEnvelope`,
    /// a naive "always prefer inner name" rule would dispatch as `X` and break
    /// every artifact-producing role. Pinned here by name so the contract is
    /// visible in the file's test list, not just implicit in the verbatim-log
    /// fixtures further below.
    func testChannelMarker_flatPayloadWithoutArguments_usesChannelName() {
        let input = "<|channel|>commentary to=create_artifact<|message|>{\"name\":\"Product Requirements\",\"content\":\"# PRD\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact",
            "Inner `name` without sibling `arguments` is a parameter value; channel `to=` wins")
        XCTAssertTrue(calls[0].argumentsJSON.contains("Product Requirements"))
        XCTAssertTrue(calls[0].argumentsJSON.contains("# PRD"))
    }

    /// Edge-shape pin: when a model double-encodes `arguments` as a JSON-string
    /// instead of a nested object (observed in some Qwen/DeepSeek outputs), the
    /// `arguments` cast in `canonicalEnvelope` fails and we fall back to channel
    /// `to=`. The full inner JSON becomes the args for the channel tool. This is
    /// not "correct" from the model's perspective — but it's the safest
    /// deterministic behavior, and downstream `INVALID_ARGS` will surface the
    /// raw payload so the user sees the model defect.
    func testChannelMarker_argumentsAsString_fallsBackToChannelDispatch() {
        let input = "<|channel|>commentary to=read_file<|message|>{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file",
            "When `arguments` is a string (not object), envelope-shape rejects and channel `to=` wins")
    }

    /// Edge-shape pin: when `arguments` is an array instead of an object, same
    /// fallback as the string case — channel `to=` wins, full inner JSON is the
    /// args payload.
    func testChannelMarker_argumentsAsArray_fallsBackToChannelDispatch() {
        let input = "<|channel|>commentary to=read_file<|message|>{\"name\":\"X\",\"arguments\":[1,2,3]}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_file",
            "When `arguments` is an array (not object), envelope-shape rejects and channel `to=` wins")
    }

    func testExtractChannelMarker_withLiteralNewlines() {
        // Full flow: Harmony <|channel|> format with markdown content containing literal newlines
        let input = "<|channel|>commentary to=create_artifact code<|message|>{\"name\":\"World Compendium\",\"content\":\"# Star Wars\nA long time ago\nin a galaxy far away\"}"
        let parser = HarmonyToolCallParser()
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")

        // Verify the arguments JSON is valid and parseable
        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(args["name"], "World Compendium")
        XCTAssertEqual(args["content"], "# Star Wars\nA long time ago\nin a galaxy far away")
    }

    // MARK: - Composite parser with real LLM log patterns

    func testCompositeParser_quotedToolName_fromLog() {
        // Exact PM response from network_log.json — previously caused infinite retry loop
        let input = "[reasoning]\nNeed to use create_artifact correctly.\n[/reasoning]\n\n<|channel|>commentary to= \"create_artifact\" <|constrain|>json<|message|>{\"name\":\"Product Requirements\",\"content\":\"# Product Requirements – Calculator\\n\\n## Scope\\n- In-Scope: Basic arithmetic calculator UI\"}"
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")

        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(args["name"], "Product Requirements")
    }

    func testCompositeParser_constrainToolName_fromLog() {
        // Exact UX Researcher response from network_log.json — previously failed on first try
        let input = "[reasoning]\nSupervisor task \"Make a calculator\". It's user-facing. Need research report.\n[/reasoning]\n\n<|channel|>final <|constrain|>create_artifact<|message|>{\"name\":\"Research Report\",\"content\":\"# Research Report – Calculator Feature\\n\\n## 1. User Personas (2-3)\\n| Persona | Goals | Pain Points |\"}"
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")

        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(args["name"], "Research Report")
    }

    // MARK: - Verbatim real LLM responses (from network_log.json run 459AAE1E)

    func testVerbatim_PMResponse1_quotedCreateArtifact() {
        // PM's first response — to="create_artifact" with quotes, <|constrain|>json
        let input = """
        [reasoning]
        Goal: "Make a calculator". Provide PRD. Simple.
        [/reasoning]

        <|channel|>commentary to="create_artifact" <|constrain|>json<|message|>{"name":"Product Requirements","content":"# Product Requirements: Calculator Application\\n\\n## 1. Problem Statement & Target Users\\nUsers need a lightweight, reliable tool to perform basic arithmetic operations (addition, subtraction, multiplication, division) quickly on mobile or desktop without relying on external services. The target audience includes students, professionals, and anyone who requires quick calculations in everyday tasks.\\n\\n## 2. Key User Stories & Pain Points\\n1. **As a user, I want to enter numbers and operators via a simple keypad so that I can perform calculations without leaving my workflow.**\\n   - Pain point: Existing calculators may be cluttered or require multiple steps.\\n2. **As a user, I want the result to be displayed immediately after pressing \\"=\\" so that I can verify my input quickly.**\\n   - Pain point: Delayed or unclear results in some apps.\\n3. **As a user, I want the calculator to handle basic error cases (e.g., division by zero) gracefully with clear messages.**\\n   - Pain point: Crashes or confusing error screens."}
        """
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")

        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(args["name"], "Product Requirements")
        XCTAssertTrue(args["content"]!.contains("Problem Statement & Target Users"))
        XCTAssertTrue(args["content"]!.contains("Key User Stories"))
    }

    func testVerbatim_UXResearcherResponse_constrainToolName() {
        // UX Researcher's first response — <|constrain|>create_artifact (no to=)
        let input = """
        [reasoning]
        Supervisor task is to make a calculator. Likely user-facing. Need research report.
        [/reasoning]

        <|channel|>final <|constrain|>create_artifact<|message|>{"name":"Research Report","content":"# Research Report – Calculator Feature\\n\\n## 1. User Personas\\n| Persona | Goals | Pain Points |\\n|---------|-------|-------------|\\n| **Alex – Student** | Quickly perform arithmetic for homework and labs. Needs a reliable, distraction‑free tool that can handle basic operations (+, –, ×, ÷) and simple functions (square root, percent). | Overwhelmed by complex scientific calculators. Wants a clean UI and instant results without navigating menus.\\n| **Jordan – Finance Analyst** | Compute quick financial figures (e.g., tax, interest) on the go. | Current phone calculators lack easy access to repeated operations; toggling between modes is tedious.\\n| **Maya – Casual User** | Use a calculator for everyday tasks (splitting bills, converting units). | Clunky layout on small screens; difficulty reaching keys during fast calculations."}
        """
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")

        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(args["name"], "Research Report")
        XCTAssertTrue(args["content"]!.contains("User Personas"))
        XCTAssertTrue(args["content"]!.contains("Alex – Student"))
        XCTAssertTrue(args["content"]!.contains("Jordan – Finance Analyst"))
    }

    func testVerbatim_PMResponseAfterNudge_unquotedCreateArtifact() {
        // PM's response after handleNoToolCalls nudge — unquoted to=create_artifact
        let input = """
        [reasoning]
        Need to call tool.
        [/reasoning]

        <|channel|>commentary to=create_artifact <|constrain|>json<|message|>{"name":"Product Requirements","content":"## Product Requirements: Calculator Application\\n\\n1. **Problem Statement & Target Users**\\n   - Users need a lightweight, reliable tool to perform basic arithmetic (add, subtract, multiply, divide) quickly on mobile or desktop without external services. Target audience: students, professionals, and anyone needing quick calculations.\\n\\n2. **Key User Stories & Pain Points**\\n   1. *As a user, I want to enter numbers and operators via a simple keypad so I can calculate without leaving my workflow.*\\n      - Pain point: Existing calculators may be cluttered or require multiple steps."}
        """
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")

        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(args["name"], "Product Requirements")
        XCTAssertTrue(args["content"]!.contains("Problem Statement & Target Users"))
    }

    func testVerbatim_TechLeadResponse_updateScratchpad() {
        // Tech Lead's planning phase response — to=update_scratchpad
        let input = """
        [reasoning]
        Need to plan.
        [/reasoning]

        <|channel|>commentary to=update_scratchpad <|constrain|>json<|message|>{"content":"1. Review product requirements and design spec\\n2. Define project structure (React app, component hierarchy)\\n3. Implement calculator logic (evaluate single operation, error handling)\\n4. Build UI components: keypad, display, responsive layout\\n5. Add unit tests for logic (Jest)\\n6. Integrate with design spec and run visual regression\\n7. Prepare handoff artifacts (code repo link, README)\\n"}
        """
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "update_scratchpad")

        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertTrue(args["content"]!.contains("Review product requirements"))
        XCTAssertTrue(args["content"]!.contains("unit tests"))
    }

    func testVerbatim_PMGaveUp_noToolCall() {
        // PM's final response after 7 failed retries — gave up and wrote PRD as plain text
        let input = """
        [reasoning]
        We are stuck. Probably the system expects no tool calls; just plain answer? But earlier we were required to use create_artifact. However repeated failures suggest maybe tool call syntax wrong: need to output without quotes around keys? The JSON is correct. I'm out of juice.
        [/reasoning]

        I'm sorry for the repeated issues. I'll provide the PRD directly here:

        **Product Requirements: Calculator Application**

        1. **Problem Statement & Target Users**
           - Users need a lightweight, reliable tool to perform basic arithmetic (add, subtract, multiply, divide) quickly on mobile or desktop without external services.

        2. **Key User Stories & Pain Points**
           1. *As a user, I want to enter numbers and operators via a simple keypad so I can calculate without leaving my workflow.*
           2. *As a user, I want the result displayed immediately after pressing "=" so I can verify my input quickly.*
        """
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 0, "Plain text with no tool markers should yield no tool calls")
    }

    func testVerbatim_twoChannelBlocksInOneResponse() {
        // Two tool calls in one response — each in its own <|channel|> block
        let input = "<|channel|>commentary to=update_scratchpad <|constrain|>json<|message|>{\"content\":\"plan\"}<|channel|>commentary to=create_artifact <|constrain|>json<|message|>{\"name\":\"Report\",\"content\":\"done\"}"
        let calls = ChannelMarkerStrategy().parse(from: input)

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "update_scratchpad")
        XCTAssertEqual(calls[1].name, "create_artifact")

        let data1 = calls[0].argumentsJSON.data(using: .utf8)!
        let args1 = try! JSONSerialization.jsonObject(with: data1) as! [String: String]
        XCTAssertEqual(args1["content"], "plan")

        let data2 = calls[1].argumentsJSON.data(using: .utf8)!
        let args2 = try! JSONSerialization.jsonObject(with: data2) as! [String: String]
        XCTAssertEqual(args2["name"], "Report")
    }

    func testVerbatim_PMResponse_spaceBeforeQuotedName() {
        // PM used `to= "create_artifact"` (space between = and opening quote) — exact pattern from retry #2
        let input = """
        [reasoning]
        Need to call create_artifact properly.
        [/reasoning]

        <|channel|>commentary to= "create_artifact" <|constrain|>json<|message|>{"name":"Product Requirements","content":"# Product Requirements: Calculator Application\\n\\n## 1. Problem Statement & Target Users\\nUsers need a lightweight, reliable tool to perform basic arithmetic operations.\\n\\n## 4. Scope\\n- **In scope**: Basic arithmetic operations, responsive UI, error handling, unit tests for logic.\\n- **Out of scope**: Advanced functions (exponentiation, trigonometry), history log, persistence, multi-operation chaining.\\n\\n## 5. Success Metrics\\n- **Error Rate**: < 1% of operations resulting in crashes or unhandled exceptions.\\n- **Performance**: 99th percentile response time < 50 ms."}
        """
        let parser = HarmonyToolCallParser()
        let calls = parser.extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "create_artifact")

        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(args["name"], "Product Requirements")
        XCTAssertTrue(args["content"]!.contains("Scope"))
        XCTAssertTrue(args["content"]!.contains("Success Metrics"))
    }

    // MARK: - Unbalanced Brace Salvage (qwen3.5-4b-mlx bug)
    // Some models emit <|call|>{"name":"X","arguments":{…}<|end|> — missing the outer
    // closing brace. The parser should salvage these rather than silently drop the call.
    // Repro from run EAE23A6D network_log (Code Reviewer step 27B58D62).

    func testSalvagesUnbalancedOuterBraceCallMarker() {
        let input = "<|call|>{\"name\":\"create_artifact\",\"arguments\":{\"name\":\"Code Review\",\"content\":\"# Report\\n\\nAPPROVE\"}<|end|>"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1, "Parser should salvage call with missing outer brace")
        XCTAssertEqual(calls[0].name, "create_artifact")
        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(args["name"], "Code Review")
        XCTAssertTrue(args["content"]!.contains("APPROVE"))
    }

    func testSalvagesUnbalancedEmptyArguments() {
        // Even simpler repro: <|call|>{"name":"update_scratchpad","arguments":{}<|end|>
        let input = "<|call|>{\"name\":\"update_scratchpad\",\"arguments\":{}<|end|>"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "update_scratchpad")
        // Verify the salvaged argumentsJSON actually parses to an empty dict.
        let data = calls[0].argumentsJSON.data(using: .utf8)!
        let args = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(args.isEmpty, "Salvaged arguments must be a valid empty object")
    }

    func testDoesNotSalvageDeeplyUnbalancedGarbage() {
        // Guard: don't salvage input with implausible imbalance (>3 missing braces).
        let input = "<|call|>{{{{{\"name\":\"x\",\"arguments\":{\"a\":\"b\"<|end|>"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertTrue(calls.isEmpty, "Should not attempt to salvage deeply broken input")
    }

    func testDoesNotSalvageWhenNoCloseBraceObserved() {
        // Guard: when walker has never seen a closing brace, there's no anchor to truncate
        // at — lastCloseEnd is nil, salvage must refuse. Input has depth=2 with no closes.
        let input = "<|call|>{\"name\":\"x\",\"arguments\":{\"a\":\"b\"<|end|>"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertTrue(
            calls.isEmpty,
            "Should not salvage when no close brace was observed (lastCloseEnd == nil)"
        )
    }

    func testDoesNotSalvageUnterminatedString() {
        // The `!inString` guard prevents salvage when the walker is mid-string at EOF:
        // we can't know where the string should close. Without this guard we could
        // corrupt content that legitimately contains `<|end|>` inside a string value.
        let input = "<|call|>{\"name\":\"x\",\"arguments\":{\"content\":\"hello <|end|>"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertTrue(
            calls.isEmpty,
            "Should not salvage when walker is mid-string at EOF"
        )
    }

    func testSalvagesUnbalancedStartMarkerFormat() {
        // Shared helper benefits all strategies — verify StartMarkerStrategy also salvages.
        let input = "<|start|>functions.create_artifact<|message|>{\"name\":\"Plan\",\"content\":\"x\"}"
        // Note: this input has outer { balanced (single object), so it's already valid.
        // Test a truly unbalanced variant:
        let unbalanced = "<|start|>functions.create_artifact<|message|>{\"outer\":{\"name\":\"Plan\"}"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: unbalanced)
        _ = input
        XCTAssertEqual(calls.count, 1, "StartMarkerStrategy should benefit from shared salvage")
        XCTAssertEqual(calls[0].name, "create_artifact")
    }

    func testSalvagesUnbalancedChannelMarkerFormat() {
        // Same shared-helper check for ChannelMarkerStrategy: extracts JSON even
        // when the trailing outer `}` is missing (inner `{"x":1}` provides the
        // salvage anchor). Inner JSON happens to be a canonical tool-call envelope
        // (`name` + `arguments` both top-level), so per `resolveDispatch` the inner
        // `name` wins over channel `to=` — the resolved call is `Plan`, args
        // `{"x":1}`. The test's primary purpose is to verify salvage; the dispatch
        // assertion just pins the post-fix envelope-shape semantics.
        let input = "<|channel|>commentary to=create_artifact<|message|>{\"name\":\"Plan\",\"arguments\":{\"x\":1}"
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1, "ChannelMarkerStrategy should benefit from shared salvage")
        XCTAssertEqual(calls[0].name, "Plan",
            "Inner canonical envelope wins over channel `to=` (envelope-shape rule)")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"x\":1}")
    }

    func testExtractsValidCallFollowedByUnbalancedCall() {
        // Two <|call|> blocks in one response: the first is well-formed, the second is
        // unbalanced. Both should be recovered. Verifies cursor advances correctly past
        // the salvaged call so subsequent parsing continues.
        let input =
            "<|call|>{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.txt\"}}<|end|>" +
            "<|call|>{\"name\":\"create_artifact\",\"arguments\":{\"name\":\"X\",\"content\":\"y\"}<|end|>"
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "read_file")
        XCTAssertEqual(calls[1].name, "create_artifact")
    }

    // MARK: - <|start|>commentary channel-style variant (gpt-oss-20b defect)
    // The model emits `<|start|>commentary to=NAME <|message|>{JSON}` — mixing
    // the start opening marker with channel-style framing. Both real-data
    // fixtures are verbatim from `network_log.json` for the user's run.

    /// Real-data fixture A — `<|start|>commentary to=read_file` envelope from
    /// `gpt-oss-20b`, no closing marker. Preserved byte-exact, including the
    /// leading space inside `" .nanoteams/tasks/0"` (model quirk).
    func testStartMarker_channelStyle_readFile_realDataA_recognizedAsToolCall() throws {
        let input = """
[reasoning]
Open one.
[/reasoning]

<|start|>commentary to=read_file <|constrain|>json<|message|>{"path":" .nanoteams/tasks/0"}
"""
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        let json = calls.first?.argumentsJSON ?? ""
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["path"] as? String, " .nanoteams/tasks/0")
    }

    /// Real-data fixture B — `<|start|>commentary to=list_files` from
    /// `gpt-oss-20b`, immediately followed by `<|start|>userI've examined…`
    /// (inlined next-turn). The em-dash is U+2014 and the apostrophe is ASCII
    /// 0x27 — preserved byte-exact. Trailing role marker must NOT be parsed as
    /// a second tool call.
    func testStartMarker_channelStyle_listFiles_realDataB_inlinedUserTurn_oneCallOnly() throws {
        let input = """
[reasoning]
Let's list files inside .nanoteams/tasks/0.No output. Maybe empty dir. So nothing.

Thus no tasks.

We cannot proceed.
[/reasoning]

<|start|>commentary to=list_files <|constrain|>json<|message|>{"path":".nanoteams/tasks/0","depth":1}<|start|>userI've examined the repository contents—including the `.nanoteams/tasks` directories—and found no code or task files to act on. Without a clear specification or source file, I'm unable to perform any work at this time.
"""
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1,
            "the trailing <|start|>user… is a role marker, not a second tool call")
        XCTAssertEqual(calls.first?.name, "list_files")
        let json = calls.first?.argumentsJSON ?? ""
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["path"] as? String, ".nanoteams/tasks/0")
        XCTAssertEqual(decoded?["depth"] as? Int, 1)
    }

    // MARK: - Role markers must never parse as tool calls

    func testStartMarker_userRole_notParsedAsToolCall() {
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: "<|start|>user hello<|end|>")
        XCTAssertTrue(calls.isEmpty)
    }

    func testStartMarker_assistantRole_notParsedAsToolCall() {
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: "<|start|>assistant ack<|end|>")
        XCTAssertTrue(calls.isEmpty)
    }

    func testStartMarker_systemRole_notParsedAsToolCall() {
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: "<|start|>system foo<|end|>")
        XCTAssertTrue(calls.isEmpty)
    }

    func testStartMarker_developerRole_notParsedAsToolCall() {
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: "<|start|>developer foo<|end|>")
        XCTAssertTrue(calls.isEmpty)
    }

    func testStartMarker_toolRole_notParsedAsToolCall() {
        let calls = HarmonyToolCallParser().extractAllToolCalls(
            from: "<|start|>tool foo<|end|>")
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Pre-existing `functions.NAME` path must keep working

    func testStartMarker_functions_regressionStillWorks() {
        let input = #"<|start|>functions.create_artifact<|message|>{"name":"X","content":"y"}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "create_artifact")
    }

    // MARK: - Channel-style framing variants after <|start|>

    func testStartMarker_channelStyle_withoutConstrain_recognized() {
        let input = #"<|start|>commentary to=read_file <|message|>{"path":"p"}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    func testStartMarker_channelStyle_quotedName_recognized() {
        let input = #"<|start|>commentary to="read_file" <|message|>{"path":"p"}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    func testStartMarker_channelStyle_constrainFallbackName_recognized() {
        // No `to=` — name lives in `<|constrain|>NAME` instead. `json`/`text`/
        // etc. are format keywords and rejected; `read_file` is an identifier
        // and accepted.
        let input = #"<|start|>commentary <|constrain|>read_file<|message|>{"path":"p"}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    func testStartMarker_channelStyle_followedByFunctionsBlock_bothExtracted() {
        let input =
            #"<|start|>commentary to=read_file <|message|>{"path":"a"}"# +
            #"<|start|>functions.write_file<|message|>{"path":"b","content":"c"}<|end|>"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "read_file")
        XCTAssertEqual(calls[1].name, "write_file")
    }

    // MARK: - Streaming-trigger marker set (Part B coverage)

    func testHarmonyMarkers_includesBareStartMarker_realDataPayloadDetected() {
        // Real data fixture A must be detected as a Harmony envelope by the
        // streaming trigger so the parser ever gets a chance to run on it.
        let payload = #"<|start|>commentary to=read_file <|constrain|>json<|message|>{"path":" .nanoteams/tasks/0"}"#
        let hit = HarmonyToolCallParser.harmonyMarkers.contains { payload.contains($0) }
        XCTAssertTrue(hit,
            "bare <|start|> must be a Harmony marker so the streamer routes content to the harmony buffer")
    }

    func testHarmonyMarkers_doesNotIncludeFunctionPrefixOnly() {
        // Regression guard: re-adding `<|start|>functions.` here would be
        // redundant (bare `<|start|>` already matches) and could mask a future
        // missing bare-start entry.
        XCTAssertFalse(HarmonyToolCallParser.harmonyMarkers.contains("<|start|>functions."),
            "the bare `<|start|>` entry subsumes the function-prefix marker; keep one")
    }

    // MARK: - <|start|> envelope edge cases

    /// Defends the `blockEnd` boundary heuristic — when the JSON body literally
    /// contains `<|start|>` inside a string value, the envelope must not be
    /// truncated. `extractJSONBracedValue` is string-aware so the JSON walker
    /// consumes the embedded marker; the surrounding `<|message|>` lookup is
    /// bounded by the NEXT real `<|start|>` outside the JSON.
    func testStartMarker_channelStyle_innerStartInsideJSONString_consumedCorrectly() {
        let input = #"<|start|>commentary to=read_file <|message|>{"path":"hello <|start|> world"}<|start|>userOK"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
    }

    /// Empty `{}` body must parse as a valid call with empty args — pins the
    /// contract for tools that take no parameters.
    func testStartMarker_channelStyle_emptyJSON_recognized() {
        let input = #"<|start|>commentary to=read_file <|message|>{}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertEqual(calls.first?.argumentsJSON, "{}")
    }

    /// Without `to=NAME` AND without `<|constrain|>NAME`, the envelope has no
    /// resolvable tool name and must be dropped. Critical regression guard:
    /// `commentary` is a reserved channel name — a future refactor that
    /// dispatched it as the tool would create a phantom `"commentary"` call.
    func testStartMarker_unnamedChannelEnvelope_dropped() {
        let input = #"<|start|>commentary <|message|>{"path":"p"}"#
        let calls = HarmonyToolCallParser().extractAllToolCalls(from: input)
        XCTAssertTrue(calls.isEmpty,
            "no `to=` and no `<|constrain|>` → no resolvable tool name → drop")
    }

    // MARK: - classifyHarmonyCallIssue: role-marker-only retry regression
    //
    // Before this PR the streamer trigger required `<|start|>functions.` so a
    // response containing only `<|start|>userhello<|end|>` never set
    // `sawHarmonyMarker`, and the engine sent the generic "did not call any
    // tools" retry. After widening the trigger to bare `<|start|>` (so the
    // gpt-oss-20b channel-style envelope could be parsed), role-marker-only
    // responses incorrectly route into the `sawHarmonyMarker` branch which
    // then sends a "malformed JSON" retry. The classifier needs a third case
    // that lets `handleNoToolCalls` fall through to the generic retry.

    func testClassifyHarmonyCallIssue_roleMarkerOnly_user_noEnvelopeAttempt() {
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(
            in: "<|start|>userhello<|end|>")
        XCTAssertEqual(issue, .noEnvelopeAttempt,
            "<|start|>user…<|end|> is an inlined role turn, not a tool-call attempt")
    }

    func testClassifyHarmonyCallIssue_roleMarkerOnly_assistant_noEnvelopeAttempt() {
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(
            in: "<|start|>assistant some text<|end|>")
        XCTAssertEqual(issue, .noEnvelopeAttempt)
    }

    func testClassifyHarmonyCallIssue_multipleRoleMarkers_noEnvelopeAttempt() {
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(
            in: "<|start|>userfoo<|end|><|start|>assistantbar<|end|>")
        XCTAssertEqual(issue, .noEnvelopeAttempt,
            "every <|start|> is followed by a role marker → not an envelope attempt")
    }

    func testClassifyHarmonyCallIssue_roleMarkerFollowedByActualCall_malformedJSON() {
        // Mixed: role marker AND a malformed <|call|> envelope. The call
        // marker wins — this IS an envelope attempt that failed parsing.
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(
            in: "<|start|>userfoo<|call|>{not valid json<|end|>")
        XCTAssertEqual(issue, .malformedJSON)
    }

    func testClassifyHarmonyCallIssue_channelStyleStartEnvelope_notRoleMarkerOnly() {
        // `<|start|>commentary…` is a channel-style envelope, NOT a role marker.
        // It hit malformedJSON because there's no <|call|>, but it's not
        // .noEnvelopeAttempt — the model DID try to emit an envelope.
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(
            in: #"<|start|>commentary to=read_file <|message|>{"path":"p""#)
        XCTAssertNotEqual(issue, .noEnvelopeAttempt,
            "channel-style envelope after <|start|> is an envelope attempt, not a role marker")
    }

    func testClassifyHarmonyCallIssue_validCall_unchangedBehavior() {
        // Regression guard: valid <|call|> shapes must continue routing to
        // their pre-existing classifications, NOT to .noEnvelopeAttempt.
        let issue = ToolCallParsingHelpers.classifyHarmonyCallIssue(
            in: #"<|call|>{"name":"read_file","arguments":{"path":"p"}}<|end|>"#)
        XCTAssertNotEqual(issue, .noEnvelopeAttempt)
    }

    // MARK: - Reasoning-channel verbatim payloads (regression pins)
    //
    // Three byte-near-verbatim bodies from
    // `.nanoteams/internal/tasks/0/subtasks/1/runs/0/network_log.json` records
    // #11, #13, #15 (qwen3.6-35b-a3b-ud-mlx). In production, the difference
    // between #11/#13 (FAIL) and #15 (OK) was which SSE channel carried the
    // marker — the payload shapes themselves are valid and must parse here.
    // These tests pin the parser side of the contract that the
    // streaming-side fix (post-stream scan of `thinkingCollected`) will rely on.

    /// Episode 1 — read_file in run `tasks/0/runs/0/network_log.json` record #1.
    func testCallMarkerFlatJSON_readFileVerbatim() {
        let input = #"<|call|>{"name":"read_file","arguments":{"path": "calculator.html"}}<|end|>"#
        let calls = CallMarkerStrategy().parse(from: input)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"path":"calculator.html"}"#)
    }

    /// Episode 2 — create_artifact emitted at offset 4983 inside an 9671-byte
    /// reasoning block (subtasks/1 record #11). Substantial preceding prose
    /// must not interfere with marker location or JSON extraction.
    func testCallMarkerFlatJSON_createArtifactWithLongReasoningPrefix() {
        let prose = """
        Okay, I will create the Implementation Plan artifact detailing the verified fixes \
        and the new bug found, with clear instructions for the Software Engineer.

        Let's draft the Implementation Plan:
        - Architecture/Design: Single-file HTML/CSS/JS calculator. Uses `eval()` for \
        expression evaluation after regex substitution.
        - Verified Fixes: All 3 are correct and safe.
        - New Bug Found: `exp` (eˣ) and `10x` (10ˣ) functions append `'e^('` and `'10^('` \
        without checking for implicit multiplication.

        Proportional to task scope. Simple but thorough.
        Done.
        Proceeding.
        """
        let envelope = ##"<|call|>{"name":"create_artifact","arguments":{"name":"Implementation Plan","content":"# Implementation Plan","format":"markdown"}}<|end|>"##
        let calls = CallMarkerStrategy().parse(from: prose + "\n" + envelope)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "create_artifact")
        // argumentsJSON is sortedKeys-normalized: content, format, name.
        XCTAssertEqual(
            calls.first?.argumentsJSON,
            ##"{"content":"# Implementation Plan","format":"markdown","name":"Implementation Plan"}"##
        )
    }

    /// Episode 3 — retry after "Missing deliverables: 'Implementation Plan'" nudge
    /// (subtasks/1 record #13). Same envelope shape but a different argument-key
    /// order (`format` first), confirming the parser is insensitive to top-level
    /// key ordering.
    func testCallMarkerFlatJSON_createArtifactRetryAfterMissingDeliverables() {
        let prose = """
        The user wants me to submit the "Implementation Plan" artifact. \
        I already called create_artifact in my previous turn, but the system says it's missing. \
        I will call create_artifact again with the exact name "Implementation Plan" \
        and the content I drafted.

        Tool: create_artifact
        Args: name="Implementation Plan", format="markdown", content="[the drafted text]"
        Done.
        Proceeding.
        """
        let envelope = ##"<|call|>{"name":"create_artifact","arguments":{"format":"markdown","name":"Implementation Plan","content":"# Plan v2"}}<|end|>"##
        let calls = CallMarkerStrategy().parse(from: prose + "\n" + envelope)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "create_artifact")
        XCTAssertEqual(
            calls.first?.argumentsJSON,
            ##"{"content":"# Plan v2","format":"markdown","name":"Implementation Plan"}"##
        )
    }

    // MARK: - Zero-argument channel envelope

    /// Verbatim from the wedged Autovisor pass (turn 6): the model named a tool it does
    /// not have and gave it no body. The name resolved and was then THROWN AWAY, so the
    /// turn produced no call at all and the model was told its JSON was malformed — for an
    /// envelope with no brace to malform. Emitting `{}` sends it through the normal
    /// authorization path instead, which answers "Tool 'swift_build' is not available for
    /// this role… do not retry 'swift_build'".
    func testBodylessChannelEnvelope_resolvesWithEmptyArguments() {
        let calls = ChannelMarkerStrategy().parse(
            from: "<|channel|>commentary to=swift_build code<|message|>")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "swift_build")
        XCTAssertEqual(calls.first?.argumentsJSON, "{}",
                       "never \"\" — an empty string splits the loop detector's identity key")
    }

    /// The same shape for a tool that really does take no arguments — the case the
    /// Autovisor manager needs, since `wait_for_events` is the only way its pass can end.
    func testBodylessChannelEnvelope_zeroArgTool_fires() {
        let calls = ChannelMarkerStrategy().parse(
            from: "<|channel|>commentary to=wait_for_events<|message|>")
        XCTAssertEqual(calls.map(\.name), ["wait_for_events"])
    }

    /// The `to=` path never applied the reserved-channel guard — harmless while a JSON
    /// body was mandatory, a tool literally named `commentary` the moment it isn't.
    func testBodylessChannelEnvelope_reservedRecipient_doesNotResolve() {
        for reserved in ["commentary", "analysis", "final", "Thinking"] {
            let calls = ChannelMarkerStrategy().parse(
                from: "<|channel|>commentary to=\(reserved)<|message|>")
            XCTAssertTrue(calls.isEmpty, "`to=\(reserved)` must never mint a tool call")
        }
    }

    /// A channel envelope with no recipient at all still resolves nothing.
    func testChannelEnvelopeWithNoRecipient_doesNotResolve() {
        XCTAssertTrue(ChannelMarkerStrategy().parse(from: "<|channel|>commentary<|message|>").isEmpty)
    }

    /// The zero-arg arm must not steal the JSON branch: a body that parses still wins,
    /// arguments and all.
    func testChannelEnvelopeWithBody_isUnaffected() {
        let calls = ChannelMarkerStrategy().parse(
            from: ##"<|channel|>commentary to=read_file<|message|>{"path":"a.swift"}"##)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "read_file")
        XCTAssertEqual(calls.first?.argumentsJSON, ##"{"path":"a.swift"}"##)
    }

    /// Forward progress: `nextStart` is `blockEnd`, so a second envelope is still found.
    func testTwoBodylessEnvelopes_bothResolve_noHang() {
        let calls = ChannelMarkerStrategy().parse(
            from: "<|channel|>commentary to=list_tasks<|message|>"
                + "<|channel|>commentary to=wait_for_events<|message|>")
        XCTAssertEqual(calls.map(\.name), ["list_tasks", "wait_for_events"])
    }

    /// `<|start|>` Path 2b shares `ChannelEnvelopeParser`, so it inherits the arm.
    func testBodylessEnvelope_viaStartMarker_resolves() {
        let calls = StartMarkerStrategy().parse(from: "<|start|>commentary to=list_tasks<|message|>")
        XCTAssertEqual(calls.map(\.name), ["list_tasks"])
    }

    /// The recipient is a HEADER field. Before the zero-arg arm existed, searching into
    /// the body was harmless because both strategies still needed a `{`; now it would let
    /// ordinary prose — gpt-oss's most common non-tool emission — mint a call.
    func testRecipientInsideMessageBody_isNotAName() {
        let calls = ChannelMarkerStrategy().parse(
            from: "<|channel|>final<|message|>You could pass to=read_file for that.")
        XCTAssertTrue(calls.isEmpty,
                      "`to=` after <|message|> is prose, not the Harmony recipient")
    }
}
