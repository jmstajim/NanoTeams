import XCTest
@testable import NanoTeams

/// Tripwires for bundled content that only reaches existing work folders on an
/// app-version bump.
///
/// The reconcile gate is `MARKETING_VERSION`, not a content hash — a deliberate
/// choice, so a user's edits to a system role's prompt survive until the next
/// upgrade instead of being reverted every time a bundled string moves.
///
/// The failure mode that buys is silent: edit a bundled prompt, ship it, and it
/// reaches NO existing folder, with nothing anywhere saying so. These pins turn
/// that into a red test.
final class BundledContentFingerprintPinTests: XCTestCase {

    /// Bump this together with `MARKETING_VERSION` whenever bundled prompts,
    /// role toolsets, team settings or prompt templates change.
    ///
    /// To update: run this test, copy the "got" value from the failure message,
    /// paste it here, and bump `MARKETING_VERSION` in `project.pbxproj` (BOTH
    /// app-target entries — the `1.0` pair belongs to the test target).
    private static let expectedFingerprint = "a4df3893f14fe915"

    func testBundledContent_hasNotChangedWithoutAVersionBump() {
        let actual = BundledContentFingerprint.current
        XCTAssertEqual(
            actual, Self.expectedFingerprint,
            """
            Bundled content changed.

            The reconcile gate is MARKETING_VERSION, not content — so this change \
            reaches NO existing work folder until that version is bumped.

            1. Bump MARKETING_VERSION in NanoTeams.xcodeproj/project.pbxproj \
            (both app-target entries).
            2. Set `expectedFingerprint` in this test to: \(actual)
            """
        )
    }

    /// The fingerprint must not depend on dictionary iteration order, or it
    /// would flap between launches and train everyone to ignore it.
    func testFingerprint_isStableWithinAProcess() {
        XCTAssertEqual(BundledContentFingerprint.current, BundledContentFingerprint.current)
    }

    // MARK: - Registry pins

    /// Adding a `{chip}` to the bundled templates is a decision, not a detail:
    /// every team created from the New Team picker is CUSTOM
    /// (`Team.duplicate` clears `templateID`), so reconcile never reaches it and
    /// the chip only lands via `TemplateResolver.resolveSystemPrompt`'s
    /// chip-or-append fallback. Two chips have one today; a third added without
    /// one would silently never reach those teams.
    func testSystemPromptPlaceholders_areTheKnownSet() {
        let keys = Set(SystemTemplates.systemPromptPlaceholders.map(\.key))
        let known: Set<String> = [
            "roleName", "teamName", "teamDescription", "teamRoles",
            "stepInfo", "positionContext", "workFolderContext", "roleGuidance",
            "toolList", "expectedArtifacts", "artifactInstructions",
            "conversationMechanics", "globalContext", "roleSkills", "toolCalling"
        ]
        XCTAssertEqual(
            keys, known,
            """
            The system-prompt chip catalog changed.

            If you ADDED a chip: decide whether it needs a chip-or-append \
            fallback in TemplateResolver.resolveSystemPrompt. Without one it \
            never reaches CUSTOM teams (every "New Team" is custom), forever.

            Then update `known` here.
            """
        )
    }

    /// A stored `templateID` with no bundled counterpart silently stops
    /// receiving updates — steps 1/3/4 of the reconcile all skip it.
    func testTemplateConfigKeys_coverEveryShippedTemplate() {
        let shipped = Set(Team.defaultTeams.compactMap(\.templateID))
        let configured = Set(SystemTemplates.templateConfigs.keys)
        XCTAssertTrue(
            shipped.isSubset(of: configured),
            "templates with no prompt config: \(shipped.subtracting(configured).sorted())"
        )
    }
}
