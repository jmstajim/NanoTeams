import XCTest

@testable import NanoTeams

/// Wave 11 — the wire-preview fallbacks for inputs the Settings sheets can actually hand over.
///
/// `PromptBuilder+WirePreview` exists for exactly one reason: the preview must be BYTE-IDENTICAL to
/// what the wire carries, so an author auditing a prompt is auditing the real thing. Its `??` arms
/// are where that promise is kept for degenerate inputs, and every one of them had gone unrun
/// because the suite around it drives fully-populated bundled teams.
///
/// The two degenerate inputs are both reachable from the UI, not hypothetical:
///
///   - `team: nil` — the role editor previews a role while its team is still being assembled, and
///     `WirePreviewInputs.team` is declared `Team?` precisely to admit that. The three per-kind
///     templates then have to come from `SystemTemplates`, or the preview renders an EMPTY template
///     and the author reads "this role sends nothing".
///   - a role that is not a system role and is not in the team — every role created by the "New
///     Role" button, until it is added to the graph. `Role.fromDefinition` maps it to
///     `.custom(id: name)`, whose `baseID` has no `SystemTemplates.roles` entry.
///
/// The step-execution kind and the two collaboration kinds resolve role guidance by DIFFERENT
/// rules — step trims and falls back, collaboration falls back only when the role is absent from
/// the team — and the runtime builders they mirror differ the same way. Both fallbacks landing on
/// `""` is what makes the two paths agree at the degenerate end, so both are asserted here.
final class WirePreviewFallbackCoverageTests: XCTestCase {

