import SwiftUI
import XCTest

@testable import NanoTeams

/// Drift-guard for `MeetingMessageItemView.==`. Mirrors
/// `MessageBubbleEquatableTests` — each prop the body reads must
/// participate in equality, otherwise `.equatable()` silently drops
/// updates. The pre-fix `==` only checked `toolSummaries?.count`, so
/// an in-place flip of `isError` (red ↔ green) or a tool rename
/// went undetected — that's what `testNotEqual_whenToolSummary…`
/// cases pin.
@MainActor
final class MeetingMessageItemEquatableTests: XCTestCase {

    // MARK: - Fixtures

    private static let messageID = UUID()
    private static let baselineCreatedAt = Date(timeIntervalSince1970: 1_000)
    /// `nonisolated` because it is reached from a DEFAULT ARGUMENT below
    /// (`id: UUID = toolSummaryID`). A default-argument expression inherits the enclosing
    /// isolation only under the Swift 6 language mode (SE-0411); the mirror's CI still
    /// compiles this target with `-swift-version 5`, where it is evaluated nonisolated.
    /// Safe: the value is a `Sendable` constant. Pinned by `DefaultArgumentIsolationPinTests`.
    nonisolated private static let toolSummaryID = UUID()
    private static let toolSummaryCreatedAt = Date(timeIntervalSince1970: 1_100)

    private static func toolSummary(
        id: UUID = toolSummaryID,
        toolName: String = "read_file",
        arguments: String = "{\"path\":\"x.swift\"}",
        result: String = "ok",
        isError: Bool = false
    ) -> MeetingToolSummary {
        MeetingToolSummary(
            id: id,
            createdAt: toolSummaryCreatedAt,
            toolName: toolName,
            arguments: arguments,
            result: result,
            isError: isError
        )
    }

    private static func defaultMessage(
        content: String = "hello",
        thinking: String? = nil,
        role: Role = .softwareEngineer,
        messageType: TeamMessageType = .discussion,
        toolSummaries: [MeetingToolSummary]? = nil
    ) -> TeamMessage {
        TeamMessage(
            id: messageID,
            createdAt: baselineCreatedAt,
            role: role,
            content: content,
            messageType: messageType,
            thinking: thinking,
            toolSummaries: toolSummaries
        )
    }

