import XCTest
@testable import NanoTeams

/// Argument validation guards for `delegate_to_team`. The async dispatch path
/// (`handleDelegateToTeam`) is exercised end-to-end through the LLM execution
/// service; these tests cover only the in-handler shape checks before the signal
/// is emitted.
@MainActor
final class DelegateToTeamHandlerTests: XCTestCase {

    private func makeRuntime() throws -> ToolRuntime {
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-delegate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolderRoot, withIntermediateDirectories: true)
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot,
            toolCallsLogURL: nil,
            isDefaultStorage: false
        )
        return runtime
    }

    private func invokeDelegate(
        runtime: ToolRuntime,
        args: [String: Any]
    ) throws -> ToolExecutionResult {
        let workFolderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-delegate-ctx-\(UUID().uuidString)")
        let argsJSON = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
        let call = StepToolCall(name: ToolNames.delegateToTeam, argumentsJSON: argsJSON)
        let results = runtime.executeAll(
            context: ToolExecutionContext(
                workFolderRoot: workFolderRoot,
                taskID: 1, runID: 0, roleID: "pm"
            ),
            toolCalls: [call]
        )
        guard let result = results.first else {
            throw NSError(domain: "DelegateToTeamHandlerTests", code: 1)
        }
        return result
    }

    /// Asserts the success envelope for a defaulted-to-sentinel call: signal carries
    /// the sentinel, outputJSON contains the success-shape `team_id` + status, and no
    /// stale `INVALID_ARGS` key leaked through.
    private func assertDefaultedToSentinel(
        _ result: ToolExecutionResult,
        expectedBrief: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(result.isError, "Should not error: \(result.outputJSON)", file: file, line: line)
        XCTAssertFalse(result.outputJSON.contains("INVALID_ARGS"),
                       "Stale INVALID_ARGS key in success envelope: \(result.outputJSON)",
                       file: file, line: line)
        XCTAssertTrue(result.outputJSON.contains("\"team_id\":\"\(DelegationConstants.generatedTeamSentinel)\""),
                      "Envelope must echo team_id=generated: \(result.outputJSON)",
                      file: file, line: line)
        XCTAssertTrue(result.outputJSON.contains("\"status\":\"pending\""),
                      "Envelope must carry status=pending: \(result.outputJSON)",
                      file: file, line: line)
        if case .delegateToTeam(let teamID, let brief)? = result.signal {
            XCTAssertEqual(teamID, DelegationConstants.generatedTeamSentinel, file: file, line: line)
            XCTAssertEqual(brief, expectedBrief, file: file, line: line)
        } else {
            XCTFail("Expected .delegateToTeam signal, got: \(String(describing: result.signal))", file: file, line: line)
        }
    }

    // MARK: - team_id default-to-sentinel paths

    /// Regression-pin (Run 21, 2026-05-02): small models routinely omit `team_id`. The
    /// handler defaults missing/empty/non-string values to the "generated" sentinel so
    /// the call proceeds; the downstream eligibility check produces the actionable
    /// `delegationDenied` envelope when the role isn't allowed to use generated teams.
    /// Strict `INVALID_ARGS — Missing required argument: team_id` was the prior contract.
    func testMissingTeamID_defaultsToGeneratedSentinel() throws {
        let runtime = try makeRuntime()
        let result = try invokeDelegate(runtime: runtime, args: ["task_brief": "Do X"])
        assertDefaultedToSentinel(result, expectedBrief: "Do X")
    }

    func testEmptyStringTeamID_defaultsToGeneratedSentinel() throws {
        let runtime = try makeRuntime()
        let result = try invokeDelegate(runtime: runtime, args: ["team_id": "", "task_brief": "Do X"])
        assertDefaultedToSentinel(result, expectedBrief: "Do X")
    }

    func testWhitespaceTeamID_defaultsToGeneratedSentinel() throws {
        let runtime = try makeRuntime()
        let result = try invokeDelegate(runtime: runtime, args: ["team_id": "   ", "task_brief": "Do X"])
        assertDefaultedToSentinel(result, expectedBrief: "Do X")
    }

    /// Models occasionally emit `team_id: 42` (JSON number) or `team_id: null`. The
    /// handler coerces non-string values to strings via the extractString helper —
    /// strict type-rejection would teach a contract small models can't reliably
    /// honor. Numeric `42` round-trips as `"42"`, then downstream eligibility / ID
    /// matching produces the actionable error.
    func testNonStringTeamID_coercesToString() throws {
        let runtime = try makeRuntime()
        let result = try invokeDelegate(runtime: runtime, args: ["team_id": 42, "task_brief": "Do X"])
        XCTAssertFalse(result.isError, "Non-string team_id should coerce, not error: \(result.outputJSON)")
        if case .delegateToTeam(let teamID, _)? = result.signal {
            XCTAssertEqual(teamID, "42", "Numeric team_id should round-trip as its String representation")
        } else {
            XCTFail("Expected .delegateToTeam signal, got: \(String(describing: result.signal))")
        }
    }

    /// When the model passes args as a stringified JSON blob (delivered as
    /// `__raw_input__`), the handler still recovers structured fields. Mirrors the
    /// `requiredString` recovery path so a parsable blob is never silently flattened
    /// to the sentinel even when it carries a real team_id.
    func testRawInputJSONBlob_recoversTeamID() throws {
        let runtime = try makeRuntime()
        let blob = #"{"team_id":"engineering_team","task_brief":"Do X"}"#
        let result = try invokeDelegate(runtime: runtime, args: ["__raw_input__": blob])
        XCTAssertFalse(result.isError, "Should recover from __raw_input__: \(result.outputJSON)")
        if case .delegateToTeam(let teamID, _)? = result.signal {
            XCTAssertEqual(teamID, "engineering_team",
                           "Should extract team_id from __raw_input__ blob, not default to sentinel")
        } else {
            XCTFail("Expected .delegateToTeam signal, got: \(String(describing: result.signal))")
        }
    }

    // MARK: - task_brief

    func testMissingTaskBrief_returnsInvalidArgs() throws {
        let runtime = try makeRuntime()
        let result = try invokeDelegate(runtime: runtime, args: ["team_id": "team-A"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("INVALID_ARGS"), "envelope: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("task_brief"), "Error should mention task_brief: \(result.outputJSON)")
    }

    /// Whitespace-only task_brief is rejected: an empty brief turns the 30-min
    /// delegation budget into wasted child-team work. Mirrors the team_id trim+check
    /// pattern, but here we reject (no useful default exists for content).
    func testWhitespaceTaskBrief_returnsInvalidArgs() throws {
        let runtime = try makeRuntime()
        let result = try invokeDelegate(runtime: runtime, args: ["team_id": "team-A", "task_brief": "   "])
        XCTAssertTrue(result.isError, "Whitespace-only task_brief should reject: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("INVALID_ARGS"), "envelope: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("task_brief is empty"),
                      "Error message should be actionable: \(result.outputJSON)")
    }

    // MARK: - Happy paths

    func testGeneratedSentinel_isAccepted() throws {
        let runtime = try makeRuntime()
        let result = try invokeDelegate(
            runtime: runtime,
            args: ["team_id": DelegationConstants.generatedTeamSentinel, "task_brief": "Do X"]
        )
        assertDefaultedToSentinel(result, expectedBrief: "Do X")
    }

    func testValidUUID_isAccepted() throws {
        let runtime = try makeRuntime()
        let teamID = UUID().uuidString
        let result = try invokeDelegate(
            runtime: runtime,
            args: ["team_id": teamID, "task_brief": "Brief"]
        )
        XCTAssertFalse(result.isError)
        if case .delegateToTeam(let id, _)? = result.signal {
            XCTAssertEqual(id, teamID)
        } else {
            XCTFail("Expected .delegateToTeam signal")
        }
    }
}
