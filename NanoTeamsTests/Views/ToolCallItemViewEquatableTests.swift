import SwiftUI
import XCTest

@testable import NanoTeams

/// Drift-guard for `ToolCallItemView.==` — the same convention as
/// `MessageBubbleEquatableTests`. The card is rendered under `.equatable()` in
/// the feed dispatcher (`TeamActivityFeedView.swift:691`), so anything the body
/// RENDERS but `==` does not compare has its updates silently dropped.
///
/// Two groups of cases, and the second is the one this suite was written for.
/// The per-prop cases pin that each stored member participates at all. The
/// `renderIdentity` cases pin the GRANULARITY of the two role members: the card
/// renders `roleDefinition?.name` (`:22`), `roleDefinition?.resolvedTintColor`
/// (`:23`, reading `iconBackground`), the avatar's `icon` +
/// `resolvedIconBackground`, and resolves names out of `teamRoles` via
/// `roleName(for:)` (`:40`, reading `.name` and `.systemRoleID`). Comparing
/// either member by `id` alone therefore answers a question the card does not
/// ask — and `TeamRoleDefinition.==` is itself an identity shortcut
/// (`lhs.id == rhs.id`, CLAUDE.md #42), so it cannot stand in for
/// "would this render differently" either.
@MainActor
final class ToolCallItemViewEquatableTests: XCTestCase {

    // MARK: - Fixtures

    private static let baselineCreatedAt = Date(timeIntervalSince1970: 1_000)
    private static let baselineCallID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    private static func roleDef(
        id: String = "swe",
        name: String = "Software Engineer",
        icon: String = "hammer",
        iconColor: String = "#FFFFFF",
        iconBackground: String = RoleColorDefaults.defaultHex,
        systemRoleID: String? = nil
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, icon: icon,
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            systemRoleID: systemRoleID, iconColor: iconColor, iconBackground: iconBackground
        )
    }

    private static func call(name: String = "read_file",
                             argumentsJSON: String = "{\"path\":\"a.swift\"}") -> StepToolCall {
        StepToolCall(id: baselineCallID, createdAt: baselineCreatedAt,
                     name: name, argumentsJSON: argumentsJSON)
    }

    /// Factory with overridable knobs. Defaults form the canonical baseline;
    /// each test overrides exactly ONE knob.
    private static func makeCard(
        call: StepToolCall? = nil,
        role: Role = .softwareEngineer,
        roleDefinition: TeamRoleDefinition? = nil,
        showHeader: Bool = true,
        teamRoles: [TeamRoleDefinition]? = nil,
        onAvatarTap: (() -> Void)? = nil,
        roleLabelOverride: String? = nil,
        roleTeamSuffix: String? = nil
    ) -> ToolCallItemView {
        ToolCallItemView(
            call: call ?? Self.call(),
            role: role,
            roleDefinition: roleDefinition ?? roleDef(),
            showHeader: showHeader,
            teamRoles: teamRoles ?? [roleDef()],
            onAvatarTap: onAvatarTap,
            roleLabelOverride: roleLabelOverride,
            roleTeamSuffix: roleTeamSuffix
        )
    }

    // MARK: - Identical baselines compare equal

    func testEqual_whenAllPropsMatch() async {
        XCTAssertEqual(Self.makeCard(), Self.makeCard())
    }

    /// The closure is excluded from `==` by design (closures are never
    /// `Equatable`); it must not accidentally make two identical cards differ.
    func testEqual_whenOnlyOnAvatarTapDiffers() async {
        XCTAssertEqual(Self.makeCard(), Self.makeCard(onAvatarTap: {}))
    }

    // MARK: - Per-prop drift coverage

    func testNotEqual_whenCallDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(call: Self.call(name: "write_file")))
    }

    func testNotEqual_whenCallArgumentsDiffer() async {
        XCTAssertNotEqual(
            Self.makeCard(),
            Self.makeCard(call: Self.call(argumentsJSON: "{\"path\":\"b.swift\"}")))
    }

    func testNotEqual_whenRoleDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(role: .codeReviewer))
    }

    func testNotEqual_whenShowHeaderDiffers() async {
        XCTAssertNotEqual(Self.makeCard(), Self.makeCard(showHeader: false))
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

    func testNotEqual_whenTeamRolesCountDiffers() async {
        XCTAssertNotEqual(
            Self.makeCard(teamRoles: [Self.roleDef()]),
            Self.makeCard(teamRoles: [Self.roleDef(), Self.roleDef(id: "pm")]))
    }

    // MARK: - Render granularity: `roleDefinition`
    //
    // Each of these renames or recolours a role WITHOUT changing its id — the
    // Team-editor gesture. The card's body reads the changed field, so `==`
    // must report a difference or `.equatable()` freezes the old pixels.

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
            "the avatar renders roleDefinition?.icon — an icon change must break ==")
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
            "iconColor is a presentation field — the projection covers the whole set, "
                + "so a card that starts reading it cannot reintroduce the staleness")
    }

    // MARK: - Render granularity: `teamRoles`
    //
    // `teamRoles` exists solely to resolve names (`roleName(for:)`), which reads
    // `.name` and falls back through `.systemRoleID`. An id-only comparison of
    // the roster leaves a resolved name stale after a rename elsewhere in the team.

    func testNotEqual_whenATeamRoleIsRenamed() async {
        XCTAssertNotEqual(
            Self.makeCard(teamRoles: [Self.roleDef(id: "pm", name: "Product Manager")]),
            Self.makeCard(teamRoles: [Self.roleDef(id: "pm", name: "Program Manager")]),
            "teamRoles.roleName(for:) reads .name — a roster rename must break ==")
    }

    func testNotEqual_whenATeamRoleSystemRoleIDChanges() async {
        XCTAssertNotEqual(
            Self.makeCard(teamRoles: [Self.roleDef(id: "x", systemRoleID: nil)]),
            Self.makeCard(teamRoles: [Self.roleDef(id: "x", systemRoleID: "productManager")]),
            "roleName(for:) falls back to systemRoleID — it is part of the resolution")
    }
}
