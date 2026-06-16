import SwiftUI
import XCTest
@testable import NanoTeams

/// Pins `RoleConsultationsPanel.responseTint(for:)` — the status→tint mapping that
/// makes a failed/empty consultation render red (not green) in the structured
/// consultations panel. The visible payoff of `TeammateConsultation.fail(with:)`.
@MainActor
final class RoleConsultationsPanelTests: XCTestCase {

    func testResponseTint_completed_isSuccessTint() {
        XCTAssertEqual(RoleConsultationsPanel.responseTint(for: .completed), Colors.successTint)
    }

    func testResponseTint_failed_isErrorTint() {
        XCTAssertEqual(RoleConsultationsPanel.responseTint(for: .failed), Colors.errorTint)
    }

    func testResponseTint_pending_isNeutralTint() {
        XCTAssertEqual(RoleConsultationsPanel.responseTint(for: .pending), Colors.neutralTint)
    }

    func testResponseTint_failedDistinctFromCompleted() {
        XCTAssertNotEqual(
            RoleConsultationsPanel.responseTint(for: .failed),
            RoleConsultationsPanel.responseTint(for: .completed),
            "A failed consultation must not reuse the completed (green) tint."
        )
    }

    // MARK: - iconTint (status glyph foreground, symmetric with responseTint)

    func testIconTint_completed_isSuccess() {
        XCTAssertEqual(RoleConsultationsPanel.iconTint(for: .completed), Colors.success)
    }

    func testIconTint_failed_isError() {
        XCTAssertEqual(RoleConsultationsPanel.iconTint(for: .failed), Colors.error)
    }

    func testIconTint_pending_isWarning() {
        XCTAssertEqual(RoleConsultationsPanel.iconTint(for: .pending), Colors.warning)
    }

    func testIconTint_failedNotWarning() {
        XCTAssertNotEqual(
            RoleConsultationsPanel.iconTint(for: .failed),
            RoleConsultationsPanel.iconTint(for: .pending),
            "A failed consultation's icon must read red, not warning-orange over a red body."
        )
    }
}
