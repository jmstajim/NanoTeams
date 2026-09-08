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
    // 1.9.4 — the Autovisor manager prompt gained one bullet: `roles_awaiting_acceptance: true`
    // on a task still reporting `"running"` means a role FINISHED and the whole pipeline is
    // parked on the Supervisor's decision, so the pass must reach for `manage_role accept`
    // instead of spending a wake on a task it reads as busy. One bundled surface moved: the
    // `autovisor` role prompt, the same one 1.9.3 moved.
    //
    // Uniqueness derived, not assumed — and derived without the revert 1.9.3 paid for, because
    // three commands answer it. **Anchor the range on the SHIP commit `dd22fa89`, not on the
    // bump `c735d4eb`**: they are 33 commits apart, and picking the bump is what made the D-29
    // record in DEBTS.md claim an untouched file that had moved by 151 lines.
    //   git diff --name-only dd22fa89..HEAD -- NanoTeams/Domain/SystemTemplates*
    //     → exactly one file, `SystemTemplates+RolePrompts.swift`, one added line.
    //   git diff dd22fa89..HEAD -- NanoTeams/Services/Tools/ | grep 'static let schema'
    //     → empty. Tool definitions feed the fingerprint through `ToolHandlerRegistry
    //       .allSchemas`; only `BashHandlers.handle` changed, never a `schema`.
    //   git diff --stat 1002010f..HEAD -- NanoTeams/Domain/ NanoTeams/Services/Team/
    //     → EMPTY, so nothing could have moved the value after the bump recorded it.
    //
    // Like 1.9.2 and 1.9.3, this bump DOES deliver: a role prompt reaches an existing folder
    // only through the version-gated reconcile.
    //
    // 1.9.5 — bumped WITHOUT moving this value: the first bump of the 1.9.x line that
    // delivers no bundled content at all. The 1.9.4 note above is kept, not rewritten,
    // because it describes where the STANDING value came from and is still true; a
    // mismatch between `project.pbxproj` (1.9.5) and that heading is expected here rather
    // than drift. `fe76a2df` fixed the opposite failure — a note describing an OLDER value
    // than the constant carried — so the rule is "the note tracks the constant", not "the
    // note tracks the version".
    //
    // Anchored on the BUMP that recorded this value. Re-recorded 2026-09-06 for 1.9.6,
    // which ships four bundled edits at once — attachment-source wording in the coding
    // fragment and in the Autovisor prompt, the code-reviewer emphasis, and the two
    // Autovisor verb tables re-shaped so they stop rendering as argument lists. (The release RANGE anchors on the ship commit `55f5b418` instead — rule
    // #155 answers "what shipped since last release", a different question from "what has
    // moved since this constant was written", and using one anchor for both is the error
    // that rule exists to prevent.)
    //   git diff --stat 1002010f..HEAD -- NanoTeams/Domain/SystemTemplates+PromptLibrary.swift \
    //     NanoTeams/Domain/SystemTemplates+RolePrompts.swift NanoTeams/Domain/TeamTemplateFactory.swift
    //     → 3 files, +8/-6, EVERY changed line is comment text; no prompt body moved.
    //   git diff 1002010f..HEAD -- NanoTeams/Domain/ToolDefinitionRecord.swift → empty.
    //   git diff 1002010f..HEAD -- NanoTeams/Services/Tools/ | grep -c 'static let schema' → 0.
    //
    // 1.9.7 — re-recorded 2026-09-06 (same day as 1.9.6): one bump for the second playbook
    // wave's bundled batch. Four tool descriptions lose workflow narrative
    // (`screen_capture`'s Spotlight recipe, `ui_type`'s address-bar recipe, `ui_click`'s
    // error-recovery and stale-coordinates sentences, `bash_output` restating its own
    // `action` enum); three bare prohibitions in the templates become the action to take
    // (`## Constraints` "Avoid human-only…", the two attachment fragments, "Never send
    // What next?"); the Quest Party and Discussion Club `## Final reminder` bodies gain the
    // end condition every other producing template already carries. Verified by the
    // `ToolSchemaTextPinTests.descriptionWordBudget` census taken from the same tree.
    //
    // 1.9.8 — re-recorded 2026-09-06 (third bump that day): the third playbook wave's
    // bundled batch. New content: `meetingGuidance` on nine roles (folded here as a tenth
    // field) and the `{stepEnding}` chip replacing four literal / if-clause Final-reminder
    // endings; `search.mode` exposed; `conclude_meeting`'s text now describes a real tool.
    // Removed content: 17 property descriptions that restated their key (pinned by
    // `ToolSchemaTextPinTests.testNoPropertyDescriptionMerelyRestatesItsKey`), the
    // Discussion Club's duplicated `## Conversation style`, the PM's "leave technical
    // design to Tech Lead", `create_artifact`'s plumbing sentence, `edit_file`'s
    // byte-for-byte demand, `search`'s omit-query listing clause. Reworded: TPM
    // checklist names the artifacts that exist, Quest Master wrap-up, Coding Agent 3a
    // (`bash` verifies), Autovisor `manage_role request_changes` and `## Supervisor`,
    // one roster wording for the three teammate-by-name arguments, `Your position:` in
    // both chat templates, attachment fragments "note the path and continue".
    // Census from the red run of this test on the same tree: ad6c4b67d375d0ca.
    //
    // 1.9.10 — re-recorded 2026-09-07 (the fourth playbook wave, the surfaces the first-prompt
    // audit declares out of scope). New content: a MEETING body for the ten roles that had
    // none (`softwareEngineer`, `uxResearcher`, `uxDesigner`, `loreMaster`, `npcCreator`,
    // `encounterArchitect`, the four Discussion Club observers) and `meetingStance` as the
    // fallback for a custom role; the `rulesArbiter` prompt's lead-in ("Check every document
    // for:"). Tool text: `control_task`'s verb table and `set_work_folder_context` no longer
    // restate their parameters' lines (the contracts moved onto `arg` / `content`),
    // `create_managed_task`'s "put everything into `brief`" moved onto `brief`. Bundle
    // 1.9.10 also carries the first `RuntimePromptFingerprint` — the composed texts this pin
    // never covered. Census from the red run of this test on the same tree: 5882e0ac100e1def.
    //
    // 1.9.11 — bumped WITHOUT moving this value (as 1.9.5 was): the release carries the live
    // measurements the 1.9.10 wave still owed (judges before/after, a vote meeting, Discussion
    // Club N=3, the one-shot trainer), a lint/periphery pass and the trainer itself — no bundled
    // content. Anchored on the 1.9.10 wave commit `746b904e`, where this value was recorded:
    //   git diff --stat 746b904e..HEAD -- NanoTeams/Domain/SystemTemplates+PromptLibrary.swift \
    //     NanoTeams/Domain/SystemTemplates+RolePrompts.swift NanoTeams/Domain/SystemTemplates+RoleTemplates.swift \
    //     NanoTeams/Domain/TeamTemplateFactory.swift NanoTeams/Domain/ToolDefinitionRecord.swift \
    //     NanoTeams/Services/Tools/ → empty.
    //   git diff --stat 746b904e..HEAD -- NanoTeams/ → HarmonySentinelNormalizer.swift 1/1, an indent.
    //
    // 1.9.12 — bumped WITHOUT moving this value again. The wave is context compaction and
    // tool-call parsing: binary behaviour, no bundled content at all. Same anchor `746b904e`,
    // because the anchor belongs to the value, not to the release (#167):
    //   git diff --stat 746b904e -- <the six folded surfaces above>
    //     → ToolRegistry.swift +7, ToolRuntime.swift +5/−1, and neither folds:
    //       `defaultAliases` is not read by `compute`, and `errorDescription` is a RUNTIME
    //       text — it carries a `RuntimePromptRegistry` row instead.
    //   git diff 746b904e -- NanoTeams/Services/Tools/ | grep -c 'static let schema' → 0
    // So the reconcile this bump triggers rewrites nothing in an existing work folder; what
    // 1.9.12 delivers travels in the binary, and the watermark advance is the whole effect.
    private static let expectedFingerprint = "5882e0ac100e1def"

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
            "conversationMechanics", "globalContext", "roleSkills", "toolCalling",
            // No chip-or-append fallback, on purpose: a custom team's stored template
            // already carries its own literal `## Final reminder` sentence.
            "stepEnding",
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
