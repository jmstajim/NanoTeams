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

    private static func roleDef(
        id: String = "sup",
        name: String = "Supervisor",
        icon: String = "crown",
        iconColor: String = "#FFFFFF",
        iconBackground: String = RoleColorDefaults.defaultHex
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, icon: icon,
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconColor: iconColor, iconBackground: iconBackground
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
            "roleDefinition compares by renderIdentity — two definitions built alike must "
                + "stay equal. Note the fixture's createdAt/updatedAt differ between the two "
                + "calls: that is the case FOR a presentation projection over a whole-struct "
                + "comparison, which would over-fire on a timestamp nothing renders."
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

    // MARK: - Render granularity
    //
    // Each case renames or recolours the role WITHOUT changing its id — the
    // Team-editor gesture. The body reads the changed field, so `==` must
    // report a difference or `.equatable()` freezes the old pixels. An
    // `id`-only comparison answers a question this view does not ask, and
    // `TeamRoleDefinition.==` is itself an identity shortcut (CLAUDE.md #42),
    // so it cannot stand in for "would this render differently" either.

    func testNotEqual_whenRoleDefinitionNameDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(roleDefinition: Self.roleDef(name: "Alpha")),
            Self.makeCard(roleDefinition: Self.roleDef(name: "Beta")),
            "the view renders roleDefinition?.name — a rename must break ==")
    }

    func testNotEqual_whenRoleDefinitionIconDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(roleDefinition: Self.roleDef(icon: "hammer")),
            Self.makeCard(roleDefinition: Self.roleDef(icon: "wrench")),
            "the avatar renders roleDefinition?.icon")
    }

    func testNotEqual_whenRoleDefinitionIconBackgroundDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(roleDefinition: Self.roleDef(iconBackground: "#112233")),
            Self.makeCard(roleDefinition: Self.roleDef(iconBackground: "#445566")),
            "resolvedTintColor and resolvedIconBackground both read iconBackground")
    }

    func testNotEqual_whenRoleDefinitionIconColorDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(roleDefinition: Self.roleDef(iconColor: "#FFFFFF")),
            Self.makeCard(roleDefinition: Self.roleDef(iconColor: "#000000")),
            "iconColor is a presentation field — the projection covers the whole set")
    }
}
