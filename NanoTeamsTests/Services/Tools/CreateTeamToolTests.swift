import XCTest
@testable import NanoTeams

final class CreateTeamToolTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var registry: ToolRegistry!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (reg, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        registry = reg
        runtime = run

        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: 0,
            runID: 0,
            roleID: "team_creator"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        registry = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Registration

    func testCreateTeamToolRegistered() {
        XCTAssertTrue(registry.registeredToolNames.contains(ToolNames.createTeam))
    }

    // MARK: - Valid Config

    func testCreateTeam_validProducingTeam_returnsSignal() {
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "Dev Team",
                    "description": "Team for development",
                    "roles": [
                        {
                            "name": "Engineer",
                            "prompt": "Build the feature",
                            "produces_artifacts": ["Code"],
                            "requires_artifacts": ["Supervisor Task"],
                            "tools": ["read_file", "write_file"]
                        }
                    ],
                    "artifacts": [
                        {"name": "Code", "description": "Source code"}
                    ],
                    "supervisor_requires": ["Code"]
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)

        if case .teamCreation(let config) = results[0].signal {
            XCTAssertEqual(config.name, "Dev Team")
            XCTAssertEqual(config.roles.count, 1)
            XCTAssertEqual(config.roles[0].name, "Engineer")
            XCTAssertEqual(config.supervisorRequires, ["Code"])
        } else {
            XCTFail("Expected .teamCreation signal, got \(String(describing: results[0].signal))")
        }
    }

    func testCreateTeam_chatTeam_validConfig() {
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "Chat Team",
                    "description": "Interactive",
                    "roles": [
                        {
                            "name": "Assistant",
                            "prompt": "Help the user",
                            "produces_artifacts": [],
                            "requires_artifacts": ["Supervisor Task"],
                            "tools": ["ask_supervisor", "read_file"]
                        }
                    ],
                    "artifacts": [],
                    "supervisor_requires": []
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        if case .teamCreation(let config) = results[0].signal {
            XCTAssertTrue(config.supervisorRequires.isEmpty)
            XCTAssertTrue(config.roles[0].producesArtifacts.isEmpty)
        } else {
            XCTFail("Expected .teamCreation signal")
        }
    }

    func testCreateTeam_successEnvelope_containsTeamName() {
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "MyTeam",
                    "description": "test",
                    "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["O"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
                    "artifacts": [{"name": "O", "description": "d"}],
                    "supervisor_requires": ["O"]
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].outputJSON.contains("MyTeam"))
        XCTAssertTrue(results[0].outputJSON.contains("created"))
    }

    // MARK: - Invalid Config

    func testCreateTeam_missingTeamConfig_returnsError() {
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: "{}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertNil(results[0].signal)
    }

    func testCreateTeam_invalidJSON_returnsError() {
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "Incomplete"
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertNil(results[0].signal)
    }

    func testCreateTeam_emptyRoles_returnsError() {
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "Empty",
                    "description": "No roles",
                    "roles": [],
                    "artifacts": [],
                    "supervisor_requires": []
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertNil(results[0].signal)
        XCTAssertTrue(results[0].outputJSON.contains("at least one role"))
    }

    func testCreateTeam_snakeCaseKeys_camelCaseTolerated() {
        // The decoder is snake_case — camelCase keys on role/supervisor fields
        // are silently ignored and fall back to `[]` defaults. After recovery
        // (auto-synthesize orphan produces into `artifacts[]` and promote to
        // `supervisor_requires`), the result decodes successfully even though
        // the top-level `supervisorRequires` (camelCase) was ignored.
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "Test",
                    "description": "Test",
                    "roles": [
                        {
                            "name": "R",
                            "prompt": "p",
                            "producesArtifacts": ["X"],
                            "requiresArtifacts": ["Supervisor Task"],
                            "tools": []
                        }
                    ],
                    "artifacts": [{"name": "X", "description": "d"}],
                    "supervisorRequires": ["X"]
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError,
                       "camelCase keys should be tolerated: \(results[0].outputJSON)")
        guard case .teamCreation(let config) = results[0].signal else {
            XCTFail("Expected .teamCreation signal")
            return
        }
        // camelCase role fields fell back to [], so role.produces/requires are empty.
        XCTAssertTrue(config.roles[0].producesArtifacts.isEmpty,
                      "camelCase produces_artifacts should be ignored, defaulting to []")
        XCTAssertTrue(config.roles[0].requiresArtifacts.isEmpty,
                      "camelCase requires_artifacts should be ignored, defaulting to []")
    }

    // MARK: - Tool Schema Properties

    func testCreateTeam_category() {
        XCTAssertEqual(CreateTeamTool.category, .collaboration)
    }

    func testCreateTeam_excludedInMeetings() {
        XCTAssertTrue(CreateTeamTool.excludedInMeetings)
    }

    func testCreateTeam_notCacheable() {
        XCTAssertFalse(CreateTeamTool.isCacheable)
    }

    func testCreateTeam_unavailableToRoles() {
        XCTAssertFalse(CreateTeamTool.availableToRoles,
                       "create_team must be unavailable to team roles — it has a dedicated invocation path")
    }

    // MARK: - String-form team_config (LLMs that pass tool args as escaped JSON strings)

    func testCreateTeam_stringFormTeamConfig_decodesSuccessfully() {
        // Some providers encode object args as JSON-string literals. The handler
        // accepts both forms; this pins the string-form path.
        let escapedConfig = #"{\"name\":\"StringTeam\",\"description\":\"x\",\"roles\":[{\"name\":\"E\",\"prompt\":\"p\",\"produces_artifacts\":[\"X\"],\"requires_artifacts\":[\"Supervisor Task\"],\"tools\":[]}],\"artifacts\":[{\"name\":\"X\",\"description\":\"d\"}],\"supervisor_requires\":[\"X\"]}"#
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {"team_config": "\(escapedConfig)"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError, "String-form team_config should decode successfully")
        if case .teamCreation(let config) = results[0].signal {
            XCTAssertEqual(config.name, "StringTeam")
        } else {
            XCTFail("Expected .teamCreation signal")
        }
    }

    // MARK: - New decode-time validation

    func testCreateTeam_orphanArtifactReference_rewritesToSupervisorTask() {
        // A role requires an artifact that no role produces. Rather than fail
        // (engine would stall on "no roles ready"), the decoder rewrites the
        // phantom dependency to the implicit Supervisor Task so the role can
        // start from the supervisor brief.
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "T",
                    "description": "d",
                    "roles": [
                        {"name": "Eng", "prompt": "p", "produces_artifacts": [], "requires_artifacts": ["Phantom"], "tools": []}
                    ],
                    "artifacts": [],
                    "supervisor_requires": []
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError,
                       "Phantom dependency should be rewritten, not rejected: \(results[0].outputJSON)")
        guard case .teamCreation(let config) = results[0].signal else {
            XCTFail("Expected .teamCreation signal")
            return
        }
        XCTAssertEqual(config.roles[0].requiresArtifacts, ["Supervisor Task"],
                       "Phantom requires should be rewritten to Supervisor Task.")
    }

    func testCreateTeam_invalidSupervisorMode_returnsError() {
        // Typo in supervisor_mode — strong-typed decode rejects.
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "T",
                    "description": "d",
                    "supervisor_mode": "autonimous",
                    "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
                    "artifacts": [{"name": "X", "description": "d"}],
                    "supervisor_requires": ["X"]
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("supervisor_mode"))
    }

    // MARK: - Signal payload integrity

    func testCreateTeam_signalCarriesParsedConfig_notRawArgs() {
        // The signal must carry the typed `GeneratedTeamConfig`, not just the raw args —
        // any consumer of the signal can call GeneratedTeamBuilder.build directly.
        let call = StepToolCall(
            name: ToolNames.createTeam,
            argumentsJSON: """
            {
                "team_config": {
                    "name": "Signal Team",
                    "description": "d",
                    "supervisor_mode": "autonomous",
                    "acceptance_mode": "afterEachRole",
                    "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
                    "artifacts": [{"name": "X", "description": "d"}],
                    "supervisor_requires": ["X"]
                }
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        guard case .teamCreation(let config) = results[0].signal else {
            XCTFail("Expected .teamCreation signal"); return
        }
        XCTAssertEqual(config.name, "Signal Team")
        XCTAssertEqual(config.supervisorMode, .autonomous,
                       "Signal must carry the typed enum (not the raw string)")
        XCTAssertEqual(config.acceptanceMode, .afterEachRole)
    }
}