    private static func roleDef(
        id: String = "swe",
        name: String = "Software Engineer",
        icon: String = "chevron.left.forwardslash.chevron.right",
        iconColor: String = "#FFFFFF",
        iconBackground: String = RoleColorDefaults.defaultHex
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, icon: icon,
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconColor: iconColor, iconBackground: iconBackground
        )
    }

    private static func makeView(
        message: TeamMessage? = nil,
        roleDefinition: TeamRoleDefinition? = nil,
        showHeader: Bool = true,
        onAvatarTap: (() -> Void)? = nil,
        roleLabelOverride: String? = nil,
        roleTeamSuffix: String? = nil
    ) -> MeetingMessageItemView {
        MeetingMessageItemView(
            message: message ?? defaultMessage(),
            roleDefinition: roleDefinition,
            showHeader: showHeader,
            onAvatarTap: onAvatarTap,
            roleLabelOverride: roleLabelOverride,
            roleTeamSuffix: roleTeamSuffix
        )
    }

    // MARK: - Identical baselines compare equal

    func testEqual_whenAllPropsMatch() async {
        XCTAssertEqual(Self.makeView(), Self.makeView())
    }

    func testEqual_whenToolSummariesArrayContentMatches() async {
        let summaries = [Self.toolSummary()]
        let a = Self.makeView(message: Self.defaultMessage(toolSummaries: summaries))
        let b = Self.makeView(message: Self.defaultMessage(toolSummaries: summaries))
        XCTAssertEqual(a, b)
    }

    // MARK: - Per-prop drift coverage

    func testNotEqual_whenMessageContentDiffers() async {
        let a = Self.makeView()
        let b = Self.makeView(message: Self.defaultMessage(content: "different"))
        XCTAssertNotEqual(a, b)
    }

    func testNotEqual_whenMessageThinkingDiffers() async {
        let a = Self.makeView(message: Self.defaultMessage(thinking: nil))
        let b = Self.makeView(message: Self.defaultMessage(thinking: "reasoning"))
        XCTAssertNotEqual(a, b)
    }

    func testNotEqual_whenMessageRoleDiffers() async {
        let a = Self.makeView(message: Self.defaultMessage(role: .softwareEngineer))
        let b = Self.makeView(message: Self.defaultMessage(role: .productManager))
        XCTAssertNotEqual(a, b)
    }

    func testNotEqual_whenMessageTypeDiffers() async {
        let a = Self.makeView(message: Self.defaultMessage(messageType: .discussion))
        let b = Self.makeView(message: Self.defaultMessage(messageType: .objection))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Tool-summary drift (the actual bug being fixed)

    /// Pre-fix: == compared `toolSummaries?.count` only. Same count → equal
    /// even when isError flipped, so the green→red badge stuck on screen.
    /// This is the regression test for that.
    func testNotEqual_whenToolSummaryIsErrorFlips() async {
        let okSummary = [Self.toolSummary(isError: false)]
        let errSummary = [Self.toolSummary(isError: true)]
        let a = Self.makeView(message: Self.defaultMessage(toolSummaries: okSummary))
        let b = Self.makeView(message: Self.defaultMessage(toolSummaries: errSummary))
        XCTAssertNotEqual(a, b, "isError flip with same count must invalidate equality.")
    }

    func testNotEqual_whenToolSummaryToolNameChanges() async {
        let read = [Self.toolSummary(toolName: "read_file")]
        let search = [Self.toolSummary(toolName: "search")]
        let a = Self.makeView(message: Self.defaultMessage(toolSummaries: read))
        let b = Self.makeView(message: Self.defaultMessage(toolSummaries: search))
        XCTAssertNotEqual(a, b)
    }

    func testNotEqual_whenToolSummaryResultChanges() async {
        let r1 = [Self.toolSummary(result: "ok")]
        let r2 = [Self.toolSummary(result: "different")]
        let a = Self.makeView(message: Self.defaultMessage(toolSummaries: r1))
        let b = Self.makeView(message: Self.defaultMessage(toolSummaries: r2))
        XCTAssertNotEqual(a, b)
    }

    /// Pre-fix already detected count diffs via the `count` compare —
    /// this test pins that the post-fix array compare retains that behaviour.
    func testNotEqual_whenToolSummaryCountDiffers() async {
        let one = [Self.toolSummary()]
        let two = [Self.toolSummary(), Self.toolSummary(id: UUID(), toolName: "search")]
        let a = Self.makeView(message: Self.defaultMessage(toolSummaries: one))
        let b = Self.makeView(message: Self.defaultMessage(toolSummaries: two))
        XCTAssertNotEqual(a, b)
    }

    func testNotEqual_whenToolSummariesNilVsEmpty() async {
        // nil vs [] is observably the same in the UI (no row rendered),
        // so they should compare equal. The fix MUST normalize this.
        let a = Self.makeView(message: Self.defaultMessage(toolSummaries: nil))
        let b = Self.makeView(message: Self.defaultMessage(toolSummaries: []))
        XCTAssertEqual(a, b, "nil and empty-array tool summaries render the same row (none) — must compare equal.")
    }

    // MARK: - Other props

    func testNotEqual_whenRoleDefinitionIDDiffers() async {
        XCTAssertNotEqual(
            Self.makeView(roleDefinition: Self.roleDef(id: "swe-a")),
            Self.makeView(roleDefinition: Self.roleDef(id: "swe-b"))
        )
    }

    func testNotEqual_whenShowHeaderDiffers() async {
        XCTAssertNotEqual(Self.makeView(showHeader: true), Self.makeView(showHeader: false))
    }

    func testNotEqual_whenRoleLabelOverrideDiffers() async {
        XCTAssertNotEqual(Self.makeView(), Self.makeView(roleLabelOverride: "Override"))
    }

    func testNotEqual_whenRoleTeamSuffixDiffers() async {
        XCTAssertNotEqual(Self.makeView(), Self.makeView(roleTeamSuffix: "from Other Team"))
    }

    // MARK: - Closure exclusion

    func testEqual_whenOnlyOnAvatarTapDiffers() async {
        let a = Self.makeView(onAvatarTap: { })
        let b = Self.makeView(onAvatarTap: { })
        XCTAssertEqual(a, b, "onAvatarTap is intentionally excluded from ==.")
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
            Self.makeView(roleDefinition: Self.roleDef(name: "Alpha")),
            Self.makeView(roleDefinition: Self.roleDef(name: "Beta")),
            "the view renders roleDefinition?.name — a rename must break ==")
    }

    func testNotEqual_whenRoleDefinitionIconDiffers() async {
        XCTAssertNotEqual(
            Self.makeView(roleDefinition: Self.roleDef(icon: "hammer")),
            Self.makeView(roleDefinition: Self.roleDef(icon: "wrench")),
            "the avatar renders roleDefinition?.icon")
    }

    func testNotEqual_whenRoleDefinitionIconBackgroundDiffers() async {
        XCTAssertNotEqual(
            Self.makeView(roleDefinition: Self.roleDef(iconBackground: "#112233")),
            Self.makeView(roleDefinition: Self.roleDef(iconBackground: "#445566")),
            "resolvedTintColor and resolvedIconBackground both read iconBackground")
    }

    func testNotEqual_whenRoleDefinitionIconColorDiffers() async {
        XCTAssertNotEqual(
            Self.makeView(roleDefinition: Self.roleDef(iconColor: "#FFFFFF")),
            Self.makeView(roleDefinition: Self.roleDef(iconColor: "#000000")),
            "iconColor is a presentation field — the projection covers the whole set")
    }
}
