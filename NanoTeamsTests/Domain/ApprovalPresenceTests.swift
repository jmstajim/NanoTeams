import XCTest

@testable import NanoTeams

/// The one predicate for "is a human there to answer an approval card". Both gates spelled
/// it inline until 2026-09-07; the schema resolver, badge, preview and renderer now read the
/// same answer, so this table is the contract they all share.
final class ApprovalPresenceTests: XCTestCase {

    func testManualSupervisor_notUnderAutovisor_isAHuman() {
        XCTAssertTrue(ApprovalPresence.humanPresent(supervisorMode: .manual, underAutovisor: false))
    }

    /// Off removes `ask_supervisor` from the ROLES, not the approval card from the person.
    func testOffSupervisor_countsAsAHuman() {
        XCTAssertTrue(ApprovalPresence.humanPresent(supervisorMode: .off, underAutovisor: false))
    }

    /// `.autonomous` replaces the human with an LLM for QUESTIONS; an approval card has no
    /// LLM answerer, so there is nobody.
    func testAutonomousSupervisor_isNobody() {
        XCTAssertFalse(ApprovalPresence.humanPresent(supervisorMode: .autonomous, underAutovisor: false))
    }

    /// The Autovisor answers the task's questions; it never answers a card.
    func testUnderAutovisor_isNobody_whateverTheSupervisorMode() {
        for mode in SupervisorMode.allCases {
            XCTAssertFalse(ApprovalPresence.humanPresent(supervisorMode: mode, underAutovisor: true),
                           "\(mode) under the Autovisor must read as no human")
        }
    }

    /// Exhaustive: every mode has a row above, so a new case cannot inherit an answer.
    func testEveryModeIsClassified() {
        XCTAssertEqual(SupervisorMode.allCases.count, 3, "add a row above for the new mode")
    }
}
