import XCTest
@testable import NanoTeams

/// Pins `AcceptanceService.routeAccept` — the Autovisor's `manage_role accept` decision.
final class AcceptanceRouteTests: XCTestCase {

    private let roleID = "role_a"

    func testRouteAccept_needsAcceptance_routesToAccept() {
        // .needsAcceptance is checked first — even in a chat team, a producing role at
        // needsAcceptance is a real acceptance gate and must route to ordinary accept.
        let route = AcceptanceService.routeAccept(
            roleID: roleID,
            roleStatuses: [roleID: .needsAcceptance],
            isChatModeTask: true,
            roleIsProducing: true
        )
        XCTAssertEqual(route, .accept)
    }

    func testRouteAccept_chatWorkingAdvisory_routesToFinish() {
        let route = AcceptanceService.routeAccept(
            roleID: roleID,
            roleStatuses: [roleID: .working],
            isChatModeTask: true,
            roleIsProducing: false
        )
        XCTAssertEqual(route, .finishChatRole)
    }

    func testRouteAccept_chatWorkingProducing_rejectsWithStillWorking() {
        // A producing role in a chat team is not an advisory chat role — accept must not
        // finish it; it rejects with the ordinary message.
        let route = AcceptanceService.routeAccept(
            roleID: roleID,
            roleStatuses: [roleID: .working],
            isChatModeTask: true,
            roleIsProducing: true
        )
        XCTAssertEqual(route, .reject(reason: "Role is still working"))
    }

    func testRouteAccept_nonChatWorking_rejectsWithStillWorking() {
        let route = AcceptanceService.routeAccept(
            roleID: roleID,
            roleStatuses: [roleID: .working],
            isChatModeTask: false,
            roleIsProducing: false
        )
        XCTAssertEqual(route, .reject(reason: "Role is still working"))
    }

    func testRouteAccept_chatDoneAdvisory_routesToFinish() {
        // The auto-finished-but-task-not-closed zombie: a .done chat advisory role routes
        // to finish (idempotent) so finishRoleAndMaybeClose can close the task.
        let route = AcceptanceService.routeAccept(
            roleID: roleID, roleStatuses: [roleID: .done],
            isChatModeTask: true, roleIsProducing: false)
        XCTAssertEqual(route, .finishChatRole)
    }

    func testRouteAccept_chatFailedAdvisory_rejectsPreservingFailure() {
        // A failed chat advisory role must NOT be force-converted to .done — accept rejects,
        // preserving the failure record.
        let route = AcceptanceService.routeAccept(
            roleID: roleID, roleStatuses: [roleID: .failed],
            isChatModeTask: true, roleIsProducing: false)
        XCTAssertEqual(route, .reject(reason: "Cannot accept failed role"))
    }

    func testRouteAccept_chatRevisionRequestedAdvisory_rejects() {
        let route = AcceptanceService.routeAccept(
            roleID: roleID, roleStatuses: [roleID: .revisionRequested],
            isChatModeTask: true, roleIsProducing: false)
        XCTAssertEqual(route, .reject(reason: "Role is already in revision"))
    }

    func testRouteAccept_chatIdleAdvisory_rejects() {
        // idle/ready = work that never ran — not a chat-finish case (a step-less idle role
        // has nothing to finish).
        let route = AcceptanceService.routeAccept(
            roleID: roleID, roleStatuses: [roleID: .idle],
            isChatModeTask: true, roleIsProducing: false)
        XCTAssertEqual(route, .reject(reason: "Role has not started work yet"))
    }

    func testRouteAccept_chatMissingRole_rejectsNotFound() {
        // A role absent from roleStatuses must not masquerade as a chat finish.
        let route = AcceptanceService.routeAccept(
            roleID: "ghost",
            roleStatuses: [roleID: .working],
            isChatModeTask: true,
            roleIsProducing: false
        )
        XCTAssertEqual(route, .reject(reason: "Role not found: ghost"))
    }
}
