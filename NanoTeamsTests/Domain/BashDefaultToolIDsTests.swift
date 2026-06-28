import XCTest
@testable import NanoTeams

/// Pins the "bash enabled by default for code-writing roles" policy.
///
/// `bash` (+ its companion `bash_output`) is granted by default ONLY to the
/// three code-writing roles — Software Engineer, Coding Assistant, Coding Agent.
/// Read/review roles (Tech Lead, Code Reviewer, SRE) and every non-programmer
/// role stay shell-free. The grant lives in three surfaces that must agree:
///   1. inline role templates (`SystemTemplates.roles`)
///   2. fallback unions (`SystemTemplates.fallbackToolIDs`)
///   3. team-specific `customize` closures (`TeamTemplateFactory`)
/// bash and bash_output are always granted together — a `run_in_background`
/// process is unreadable without `bash_output`.
final class BashDefaultToolIDsTests: XCTestCase {

    private typealias TN = ToolNames

    /// Roles that should carry shell access by default.
    private let codeWritingRoleIDs = ["softwareEngineer", "codingAssistant", "codingAgent"]

    /// Roles that must NOT carry shell access (review/read + non-programmer).
    private let shellFreeRoleIDs = [
        "supervisor", "productManager", "uxResearcher", "uxDesigner",
        "techLead", "codeReviewer", "sre", "tpm",
        "loreMaster", "npcCreator", "encounterArchitect", "rulesArbiter", "questMaster",
        "theAgreeable", "theOpen", "theConscientious", "theExtrovert", "theNeurotic",
        "assistant", "autovisor",
    ]

    // MARK: - Inline role templates

    func testRoleTemplates_codeWritingRoles_haveBashAndBashOutput() {
        for id in codeWritingRoleIDs {
            guard let template = SystemTemplates.roles[id] else {
                XCTFail("role template `\(id)` must exist")
                continue
            }
            XCTAssertTrue(template.toolIDs.contains(TN.bash),
                          "`\(id)` template must include bash by default")
            XCTAssertTrue(template.toolIDs.contains(TN.bashOutput),
                          "`\(id)` template must include bash_output (paired with bash)")
        }
    }

    func testRoleTemplates_shellFreeRoles_lackBash() {
        for id in shellFreeRoleIDs {
            guard let template = SystemTemplates.roles[id] else { continue }
            XCTAssertFalse(template.toolIDs.contains(TN.bash),
                           "`\(id)` template must NOT include bash")
            XCTAssertFalse(template.toolIDs.contains(TN.bashOutput),
                           "`\(id)` template must NOT include bash_output")
        }
    }

    // MARK: - Fallback unions

    func testFallbackToolIDs_codeWritingRoles_haveBashAndBashOutput() {
        for id in codeWritingRoleIDs {
            guard let fallback = SystemTemplates.fallbackToolIDs[id] else {
                XCTFail("fallback toolIDs for `\(id)` must exist")
                continue
            }
            XCTAssertTrue(fallback.contains(TN.bash),
                          "fallback for `\(id)` must include bash")
            XCTAssertTrue(fallback.contains(TN.bashOutput),
                          "fallback for `\(id)` must include bash_output")
        }
    }

    func testFallbackToolIDs_shellFreeRoles_lackBash() {
        for id in shellFreeRoleIDs {
            guard let fallback = SystemTemplates.fallbackToolIDs[id] else { continue }
            XCTAssertFalse(fallback.contains(TN.bash),
                           "fallback for `\(id)` must NOT include bash")
            XCTAssertFalse(fallback.contains(TN.bashOutput),
                           "fallback for `\(id)` must NOT include bash_output")
        }
    }

    func testFallbackCustomRole_lacksBash() {
        XCTAssertFalse(SystemTemplates.fallbackCustomRoleToolIDs.contains(TN.bash),
                       "custom-role fallback must NOT include bash")
        XCTAssertFalse(SystemTemplates.fallbackCustomRoleToolIDs.contains(TN.bashOutput),
                       "custom-role fallback must NOT include bash_output")
    }

