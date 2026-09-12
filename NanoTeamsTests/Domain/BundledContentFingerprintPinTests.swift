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
    // 1.9.13 — the value MOVES, for the first time since 1.9.10: the Ultra Team ships as the
    // ninth bundled template, with seven new system roles, seven new artifacts and a
    // `templateConfigs` row. All of that is folded content, so an existing work folder needs
    // this bump to receive the roles' prompts and toolsets — the team itself arrives without
    // one (`migrateIfNeeded` appends missing bundled templates unconditionally), but every
    // later edit to its prompts does not.
    // 1.9.14 — the value MOVES with the Ultra Team's first correction, found by auditing the
    // shipped pipeline against the playbook rather than by a failure: the Spec Critic's contract
    // is a table over the acceptance criteria and the Build Verifier settles the third of the
    // run's three success conditions, and NEITHER received the brief those criteria live in — it
    // reached both as a path in the handoff, on a read the model may skip. Two edges, one
    // rewritten verifier contract (the diff read before the notes, a verdict per criterion, and
    // changes no claim covers), one artifact description. All folded, so an existing work folder
    // needs this bump to receive any of it.
    // 1.9.15 — the value MOVED (`dda52773c3a51431` → `ada8e54b09f06a29`) and no note was
    // written; recorded here retroactively, because the convention is that the note tracks the
    // CONSTANT. What moved: `ask_supervisor_form`'s schema. Tool schemas fold through
    // `ToolHandlerRegistry.allSchemas`, so a new tool moves this value by existing.
    //
    // 1.9.16 — the value MOVES with the questionnaire's last bundled edit: the Ultra Team's
    // planner now holds `ask_supervisor_form` beside `ask_supervisor` (a role toolset — folded
    // via `role.toolIDs`), and its prompt stops asking for a numbered list inside one plain
    // call. Both reach an EXISTING work folder only through the version-gated reconcile, so
    // without this bump the tool ships in the binary and no folder's planner is ever granted
    // it — the feature would be live only in folders created after the upgrade.
    //   git diff --stat 0e9b1dce..HEAD -- <the six folded surfaces> → the three files of the
    //     tool's own wave (`SupervisorHandlers`, `SupervisorAskRouting`, `ToolRuntime`), none
    //     of which moves a folded field; `grep -c 'static let schema'` on that diff → 0.
    //   git diff HEAD --stat -- <the same six> → exactly the two files this bump is for.
    //
    // 1.9.17 — the value MOVES because the questionnaire stopped being one role's tool: every
    // bundled role that holds `ask_supervisor` now holds `ask_supervisor_form` beside it (ten
    // role templates plus four `TeamTemplateFactory` closures — folded via `role.toolIDs`),
    // and the shared choice fragment the three chat roles carry stops asking them to hand-roll
    // a numbered list when they hold the tool that IS the list (folded via `role.prompt`).
    // Nothing here reaches an existing work folder without the bump: the reconcile rewrites a
    // system role's `toolIDs` and `prompt` from the bundle, and its gate is the version.
    //   Проверка: `grep -c 'TN.askSupervisorForm' NanoTeams/Domain/SystemTemplates+RoleTemplates.swift
    //     NanoTeams/Domain/TeamTemplateFactory.swift` → 11 and 4; `grep -c 'TN.askSupervisor,'`
    //     on the same two counts the pairs, never a lone plain ask.
    // 1.9.18 — the largest move the register has recorded, because the Ultra Team stopped
    // being a FEATURE pipeline and became a general CHANGE pipeline. Three system roles were
    // renamed (`featurePlanner`/`featureEngineer`/`buildVerifier` →
    // `changePlanner`/`changeEngineer`/`changeVerifier`), three were added (`briefCritic`,
    // `feasibilityCritic`, `diffReviewer`), "Feature Brief" became "Change Brief" and three
    // artifacts joined it; every one of the ten roles gained `analyze_image` and both Xcode
    // runners; all ten prompts were rewritten around one shared `### Unverified` rule; and
    // the team carries its own `TeamLimits.ultra`.
    //
    // This is also the first bump whose reconcile REMOVES something: the three retired ids
    // live in `SystemTemplates.retiredSystemRoleIDs`, and step 4a deletes them from a stored
    // team before the additive pass runs. Without the version bump a folder keeps both
    // rosters — two planners, two writers on one tree — so the gate is doing more work here
    // than usual.
    //   Проверка: `grep -c 'changePlanner\|briefCritic\|feasibilityCritic\|diffReviewer'
    //     NanoTeams/Domain/SystemTemplates+RoleTemplates.swift` → non-zero; and
    //     `grep -rn 'featurePlanner' NanoTeams --include='*.swift'` → only the retired roster.
    // 1.9.19 — the value MOVES with the review of 1.9.18, the same day: the Spec Critic's
    // "Evidence outranks claims" stops penalising a MEASURED baseline (both architects hold the
    // runners now, so a paired tool call is evidence; inventing a result for code that does
    // not exist is still the defect); the Feasibility Critic's probe gets a placement rule
    // (beside an existing source of the target — a root-level file is in no synchronized
    // group and compiled by nothing) and one retry of the control before declaring everything
    // unverified; the verifier's prompt drops the MeditationApp incident narrative (it lives
    // in the Swift comment now); and the Implementation Notes / Verification Report
    // descriptions agree with the prompts they ride beside. RETRACTED IN PART 2026-09-12:
    // "all folded (`role.prompt`, artifact descriptions)" was half wrong — until 1.9.21 this
    // value folded artifact NAMES only, and reconcile step 4 skipped an artifact it already
    // had. So the prompt half of that 1.9.19 edit shipped and the DESCRIPTION half reached no
    // existing folder at all, at any version. Both are fixed in 1.9.21; the 1.9.19 prompt
    // changes stand as recorded.
    //   Проверка: `grep -c 'MeditationApp' NanoTeams/Domain/SystemTemplates+RolePrompts.swift`
    //     → the comment only (0 inside a prompt literal — `UltraTeamTests` pins it).
    // 1.9.20 — the value MOVES because the recency slot now names the questionnaire: the
    // advisory `{stepEnding}` sentence reads "Reply by calling `ask_supervisor` with your full
    // response in its `question` field. Several questions, or a choice with its options, go as
    // `ask_supervisor_form`." — one imperative, the "plain text outside tool calls is
    // invisible" rationale dropped (R1.2.3, R4.3.2) — and `choiceFragment` is gone from the
    // three chat roles that carried it mid-prompt (R4.3.2: one rule, one place — the tool's
    // description, the refusal's `next`, the nudge, the recency slot). Both folded (template
    // constant and `role.prompt`), so a folder already opened at 1.9.19 needs this bump.
    // Measured live (REC.10, N=2 after the A2 point) — RUN_HISTORY 2026-09-11j.
    //   Проверка: `grep -c choiceFragment NanoTeams/Domain/SystemTemplates+RolePrompts.swift` → 0.
    // 1.9.21 — the value MOVES because the Ultra Team stopped being a SWIFT pipeline. It was a
    // general CHANGE pipeline that only ran on a macOS project with an Xcode scheme: step 3.1 of
    // `resolveToolSchemasCore` strips both runners when no scheme is selected, and the floor
    // offered no other build channel, so on a SwiftPM package — or any repository that is not
    // Swift — nine roles were ordered to build with nothing to build with (playbook E7.7.6:
    // an unfulfillable directive, not disobedience). Three things moved together: `bash` +
    // `bash_output` joined `ultraToolFloor` (folded via `role.toolIDs`); the Feasibility Critic
    // retired, because its whole contract was a compiled `FeasibilityProbe.swift` inside an Xcode
    // target — so ten roles became nine, `Feasibility Report` left `SystemTemplates.artifacts`,
    // and three `requires` lists lost it (folded via the roster, the artifact set and
    // `role.dependencies`); and five prompts were rewritten to stop naming a document that no
    // longer exists and a runner the resolver may have taken away (folded via `role.prompt`).
    //
    // A fourth thing moved, found by the stack pin rather than by hand: an artifact DESCRIPTION
    // rides the wire beside the role's prompt, but this value folded artifact NAMES only and
    // reconcile step 4 skipped any artifact it already had — so a description edit reached no
    // existing folder at any version, while the prompt beside it did. Both halves are folded and
    // refreshed now (`RetiredSystemRoleReconcileTests.testStoredSystemArtifact_gets…`), which is
    // also why this value moved twice while 1.9.21 was being assembled.
    //
    // The second bump whose reconcile REMOVES something, and the more dangerous of the two: the
    // retired role held `write_file` + `delete_file`. Without the bump a stored folder keeps it
    // alive beside the engineer — two writers on one tree — while every pin over the FRESH
    // template stays green (`UltraTeamTests.testTheRetiredFeasibilityCriticIsActuallyRetired`).
    //   Проверка: `grep -rn 'feasibilityCritic' NanoTeams --include='*.swift'` → only the retired
    //     roster; `grep -c 'ultraToolFloor' NanoTeams/Domain/SystemTemplates+RoleTemplates.swift`
    //     → 11 (one declaration, nine call sites, one comment), and the declaration carries
    //     `TN.bash, TN.bashOutput`. And the nine prompts say nothing that only holds on one
    //     stack: `grep -icE 'swift|xcode|macos|compile|runner' ` over the Ultra prompt bodies
    //     → 0 (`UltraTeamTests.testNoUltraPromptNamesAStack` reads the same population).
    // 1.9.22 (2026-09-12) — the two tool parameters that carry a nested JSON DOCUMENT,
    // `ask_supervisor_form.form` and `create_team.team_config`, are declared `object` instead
    // of `string`, and the form's worked example became the WHOLE call rather than the form's
    // contents. Both handlers already accepted the object shape, dict-first; only the schema
    // said otherwise. No provider is sent a real JSON Schema — `NativeChatRequest` and
    // Ollama's `ChatRequest` have no `tools` field, every schema reaches the model as prose —
    // so the rendered `(type)` was the only thing telling the model whether to send a value or
    // a transcript of one, and `string` asked it to hand-escape 1500 characters of JSON inside
    // JSON. Field measure over three runs, 2026-09-12 (MeditationApp tasks 71 and 74,
    // `ornith-1.5:35b`): seven form emissions, six of them strings, two of those clean —
    // 0 of 3 runs parked on the first attempt, 2.33 calls per park. The single NATIVE emission
    // was syntactically flawless and was refused for a missing `form`, which is the other half
    // of this bump: the handler now reads a top-level `questions` array as the document, and a
    // `form` of the wrong type is reported as the wrong type rather than as missing.
    //   Проверка: `./run_ask_supervisor_form_trainer.sh` — `clean-on-first` and
    //     `calls-per-park` over N runs, the same numbers the classifier reads off any existing
    //     run's `tool_calls.jsonl`.
    // 1.9.23, 2026-09-12: the `ask_supervisor_form` description lost its assumed-answer
    // paragraph and the Ultra changePlanner its stop-condition clause, because the behaviour
    // both described is gone — an untouched question is no longer filled in from `options[0]`.
    // Both texts promised something the app stopped doing, which is the one kind of prompt
    // edit that cannot wait for a later bundle.
    // 1.9.24, 2026-09-12: the `ask_supervisor_form` description stopped claiming that the
    // first option is the recommended one, and teaches the spelling models already write
    // unprompted instead — a recommendation opens that option's `detail` with the word
    // Recommended, shown once in the worked example. `questionnaireRequiredReason` lost the
    // same claim. The clause is bundled, so the reconcile must reach existing work folders:
    // a role told "order them deliberately" by a stale template would be ordering for a
    // reader that no longer reads order.
    // 1.9.25, 2026-09-13 — bumped WITHOUT moving this value, as 1.9.5, 1.9.11 and 1.9.12 were.
    // The release is the first public one since 1.9.12, thirteen bundled bumps back, so the
    // watermark advance IS the effect here: every folder opened at any 1.9.1x receives the
    // whole accumulated reconcile on this open. What the wave itself ships travels in the
    // binary — the delegated exchange offering the parking PAIR (D-B14), the executor's
    // rewritten refusals (D-B10), the chair rule lifted into `Domain` (D-B12) — and none of it
    // is folded content.
    //   Проверка, перепрогнанная а не унаследованная: over the wave's own range,
    //     git diff --stat <range> -- NanoTeams/Domain/SystemTemplates+RolePrompts.swift \
    //       SystemTemplates+RoleTemplates.swift SystemTemplates+ArtifactTemplates.swift \
    //       SystemTemplates+PromptLibrary.swift TeamTemplateFactory.swift → EMPTY, and
    //     the `ask_supervisor_form` schema's `description` and `parameters` are byte-identical
    //     (`SupervisorHandlers.swift` lost 266 lines, all of them the decode ladder moving to
    //     `SupervisorFormPayload`, none of them schema text).
    private static let expectedFingerprint = "32337af25e41c6eb"

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
