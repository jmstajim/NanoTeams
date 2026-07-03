import XCTest

@testable import NanoTeams

/// Computer-use is a dangerous capability with a deliberate default-grant surface:
/// the dialog-first assistant roles (Assistant, Coding Assistant) and the Autovisor
/// manager carry it out of the box (execution stays gated by the permission layer —
/// Manual approval by default); every other built-in role must NOT ship it and gets
/// it only explicitly in the Team Editor. Pins both sides of that boundary.
@MainActor
final class ComputerUseDefaultToolIDsTests: XCTestCase {

    private let computerUseTools: Set<String> = [
        ToolNames.screenCapture, ToolNames.uiClick, ToolNames.uiType, ToolNames.uiKey, ToolNames.uiScroll,
    ]

    /// System role IDs that are ALLOWED (and required) to grant computer-use by default.
    private let grantedSystemRoleIDs: Set<String> = ["assistant", "codingAssistant"]

    func testOnlyAssistantRolesGrantComputerUseByDefault() {
        for team in Team.defaultTeams {
            for role in team.roles {
                let granted = Set(role.toolIDs).intersection(computerUseTools)
                if let sid = role.systemRoleID, grantedSystemRoleIDs.contains(sid) {
                    XCTAssertEqual(
                        granted, computerUseTools,
                        "\(team.name) / \(role.name) must grant the full computer-use set by default")
                } else {
                    XCTAssertTrue(
                        granted.isEmpty,
                        "\(team.name) / \(role.name) grants a computer-use tool by default")
                }
            }
        }
    }

    func testAutovisorManagerGrantsComputerUseByDefault() {
        // The hidden manager team isn't in `defaultTeams` — pin it explicitly.
        let manager = TeamTemplateFactory.autovisor().roles.first {
            $0.systemRoleID == AutovisorConstants.managerRoleSystemID
        }
        XCTAssertNotNil(manager)
        XCTAssertTrue(
            computerUseTools.isSubset(of: Set(manager?.toolIDs ?? [])),
            "Autovisor manager must carry the full computer-use set by default")
        // They must be OPTIONAL (user can toggle off in the role editor), not mandatory.
        XCTAssertTrue(
            computerUseTools.isDisjoint(with: Set(AutovisorConstants.managerMandatoryToolIDs)),
            "computer-use tools must stay optional for the manager, never mandatory")
        XCTAssertTrue(
            computerUseTools.isSubset(of: Set(AutovisorConstants.managerOptionalToolIDs)),
            "computer-use tools must be in the manager's allowed-optional set or the on-open prune strips them")
    }

    func testFallbackToolIDs_matchTemplateGrants() {
        // The no-team fallback map must agree with the templates for the granted roles.
        for sid in grantedSystemRoleIDs {
            let fallback = SystemTemplates.fallbackToolIDs[sid] ?? []
            XCTAssertTrue(
                computerUseTools.isSubset(of: fallback),
                "fallbackToolIDs[\(sid)] must include the computer-use set")
        }
        XCTAssertTrue(
            computerUseTools.isDisjoint(with: SystemTemplates.fallbackCustomRoleToolIDs),
            "custom roles must NOT get computer-use via the fallback")
    }
}
