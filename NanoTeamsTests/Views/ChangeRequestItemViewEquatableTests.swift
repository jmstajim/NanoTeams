import SwiftUI
import XCTest

@testable import NanoTeams

/// Drift-guard for `ChangeRequestItemView.==` — same convention as
/// `MessageBubbleEquatableTests`. Rendered under `.equatable()` in the feed
/// dispatcher, so a member the body renders but `==` skips has its updates
/// silently dropped.
///
/// This card is the one member of the feed family that takes NO
/// `TeamRoleDefinition`: its role label arrives pre-resolved as
/// `targetRoleName`, computed by the builder
/// (`ActivityFeedBuilder.swift:502`, `teamRoles.roleName(for:)`). That is
/// why it needs no render-identity case — the resolution happened upstream,
/// and the resolved String is what `==` compares. Recorded here rather than
/// left silent, so the absence does not read as an oversight (CLAUDE.md #92).
@MainActor
final class ChangeRequestItemViewEquatableTests: XCTestCase {

    // MARK: - Fixtures

    private static let baselineID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CA")!
    private static let baselineDate = Date(timeIntervalSince1970: 1_000)

    private static func request(
        changes: String = "Rename the endpoint",
        reasoning: String = "consistency",
        status: ChangeRequestStatus = .pending
    ) -> ChangeRequest {
        ChangeRequest(
            id: baselineID, createdAt: baselineDate,
            requestingRoleID: "code_reviewer", targetRoleID: "software_engineer",
            changes: changes, reasoning: reasoning, status: status
        )
    }

    private static func makeCard(
        request: ChangeRequest? = nil,
        targetRoleName: String = "Software Engineer"
    ) -> ChangeRequestItemView {
        ChangeRequestItemView(
            request: request ?? Self.request(),
            targetRoleName: targetRoleName
        )
    }

    // MARK: - Identical baselines compare equal

    func testEqual_whenAllPropsMatch() async {
        XCTAssertEqual(Self.makeCard(), Self.makeCard())
    }

    // MARK: - Per-prop drift coverage

    func testNotEqual_whenChangesDiffer() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(request: Self.request(changes: "other")))
    }

    func testNotEqual_whenReasoningDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(request: Self.request(reasoning: "other")))
    }

    /// The status badge is the card's most visible element; a vote landing
    /// while the feed is open must repaint it.
    func testNotEqual_whenStatusDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(request: Self.request(status: .approved)))
    }

    func testNotEqual_whenTargetRoleNameDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(targetRoleName: "Backend Engineer"))
    }
}