    private func customRole(prompt: String) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "custom_role_id",
            name: "Growth Analyst",
            prompt: prompt,
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
    }

    private func inputs(role: TeamRoleDefinition, team: Team?) -> PromptBuilder.WirePreviewInputs {
        PromptBuilder.WirePreviewInputs(
            role: role,
            team: team,
            allTeams: [],
            workFolder: nil,
            workFolderState: .defaultStorage,
            selectedScheme: nil,
            isVisionConfigured: false,
            isComputerUseEnabled: false,
            globalContext: "",
            isCoordinator: false,
            agentInstructions: nil
        )
    }

    /// With no team, each kind falls back to its `SystemTemplates` generic. Asserted as an identity
    /// against the generic constants rather than "is non-empty", because a fallback that returned
    /// the WRONG kind's template would also be non-empty — and would show a meeting author the
    /// consultation prompt.
    ///
    /// RED: swap the consultation and meeting fallbacks (`?? SystemTemplates.genericMeetingTemplate`
    /// on the `.consultation` arm and vice versa) → both identity assertions fail while a
    /// non-emptiness assertion would still pass.
    func testTemplateAndDefs_withNoTeam_fallsBackToEachKindsGenericTemplate() {
        let step = PromptBuilder.wirePreviewTemplateAndDefs(kind: .stepExecution, team: nil)
        let consultation = PromptBuilder.wirePreviewTemplateAndDefs(kind: .consultation, team: nil)
        let meeting = PromptBuilder.wirePreviewTemplateAndDefs(kind: .meeting, team: nil)

        XCTAssertEqual(step.template, SystemTemplates.genericTemplate)
        XCTAssertEqual(consultation.template, SystemTemplates.genericConsultationTemplate)
        XCTAssertEqual(meeting.template, SystemTemplates.genericMeetingTemplate)

        // The placeholder definitions are per-kind too; a fallback that only fixed the template
        // would leave the chip list describing another kind's slots.
        XCTAssertFalse(step.definitions.isEmpty)
        XCTAssertNotEqual(
            consultation.definitions.map(\.key).sorted(),
            step.definitions.map(\.key).sorted(),
            "consultation and step execution do not share a placeholder set")
    }

    /// A populated team still wins. Paired with the test above so "the fallback fired" is
    /// distinguishable from "the fallback always fires" — a mutation that ignored `team` entirely
    /// would pass the previous test alone.
    ///
    /// RED: change `team?.consultationPromptTemplate ?? …` to just the generic constant → the
    /// inequality assertion fails.
    func testTemplateAndDefs_withATeam_prefersTheTeamsOwnTemplate() {
        var team = TeamTemplateFactory.faang()
        team.consultationPromptTemplate = "TEAM-OWNED CONSULTATION TEMPLATE"

        let resolved = PromptBuilder.wirePreviewTemplateAndDefs(kind: .consultation, team: team)

        XCTAssertEqual(resolved.template, "TEAM-OWNED CONSULTATION TEMPLATE")
        XCTAssertNotEqual(resolved.template, SystemTemplates.genericConsultationTemplate)
    }

    /// Consultation and meeting values for an unknown role with no team: `teamDescription` and
    /// `roleGuidance` both resolve to the empty string rather than to a missing key.
    ///
    /// Resolving to `""` and not to "absent" is the load-bearing half: `TemplateResolver` leaves an
    /// UNKNOWN placeholder in place as literal `{teamDescription}` text, so a missing key would
    /// ship a curly-braced token to the model — the exact failure the resolver's single-pass rule
    /// exists to prevent.
    ///
    /// RED: delete the `"teamDescription"` entry from `wirePreviewConsultationValues` → the
    /// key-present assertion fails (and the rendered preview would carry a literal chip).
    func testCollaborationValues_unknownRoleAndNoTeam_resolveToEmptyStringsNotMissingKeys() {
        let role = customRole(prompt: "Ignored — the role is not in any team.")

        for kind in [WirePromptKind.consultation, .meeting] {
            let values = PromptBuilder.wirePreviewValues(kind: kind, inputs: inputs(role: role, team: nil))

            XCTAssertEqual(values["teamDescription"], "", "kind \(kind)")
            XCTAssertEqual(values["roleGuidance"], "",
                           "an unknown role has no SystemTemplates guidance to fall back to; kind \(kind)")
            XCTAssertNotNil(values["roleSkills"],
                            "skills are step-execution-only but must still be MAPPED, or a hand-typed "
                            + "chip ships as a literal token; kind \(kind)")
        }
    }

    /// The collaboration rule is "fall back only when the role is ABSENT from the team" — so a role
    /// that IS in the team keeps its own prompt, empty or not. This is deliberately different from
    /// step execution's trim-and-fall-back, and the difference mirrors the two runtime builders.
    ///
    /// RED: change `wirePreviewCollaborationRoleGuidance` to trim-and-fall-back like the step
    /// version → the empty-prompt assertion fails.
    func testCollaborationRoleGuidance_roleInTeamWithEmptyPrompt_staysEmpty() {
        var team = TeamTemplateFactory.faang()
        let role = customRole(prompt: "")
        team.roles.append(role)

        let values = PromptBuilder.wirePreviewValues(kind: .consultation, inputs: inputs(role: role, team: team))

        XCTAssertEqual(values["roleGuidance"], "")
    }

    /// Step execution's own fallback, at the far end: a blank prompt on a role no `SystemTemplates`
    /// entry matches. Step execution trims and falls back — and when the fallback has nothing
    /// either, it must resolve to `""` rather than to nil.
    ///
    /// RED: change `SystemTemplates.roles[builtIn.baseID]?.prompt ?? ""` to `?? "{roleGuidance}"`
    /// in `wirePreviewStepRoleGuidance` → the assertion fails, and the preview would echo its own
    /// unresolved chip.
    func testStepRoleGuidance_blankPromptOnAnUnknownRole_resolvesToEmptyString() {
        let role = customRole(prompt: "   \n  ")

        let values = PromptBuilder.wirePreviewValues(
            kind: .stepExecution, inputs: inputs(role: role, team: nil))

        XCTAssertEqual(values["roleGuidance"], "",
                       "whitespace trims away and the unknown role has no canonical guidance")
    }

    /// The same step-execution path when the fallback DOES have something: a system role whose
    /// stored prompt was blanked keeps the canonical `SystemTemplates` guidance. Pinned beside the
    /// test above so "the fallback resolved to empty" cannot be confused with "the fallback is
    /// never consulted".
    ///
    /// RED: delete the `SystemTemplates.roles[builtIn.baseID]?.prompt` lookup (return `""` outright)
    /// → the non-empty assertion fails.
    func testStepRoleGuidance_blankPromptOnASystemRole_recoversTheCanonicalGuidance() throws {
        let faang = TeamTemplateFactory.faang()
        var engineer = try XCTUnwrap(faang.roles.first { $0.systemRoleID == Role.softwareEngineer.baseID })
        engineer.prompt = ""

        let values = PromptBuilder.wirePreviewValues(
            kind: .stepExecution, inputs: inputs(role: engineer, team: faang))

        XCTAssertFalse(try XCTUnwrap(values["roleGuidance"]).isEmpty,
                       "a system role must recover its canonical guidance when the stored prompt is blank")
    }
}
