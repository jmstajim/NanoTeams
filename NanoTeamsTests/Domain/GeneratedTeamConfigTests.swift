import XCTest
@testable import NanoTeams

final class GeneratedTeamConfigTests: XCTestCase {

    // MARK: - JSON Decode

    func testDecode_fullConfig_allFieldsPresent() throws {
        let json = """
        {
            "name": "Test Team",
            "description": "A test team",
            "supervisor_mode": "autonomous",
            "acceptance_mode": "afterEachRole",
            "roles": [
                {
                    "name": "Engineer",
                    "prompt": "Build things",
                    "produces_artifacts": ["Code"],
                    "requires_artifacts": ["Supervisor Task"],
                    "tools": ["read_file", "write_file"],
                    "use_planning_phase": true,
                    "icon": "hammer",
                    "icon_background": "#4A90D9"
                }
            ],
            "artifacts": [
                {
                    "name": "Code",
                    "description": "Source code",
                    "icon": "doc.text"
                }
            ],
            "supervisor_requires": ["Code"]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(GeneratedTeamConfig.self, from: data)

        XCTAssertEqual(config.name, "Test Team")
        XCTAssertEqual(config.description, "A test team")
        XCTAssertEqual(config.supervisorMode, .autonomous)
        XCTAssertEqual(config.acceptanceMode, .afterEachRole)
        XCTAssertEqual(config.roles.count, 1)
        XCTAssertEqual(config.roles[0].name, "Engineer")
        XCTAssertEqual(config.roles[0].prompt, "Build things")
        XCTAssertEqual(config.roles[0].producesArtifacts, ["Code"])
        XCTAssertEqual(config.roles[0].requiresArtifacts, ["Supervisor Task"])
        XCTAssertEqual(config.roles[0].tools, ["read_file", "write_file"])
        XCTAssertEqual(config.roles[0].usePlanningPhase, true)
        XCTAssertEqual(config.roles[0].icon, "hammer")
        XCTAssertEqual(config.roles[0].iconBackground, "#4A90D9")
        XCTAssertEqual(config.artifacts.count, 1)
        XCTAssertEqual(config.artifacts[0].name, "Code")
        XCTAssertEqual(config.supervisorRequires, ["Code"])
    }

    func testDecode_minimalConfig_optionalFieldsDefault() throws {
        let json = """
        {
            "name": "Minimal",
            "description": "Minimal team",
            "roles": [
                {
                    "name": "Worker",
                    "prompt": "Do work",
                    "produces_artifacts": ["Output"],
                    "requires_artifacts": ["Supervisor Task"],
                    "tools": ["read_file"]
                }
            ],
            "artifacts": [
                {"name": "Output", "description": "Result"}
            ],
            "supervisor_requires": ["Output"]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(GeneratedTeamConfig.self, from: data)

        XCTAssertNil(config.supervisorMode)
        XCTAssertNil(config.acceptanceMode)
        XCTAssertNil(config.roles[0].usePlanningPhase)
        XCTAssertNil(config.roles[0].icon)
        XCTAssertNil(config.roles[0].iconBackground)
        XCTAssertNil(config.artifacts[0].icon)
    }

    func testDecode_chatTeam_emptySupervisorRequires() throws {
        let json = """
        {
            "name": "Chat Team",
            "description": "Interactive",
            "roles": [
                {
                    "name": "Assistant",
                    "prompt": "Help the user",
                    "produces_artifacts": [],
                    "requires_artifacts": ["Supervisor Task"],
                    "tools": ["read_file", "ask_supervisor"]
                }
            ],
            "artifacts": [],
            "supervisor_requires": []
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(GeneratedTeamConfig.self, from: data)

        XCTAssertTrue(config.roles[0].producesArtifacts.isEmpty)
        XCTAssertTrue(config.supervisorRequires.isEmpty)
    }

    // MARK: - Round-trip

    func testEncodeDecodeRoundTrip() throws {
        let role = GeneratedTeamConfig.RoleConfig(
            name: "Dev", prompt: "Code",
            producesArtifacts: ["App"], requiresArtifacts: ["Supervisor Task"],
            tools: ["write_file"], usePlanningPhase: true, icon: "hammer", iconBackground: "#FF0000"
        )
        let artifact = GeneratedTeamConfig.ArtifactConfig(name: "App", description: "The app", icon: "app")
        let config = GeneratedTeamConfig(
            name: "RT Team", description: "Round-trip",
            supervisorMode: .manual, acceptanceMode: .finalOnly,
            roles: [role], artifacts: [artifact], supervisorRequires: ["App"]
        )

        // Encode goes through synthesized Codable, which writes enum rawValues for
        // SupervisorMode/AcceptanceMode — round-trip through the validating decoder.
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GeneratedTeamConfig.self, from: data)

        XCTAssertEqual(config, decoded)
    }

    // MARK: - Hashable

    func testHashable_equalConfigsHaveSameHash() {
        let role = GeneratedTeamConfig.RoleConfig(
            name: "X", prompt: "p",
            producesArtifacts: [], requiresArtifacts: [],
            tools: [], usePlanningPhase: nil, icon: nil, iconBackground: nil
        )
        let config1 = GeneratedTeamConfig(
            name: "T", description: "D",
            roles: [role], artifacts: [], supervisorRequires: []
        )
        let config2 = GeneratedTeamConfig(
            name: "T", description: "D",
            roles: [role], artifacts: [], supervisorRequires: []
        )

        XCTAssertEqual(config1, config2)
        XCTAssertEqual(config1.hashValue, config2.hashValue)
    }

    func testHashable_differentConfigsNotEqual() {
        let role = GeneratedTeamConfig.RoleConfig(
            name: "X", prompt: "p",
            producesArtifacts: [], requiresArtifacts: [],
            tools: [], usePlanningPhase: nil, icon: nil, iconBackground: nil
        )
        let config1 = GeneratedTeamConfig(
            name: "Team A", description: "D",
            roles: [role], artifacts: [], supervisorRequires: []
        )
        let config2 = GeneratedTeamConfig(
            name: "Team B", description: "D",
            roles: [role], artifacts: [], supervisorRequires: []
        )

        XCTAssertNotEqual(config1, config2)
    }

    // MARK: - Decode Failure

    func testDecode_missingRequiredField_throws() {
        let json = """
        {
            "name": "Broken",
            "roles": [],
            "artifacts": [],
            "supervisor_requires": []
        }
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GeneratedTeamConfig.self, from: data))
    }

    // MARK: - Strong-typed enum rejection (typo guards)

    func testDecode_unknownSupervisorMode_throws() {
        let json = """
        {
            "name": "Bad",
            "description": "d",
            "supervisor_mode": "autnomous",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GeneratedTeamConfig.self, from: json)) { error in
            // Surface debug description so a future maintainer sees what was rejected.
            XCTAssertTrue("\(error)".contains("supervisor_mode"))
        }
    }

    func testDecode_unknownAcceptanceMode_throws() {
        let json = """
        {
            "name": "Bad",
            "description": "d",
            "acceptance_mode": "wheneverIFeelLikeIt",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GeneratedTeamConfig.self, from: json))
    }

    func testDecode_acceptanceMode_caseInsensitive() throws {
        // The LLM may emit `FinalOnly` / `finalonly` / `finalOnly` — all should decode.
        for variant in ["finalOnly", "FinalOnly", "FINALONLY"] {
            let json = """
            {
                "name": "T",
                "description": "d",
                "acceptance_mode": "\(variant)",
                "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
                "artifacts": [{"name": "X", "description": "d"}],
                "supervisor_requires": ["X"]
            }
            """.data(using: .utf8)!
            let cfg = try JSONDecoder().decode(GeneratedTeamConfig.self, from: json)
            XCTAssertEqual(cfg.acceptanceMode, .finalOnly, "Variant '\(variant)' should decode")
        }
    }

    func testDecode_emptyEnumString_treatedAsNil() throws {
        // LLMs sometimes emit `""` for optional string fields — accept rather than reject.
        let json = """
        {
            "name": "T",
            "description": "d",
            "supervisor_mode": "",
            "acceptance_mode": "",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(GeneratedTeamConfig.self, from: json)
        XCTAssertNil(cfg.supervisorMode)
        XCTAssertNil(cfg.acceptanceMode)
    }

    // MARK: - Validation: name + roles non-empty

    func testDecode_emptyName_synthesizesFromDescription() throws {
        // Recovery: empty `name` is synthesized from `description` rather than
        // rejecting the whole team. Captured on models that emit a valid
        // `team_config` but forget the top-level `name` field.
        let json = """
        {
            "name": "",
            "description": "Build a calculator app",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(GeneratedTeamConfig.self, from: json)
        XCTAssertEqual(cfg.name, "Build a calculator app")
    }

    func testDecode_whitespaceOnlyName_synthesizesFromDescription() throws {
        let json = """
        {
            "name": "   \\n  ",
            "description": "Build a calculator app",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(GeneratedTeamConfig.self, from: json)
        XCTAssertEqual(cfg.name, "Build a calculator app")
    }

    func testDecode_emptyNameAndDescription_throws() {
        // Name synthesis only applies when `description` is non-empty. Both empty →
        // still a hard failure so genuinely broken payloads aren't swallowed.
        let json = """
        {
            "name": "",
            "description": "",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GeneratedTeamConfig.self, from: json))
    }

    func testDecode_emptyRolesArray_throws() {
        let json = """
        {
            "name": "T",
            "description": "d",
            "roles": [],
            "artifacts": [],
            "supervisor_requires": []
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GeneratedTeamConfig.self, from: json))
    }

    // MARK: - Validation: artifact reference cross-checks

    func testDecode_phantomRequiresArtifact_rewritesToSupervisorTask() throws {
        // Recovery: a role requires an artifact that no role produces. Rather than
        // fail (which would make the consumer stall forever on "no roles ready"),
        // the decoder rewrites the phantom dependency to the implicit Supervisor
        // Task. Captured on non-English models that translate "Supervisor Task"
        // and on models that declare-but-don't-produce an intermediate artifact.
        let json = """
        {
            "name": "T",
            "description": "d",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": [], "requires_artifacts": ["Phantom"], "tools": []}],
            "artifacts": [],
            "supervisor_requires": []
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(GeneratedTeamConfig.self, from: json)
        XCTAssertEqual(cfg.roles[0].requiresArtifacts, ["Supervisor Task"])
    }

    func testDecode_orphanProducesArtifact_autoSynthesizesArtifactAndPromotes() throws {
        // Recovery: a role produces an artifact that's missing from `artifacts[]`.
        // The decoder auto-synthesizes the artifact entry (borrowing the role's
        // prompt for a stub description) and promotes it to `supervisor_requires`
        // so the role's work doesn't flow nowhere.
        let json = """
        {
            "name": "T",
            "description": "d",
            "roles": [{"name": "R", "prompt": "Build it.", "produces_artifacts": ["NotDeclared"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [],
            "supervisor_requires": []
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(GeneratedTeamConfig.self, from: json)
        XCTAssertTrue(cfg.artifacts.contains { $0.name == "NotDeclared" },
                      "Orphan produced artifact should be auto-declared.")
        XCTAssertTrue(cfg.supervisorRequires.contains("NotDeclared"),
                      "Orphan produced artifact should be promoted to supervisor_requires.")
    }

    func testDecode_orphanSupervisorRequires_throws() {
        let json = """
        {
            "name": "T",
            "description": "d",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["NeverDeclared"]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GeneratedTeamConfig.self, from: json))
    }

    func testDecode_supervisorTaskAlwaysImplicitlyDeclared() throws {
        // Roles can require "Supervisor Task" without it being in the artifacts list —
        // the builder always injects it.
        let json = """
        {
            "name": "T",
            "description": "d",
            "roles": [{"name": "R", "prompt": "p", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []}],
            "artifacts": [{"name": "X", "description": "d"}],
            "supervisor_requires": ["X"]
        }
        """.data(using: .utf8)!
        XCTAssertNoThrow(try JSONDecoder().decode(GeneratedTeamConfig.self, from: json))
    }

    func testDecode_multipleRoles_preservesOrder() throws {
        let json = """
        {
            "name": "Multi",
            "description": "Multiple roles",
            "roles": [
                {"name": "Alpha", "prompt": "A", "produces_artifacts": ["X"], "requires_artifacts": ["Supervisor Task"], "tools": []},
                {"name": "Beta", "prompt": "B", "produces_artifacts": ["Y"], "requires_artifacts": ["X"], "tools": []},
                {"name": "Gamma", "prompt": "C", "produces_artifacts": ["Z"], "requires_artifacts": ["Y"], "tools": []}
            ],
            "artifacts": [
                {"name": "X", "description": "X"},
                {"name": "Y", "description": "Y"},
                {"name": "Z", "description": "Z"}
            ],
            "supervisor_requires": ["Z"]
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(GeneratedTeamConfig.self, from: data)

        XCTAssertEqual(config.roles.count, 3)
        XCTAssertEqual(config.roles[0].name, "Alpha")
        XCTAssertEqual(config.roles[1].name, "Beta")
        XCTAssertEqual(config.roles[2].name, "Gamma")
    }
}
