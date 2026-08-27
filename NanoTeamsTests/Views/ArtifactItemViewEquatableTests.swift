import SwiftUI
import XCTest

@testable import NanoTeams

/// Drift-guard for `ArtifactItemView.==` — same convention as
/// `MessageBubbleEquatableTests`. Rendered under `.equatable()` in the feed
/// dispatcher, so a member the body renders but `==` skips has its updates
/// silently dropped.
///
/// The `renderIdentity` cases pin GRANULARITY rather than participation: the
/// card renders `roleDefinition?.name` (`:25`) and `?.resolvedTintColor`
/// (`:26`, reading `iconBackground`), and the avatar renders `icon` +
/// `resolvedIconBackground` — none of which an `id`-only comparison can see.
@MainActor
final class ArtifactItemViewEquatableTests: XCTestCase {

    // MARK: - Fixtures

    private static let baselineDate = Date(timeIntervalSince1970: 1_000)

    private static func roleDef(
        id: String = "swe",
        name: String = "Software Engineer",
        icon: String = "hammer",
        iconColor: String = "#FFFFFF",
        iconBackground: String = RoleColorDefaults.defaultHex
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, icon: icon,
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconColor: iconColor, iconBackground: iconBackground
        )
    }

    private static func artifact(name: String = "Engineering Notes") -> Artifact {
        Artifact(name: name, createdAt: baselineDate, updatedAt: baselineDate)
    }

    private static func makeCard(
        artifact: Artifact? = nil,
        role: Role = .softwareEngineer,
        roleDefinition: TeamRoleDefinition? = nil,
        showHeader: Bool = true,
        originTaskID: Int = 1,
        workFolderURL: URL? = nil,
        onAvatarTap: (() -> Void)? = nil,
        roleLabelOverride: String? = nil,
        roleTeamSuffix: String? = nil
    ) -> ArtifactItemView {
        ArtifactItemView(
            artifact: artifact ?? Self.artifact(),
            role: role,
            roleDefinition: roleDefinition ?? roleDef(),
            showHeader: showHeader,
            originTaskID: originTaskID,
            workFolderURL: workFolderURL,
            onAvatarTap: onAvatarTap,
            roleLabelOverride: roleLabelOverride,
            roleTeamSuffix: roleTeamSuffix
        )
    }

    // MARK: - Identical baselines compare equal

    func testEqual_whenAllPropsMatch() async {
        XCTAssertEqual(Self.makeCard(), Self.makeCard())
    }

    func testEqual_whenOnlyOnAvatarTapDiffers() async {
        XCTAssertEqual(Self.makeCard(), Self.makeCard(onAvatarTap: {}))
    }

    // MARK: - Per-prop drift coverage

    func testNotEqual_whenArtifactDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(artifact: Self.artifact(name: "Release Notes")))
    }

    func testNotEqual_whenRoleDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(role: .codeReviewer))
    }

    func testNotEqual_whenShowHeaderDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(showHeader: false))
    }

    func testNotEqual_whenOriginTaskIDDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(originTaskID: 2))
    }

    func testNotEqual_whenWorkFolderURLDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(), Self.makeCard(workFolderURL: URL(fileURLWithPath: "/tmp/x")))
    }

    func testNotEqual_whenRoleLabelOverrideDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(roleLabelOverride: "Child SWE"))
    }

    func testNotEqual_whenRoleTeamSuffixDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(roleTeamSuffix: "Startup"))
    }

    func testNotEqual_whenRoleDefinitionIDDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(roleDefinition: Self.roleDef(id: "swe-a")),
            Self.makeCard(roleDefinition: Self.roleDef(id: "swe-b")))
    }

    // MARK: - Render granularity

    func testNotEqual_whenRoleDefinitionNameDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(roleDefinition: Self.roleDef(name: "Software Engineer")),
            Self.makeCard(roleDefinition: Self.roleDef(name: "Backend Engineer")),
            "the card renders roleDefinition?.name — a rename must break ==")
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
