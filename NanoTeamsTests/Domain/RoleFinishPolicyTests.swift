import XCTest
@testable import NanoTeams

/// Pins `RoleFinishPolicy.canFinish` — the single "Finish Role" affordance rule shared by
/// `TeamGraphView`, `RoleNodeRuntimeView`, and `Run.finishableAdvisoryRoles`.
final class RoleFinishPolicyTests: XCTestCase {

    private func def(required: [String] = [], produces: [String] = []) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "r", name: "R", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: required, producesArtifacts: produces)
        )
    }

    func testCanFinish_advisoryWorking_nonChat_true() {
        XCTAssertTrue(RoleFinishPolicy.canFinish(roleDef: def(required: ["A"]), status: .working, isChatMode: false))
    }

    func testCanFinish_advisoryReady_nonChat_true() {
        XCTAssertTrue(RoleFinishPolicy.canFinish(roleDef: def(required: ["A"]), status: .ready, isChatMode: false))
    }

    func testCanFinish_advisoryChatMode_false() {
        XCTAssertFalse(RoleFinishPolicy.canFinish(roleDef: def(required: ["A"]), status: .working, isChatMode: true))
    }

    func testCanFinish_producingRole_false() {
        XCTAssertFalse(RoleFinishPolicy.canFinish(roleDef: def(produces: ["A"]), status: .working, isChatMode: false))
    }

    func testCanFinish_observerRole_false() {
        XCTAssertFalse(RoleFinishPolicy.canFinish(roleDef: def(), status: .working, isChatMode: false))
    }

    func testCanFinish_nilRoleDef_false() {
        XCTAssertFalse(RoleFinishPolicy.canFinish(roleDef: nil, status: .working, isChatMode: false))
    }

    func testCanFinish_advisoryNonActiveStatus_false() {
        for status in [RoleExecutionStatus.idle, .done, .failed, .accepted, .needsAcceptance, .skipped, .revisionRequested] {
            XCTAssertFalse(
                RoleFinishPolicy.canFinish(roleDef: def(required: ["A"]), status: status, isChatMode: false),
                "advisory role in \(status) must not be finishable"
            )
        }
    }
}
