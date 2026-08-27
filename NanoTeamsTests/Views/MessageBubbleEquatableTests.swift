import SwiftUI
import XCTest

@testable import NanoTeams

/// Drift-guard for `MessageBubbleView.==`. Each prop covered must
/// participate in equality — otherwise `.equatable()` would silently drop
/// updates to that prop. If you add a new prop to `MessageBubbleView` and
/// this suite still passes, you forgot to add it to `==`.
///
/// Pattern: build two views via a factory, override exactly one prop in
/// the second, assert `==` returns false. Plus one test that two
/// fully-equal baselines compare equal, and one that closures-only diff
/// is ignored.
@MainActor
final class MessageBubbleEquatableTests: XCTestCase {

    // MARK: - Fixtures

    private static let messageID = UUID()
    private static let baselineCreatedAt = Date(timeIntervalSince1970: 1_000)

    private static func defaultMessage() -> LLMMessage {
        LLMMessage(
            id: messageID,
            createdAt: baselineCreatedAt,
            role: .assistant,
            content: "hello"
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

    /// Factory with overridable knobs. Defaults form the canonical
    /// baseline; each test overrides exactly ONE knob.
    private static func makeBubble(
        message: LLMMessage? = nil,
        role: Role = .softwareEngineer,
        roleDefinition: TeamRoleDefinition? = nil,
        content: String = "hello",
        thinking: String? = nil,
        processingStatus: PromptProcessingStatus? = nil,
        hasStreamActivity: Bool = false,
        isStreamingToolCall: Bool = false,
        isStreaming: Bool = false,
        isImplicitStreamTarget: Bool = false,
        showHeader: Bool = true,
        onAvatarTap: (() -> Void)? = nil,
        roleLabelOverride: String? = nil,
        roleTeamSuffix: String? = nil,
        attachmentPaths: [String] = [],
        clippedTexts: [String] = [],
        workFolderURL: URL? = nil
    ) -> MessageBubbleView {
        MessageBubbleView(
            message: message ?? defaultMessage(),
            role: role,
            roleDefinition: roleDefinition,
            content: content,
            thinking: thinking,
            processingStatus: processingStatus,
            hasStreamActivity: hasStreamActivity,
            isStreamingToolCall: isStreamingToolCall,
            isStreaming: isStreaming,
            isImplicitStreamTarget: isImplicitStreamTarget,
            showHeader: showHeader,
            onAvatarTap: onAvatarTap,
            roleLabelOverride: roleLabelOverride,
            roleTeamSuffix: roleTeamSuffix,
            attachmentPaths: attachmentPaths,
            clippedTexts: clippedTexts,
            workFolderURL: workFolderURL
        )
    }

    // MARK: - Identical baselines compare equal

    func testEqual_whenAllPropsMatch() async {
        XCTAssertEqual(Self.makeBubble(), Self.makeBubble())
    }

    // MARK: - Per-prop drift coverage

    func testNotEqual_whenMessageDiffers() async {
        let a = Self.makeBubble()
        let b = Self.makeBubble(
            message: LLMMessage(
                id: Self.messageID,
                createdAt: Self.baselineCreatedAt,
                role: .assistant,
                content: "different"
            )
        )
        XCTAssertNotEqual(a, b, "Mutating message.content must break equality.")
    }

    func testNotEqual_whenRoleDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(role: .productManager))
    }

    func testNotEqual_whenRoleDefinitionIDDiffers() async {
        XCTAssertNotEqual(
            Self.makeBubble(roleDefinition: Self.roleDef(id: "swe-a")),
            Self.makeBubble(roleDefinition: Self.roleDef(id: "swe-b"))
        )
    }

    func testNotEqual_whenContentDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(content: "different"))
    }

    func testNotEqual_whenThinkingDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(thinking: "reasoning"))
    }

    func testNotEqual_whenProcessingProgressDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(processingStatus: .fraction(0.5)))
    }

    func testNotEqual_whenHasStreamActivityDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(hasStreamActivity: true))
    }

    func testNotEqual_whenIsStreamingToolCallDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(isStreamingToolCall: true),
                          "Tool-call flag flip must break == — otherwise .equatable() freezes the Thinking loader and drops the Generating fallback mid-stream.")
    }

    func testNotEqual_whenIsStreamingDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(isStreaming: true))
    }

    func testNotEqual_whenIsImplicitStreamTargetDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(isImplicitStreamTarget: true))
    }

    func testNotEqual_whenShowHeaderDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(showHeader: false))
    }

    func testNotEqual_whenRoleLabelOverrideDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(roleLabelOverride: "Override"))
    }

    func testNotEqual_whenRoleTeamSuffixDiffers() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(roleTeamSuffix: "from Other Team"))
    }

    func testNotEqual_whenAttachmentPathsDiffer() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(attachmentPaths: ["file.txt"]))
    }

    func testNotEqual_whenClippedTextsDiffer() async {
        XCTAssertNotEqual(Self.makeBubble(), Self.makeBubble(clippedTexts: ["clip"]))
    }

    func testNotEqual_whenWorkFolderURLDiffers() async {
        XCTAssertNotEqual(
            Self.makeBubble(),
            Self.makeBubble(workFolderURL: URL(fileURLWithPath: "/tmp/x"))
        )
    }

    // MARK: - Closure exclusion

    /// `onAvatarTap` is intentionally NOT in `==` — closures aren't
    /// Equatable, and the closure captures only props that ARE in `==`,
    /// so the cached capture stays correct. This test pins that decision:
    /// two views differing ONLY in `onAvatarTap` compare equal.
    func testEqual_whenOnlyOnAvatarTapDiffers() async {
        let a = Self.makeBubble(onAvatarTap: { })
        let b = Self.makeBubble(onAvatarTap: { })
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
            Self.makeBubble(roleDefinition: Self.roleDef(name: "Alpha")),
            Self.makeBubble(roleDefinition: Self.roleDef(name: "Beta")),
            "the view renders roleDefinition?.name — a rename must break ==")
    }

    func testNotEqual_whenRoleDefinitionIconDiffers() async {
        XCTAssertNotEqual(
            Self.makeBubble(roleDefinition: Self.roleDef(icon: "hammer")),
            Self.makeBubble(roleDefinition: Self.roleDef(icon: "wrench")),
            "the avatar renders roleDefinition?.icon")
    }

    func testNotEqual_whenRoleDefinitionIconBackgroundDiffers() async {
        XCTAssertNotEqual(
            Self.makeBubble(roleDefinition: Self.roleDef(iconBackground: "#112233")),
            Self.makeBubble(roleDefinition: Self.roleDef(iconBackground: "#445566")),
            "resolvedTintColor and resolvedIconBackground both read iconBackground")
    }

    func testNotEqual_whenRoleDefinitionIconColorDiffers() async {
        XCTAssertNotEqual(
            Self.makeBubble(roleDefinition: Self.roleDef(iconColor: "#FFFFFF")),
            Self.makeBubble(roleDefinition: Self.roleDef(iconColor: "#000000")),
            "iconColor is a presentation field — the projection covers the whole set")
    }
}