    // MARK: - Bundled team factories (the customize-closure surfaces)

    /// Resolve a role's toolIDs out of a bundled team by its `systemRoleID`.
    private func toolIDs(in team: Team, systemRoleID: String) -> [String]? {
        team.roles.first { $0.systemRoleID == systemRoleID }?.toolIDs
    }

    private func assertHasBash(_ ids: [String]?, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let ids else {
            XCTFail("\(label): role missing from bundled team", file: file, line: line)
            return
        }
        XCTAssertTrue(ids.contains(TN.bash), "\(label) must include bash", file: file, line: line)
        XCTAssertTrue(ids.contains(TN.bashOutput),
                      "\(label) must include bash_output", file: file, line: line)
    }

    private func assertNoBash(_ ids: [String]?, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let ids else { return }
        XCTAssertFalse(ids.contains(TN.bash), "\(label) must NOT include bash", file: file, line: line)
        XCTAssertFalse(ids.contains(TN.bashOutput),
                       "\(label) must NOT include bash_output", file: file, line: line)
    }

    func testFaangTeam_softwareEngineerHasBash_reviewRolesDoNot() {
        let team = TeamTemplateFactory.faang()
        assertHasBash(toolIDs(in: team, systemRoleID: "softwareEngineer"), "FAANG Software Engineer")
        assertNoBash(toolIDs(in: team, systemRoleID: "techLead"), "FAANG Tech Lead")
        assertNoBash(toolIDs(in: team, systemRoleID: "codeReviewer"), "FAANG Code Reviewer")
        assertNoBash(toolIDs(in: team, systemRoleID: "sre"), "FAANG SRE")
        assertNoBash(toolIDs(in: team, systemRoleID: "productManager"), "FAANG Product Manager")
    }

    func testEngineeringTeam_softwareEngineerHasBash_reviewRolesDoNot() {
        let team = TeamTemplateFactory.engineering()
        assertHasBash(toolIDs(in: team, systemRoleID: "softwareEngineer"), "Engineering Software Engineer")
        assertNoBash(toolIDs(in: team, systemRoleID: "techLead"), "Engineering Tech Lead")
        assertNoBash(toolIDs(in: team, systemRoleID: "codeReviewer"), "Engineering Code Reviewer")
    }

    func testStartupTeam_softwareEngineerHasBash() {
        // Startup re-assigns SWE toolIDs in a customize closure — must stay in sync.
        let team = TeamTemplateFactory.startup()
        assertHasBash(toolIDs(in: team, systemRoleID: "softwareEngineer"), "Startup Software Engineer")
    }

    func testCodingAssistantTeam_hasBash() {
        // Coding Assistant re-assigns toolIDs in a customize closure.
        let team = TeamTemplateFactory.codingAssistant()
        assertHasBash(toolIDs(in: team, systemRoleID: "codingAssistant"), "Coding Assistant")
    }

    func testCodingAgentTeam_hasBash() {
        let team = TeamTemplateFactory.codingAgent()
        assertHasBash(toolIDs(in: team, systemRoleID: "codingAgent"), "Coding Agent")
    }

    func testNonProgrammerTeams_haveNoBash() {
        // Personal Assistant re-assigns toolIDs (document-only) — must stay shell-free.
        let assistant = TeamTemplateFactory.assistant()
        assertNoBash(toolIDs(in: assistant, systemRoleID: "assistant"), "Personal Assistant")

        let quest = TeamTemplateFactory.questParty()
        for role in quest.roles where !role.isSupervisor {
            assertNoBash(role.toolIDs, "Quest Party \(role.name)")
        }

        let discussion = TeamTemplateFactory.discussionClub()
        for role in discussion.roles where !role.isSupervisor {
            assertNoBash(role.toolIDs, "Discussion Club \(role.name)")
        }
    }
}
