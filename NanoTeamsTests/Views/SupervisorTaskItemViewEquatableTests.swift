import SwiftUI
import XCTest

@testable import NanoTeams

/// Drift-guard for `SupervisorTaskItemView.==` — the same convention as
/// `MessageBubbleEquatableTests`. Each prop covered must participate in
/// equality; the view is rendered under `.equatable()` in the feed
/// dispatcher, so a prop missing from `==` silently drops its updates.
///
/// The `roleDefinition` pins matter most: the roster Supervisor
/// definition is what upgrades this card from the generic "person"
/// avatar fallback to the Supervisor's own icon/color, and without the
/// `id` term in `==` a roster swap (e.g. a delegated child's team, or a
/// different team after a team switch) would leave a stale avatar on
/// screen.
@MainActor
final class SupervisorTaskItemViewEquatableTests: XCTestCase {

    // MARK: - Fixtures

    private static let baselineCreatedAt = Date(timeIntervalSince1970: 1_000)

    private static func roleDef(id: String = "sup") -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: "Supervisor", icon: "crown",
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconBackground: RoleColorDefaults.defaultHex
        )
    }

    /// Factory with overridable knobs. Defaults form the canonical
    /// baseline; each test overrides exactly ONE knob.
    private static func makeCard(
        createdAt: Date? = nil,
        supervisorTask: String = "Build the thing",
        clippedTexts: [String] = [],
        attachmentPaths: [String] = [],
        workFolderURL: URL? = nil,
        roleDefinition: TeamRoleDefinition? = nil,
        onAvatarTap: (() -> Void)? = nil
    ) -> SupervisorTaskItemView {
        SupervisorTaskItemView(
            createdAt: createdAt ?? baselineCreatedAt,
            supervisorTask: supervisorTask,
            clippedTexts: clippedTexts,
            attachmentPaths: attachmentPaths,
            workFolderURL: workFolderURL,
            roleDefinition: roleDefinition,
            onAvatarTap: onAvatarTap
        )
    }

    // MARK: - Identical baselines compare equal

    func testEqual_whenAllPropsMatch() async {
        XCTAssertEqual(Self.makeCard(), Self.makeCard())
    }

    func testEqual_whenRoleDefinitionsShareID() async {
        XCTAssertEqual(
            Self.makeCard(roleDefinition: Self.roleDef()),
            Self.makeCard(roleDefinition: Self.roleDef()),
            "roleDefinition compares by id — two definitions with the same id must not break equality."
        )
    }

    // MARK: - Per-prop drift coverage

    func testNotEqual_whenCreatedAtDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(createdAt: Date(timeIntervalSince1970: 2_000)))
    }

    func testNotEqual_whenSupervisorTaskDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(supervisorTask: "different"))
    }

    func testNotEqual_whenClippedTextsDiffer() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(clippedTexts: ["clip"]))
    }

    func testNotEqual_whenAttachmentPathsDiffer() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(attachmentPaths: ["file.txt"]))
    }

    func testNotEqual_whenWorkFolderURLDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(),
            Self.makeCard(workFolderURL: URL(fileURLWithPath: "/tmp/x"))
        )
    }

    func testNotEqual_whenRoleDefinitionIDDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(roleDefinition: Self.roleDef(id: "sup-a")),
            Self.makeCard(roleDefinition: Self.roleDef(id: "sup-b")),
            "A roster swap must re-render the card's avatar/name/tint."
        )
    }

    func testNotEqual_whenRoleDefinitionAppears() async {
        XCTAssertNotEqual(
            Self.makeCard(roleDefinition: nil),
            Self.makeCard(roleDefinition: Self.roleDef()),
            "nil → resolved definition is the fallback-avatar → crown transition; it must break equality."
        )
    }

    // MARK: - Closure exclusion

    /// `onAvatarTap` is intentionally NOT in `==` (closures aren't
    /// Equatable; the capture is derived from props that ARE compared).
    func testEqual_whenOnlyOnAvatarTapDiffers() async {
        let a = Self.makeCard(onAvatarTap: { })
        let b = Self.makeCard(onAvatarTap: { })
        XCTAssertEqual(a, b, "onAvatarTap intentionally excluded from ==; closure-only diffs must not invalidate cache.")
    }
}
