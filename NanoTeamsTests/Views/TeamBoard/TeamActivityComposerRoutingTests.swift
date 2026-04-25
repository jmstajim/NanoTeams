import XCTest

@testable import NanoTeams

/// Tests for `TeamActivityComposer` pure routing helpers — the 4-branch
/// `resolveEffectiveRecipient` fallback chain, the asking-role exclusion in
/// `computeSelectableRoles`, and the Answer/Team/Role ordering in `computeChipOptions`.
///
/// Testing at the static-function level avoids mounting SwiftUI, which is slow and
/// brittle — see CLAUDE.md "pure composition" pattern in the design-system section.
@MainActor
final class TeamActivityComposerRoutingTests: XCTestCase {

    // MARK: - Role factories

    private func normalRole(id: String, name: String = "Role") -> TeamRoleDefinition {
        // Non-supervisor, non-observer: has at least one required artifact so
        // `completionType` falls into `.advisory`/`.producing`.
        TeamRoleDefinition(
            id: id, name: name, icon: "person.fill", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Some Input"]),
            isSystemRole: false
        )
    }

    private func producingRole(id: String, name: String = "Producer") -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: name, icon: "hammer.fill", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Artifact"]),
            isSystemRole: false
        )
    }

    private func supervisorRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "supervisor", name: "Supervisor", icon: "person.circle",
            prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: true, systemRoleID: "supervisor"
        )
    }

    private func observerRole(id: String) -> TeamRoleDefinition {
        // No required + no produced → `.observer` by derivation.
        TeamRoleDefinition(
            id: id, name: "Observer", icon: "eye.fill", prompt: "",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            isSystemRole: false
        )
    }

    private func question(stepID: String) -> TeamActivityActiveQuestion {
        TeamActivityActiveQuestion(
            stepID: stepID, role: .productManager, question: "Which?"
        )
    }

    // MARK: - resolveEffectiveRecipient — priority chain

    func testResolveEffectiveRecipient_explicitSelectionWins() {
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: .role(id: "tl"),
            activeQuestion: question(stepID: "sw"),   // would normally force .answer
            selectableRoles: [pm],                    // would normally force .role(pm)
            candidateRoles: [pm, tl]
        )
        XCTAssertEqual(result, .role(id: "tl"),
                       "Explicit selectedRecipient must override every auto-resolution")
    }

    func testResolveEffectiveRecipient_questionPending_returnsAnswerWithStepID() {
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil,
            activeQuestion: question(stepID: "pm-role-id"),
            selectableRoles: [],
            candidateRoles: []
        )
        XCTAssertEqual(result, .answer(stepID: "pm-role-id"),
                       ".answer must carry the step id so submit has no runtime lookup")
    }

    func testResolveEffectiveRecipient_singleWorkingRole_returnsThatRole() {
        let pm = normalRole(id: "pm")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestion: nil,
            selectableRoles: [pm], candidateRoles: [pm]
        )
        XCTAssertEqual(result, .role(id: "pm"),
                       "One working role → auto-pick it as the only viable recipient")
    }

    func testResolveEffectiveRecipient_singleCandidateNotWorking_returnsThatRole() {
        // One-role team whose sole role is currently idle (between chat turns).
        let assistant = normalRole(id: "assistant")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestion: nil,
            selectableRoles: [],                // not working right now
            candidateRoles: [assistant]
        )
        XCTAssertEqual(result, .role(id: "assistant"),
                       "Single-role team fallback: surface the role even when idle")
    }

    func testResolveEffectiveRecipient_multipleWorkingRoles_picksFirst() {
        let a = normalRole(id: "a")
        let b = normalRole(id: "b")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestion: nil,
            selectableRoles: [a, b], candidateRoles: [a, b]
        )
        // The first chip in the row must always be auto-selected when one exists —
        // there's no "no-recipient" state when chips are present. User can tap any
        // other chip to override.
        XCTAssertEqual(result, .role(id: "a"))
    }

    func testResolveEffectiveRecipient_multipleCandidatesNotWorking_picksFirstCandidate() {
        let a = normalRole(id: "a")
        let b = normalRole(id: "b")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestion: nil,
            selectableRoles: [],          // none working
            candidateRoles: [a, b]        // but candidates exist
        )
        // No chip is rendered for this state today (the single-candidate fallback
        // only fires for exactly 1 candidate), so this branch is defensive — but
        // if a chip ever becomes visible here, it must match the resolver's pick.
        XCTAssertEqual(result, .role(id: "a"))
    }

    func testResolveEffectiveRecipient_noRoles_noQuestion_returnsNil() {
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestion: nil,
            selectableRoles: [], candidateRoles: []
        )
        // No chip is emittable in this state — `nil` means the chip row collapses
        // and `canSubmit` is false. There is no broadcast/Team recipient anymore.
        XCTAssertNil(result)
    }

    // MARK: - computeSelectableRoles — filter invariants

    func testComputeSelectableRoles_excludesSupervisor() {
        let roles = [supervisorRole(), normalRole(id: "pm")]
        let result = TeamActivityComposer.computeSelectableRoles(
            roles: roles, workingRoleIDs: ["supervisor", "pm"], askingRoleID: nil
        )
        XCTAssertEqual(result.map(\.id), ["pm"],
                       "Supervisor is the user — never a queue target")
    }

    func testComputeSelectableRoles_excludesObservers() {
        let roles = [observerRole(id: "obs"), normalRole(id: "pm")]
        let result = TeamActivityComposer.computeSelectableRoles(
            roles: roles, workingRoleIDs: ["obs", "pm"], askingRoleID: nil
        )
        XCTAssertEqual(result.map(\.id), ["pm"],
                       "Observers don't execute steps — they can't asked for input")
    }

    func testComputeSelectableRoles_excludesNonWorkingRoles() {
        let pm = normalRole(id: "pm")
        let tl = normalRole(id: "tl")
        // Only pm is .working — tl is idle.
        let result = TeamActivityComposer.computeSelectableRoles(
            roles: [pm, tl], workingRoleIDs: ["pm"], askingRoleID: nil
        )
        XCTAssertEqual(result.map(\.id), ["pm"],
                       "Queueing to an idle role would never flush — exclude them from the chip row")
    }

    func testComputeSelectableRoles_excludesAskingRoleID() {
        let pm = normalRole(id: "pm")
        let tl = normalRole(id: "tl")
        // Both working, but PM is the one currently asking a supervisor question
        // → the composer already offers an "Answer PM" chip for them, a second
        // queue target would never flush (PM is paused on input, not .working).
        let result = TeamActivityComposer.computeSelectableRoles(
            roles: [pm, tl], workingRoleIDs: ["pm", "tl"], askingRoleID: "pm"
        )
        XCTAssertEqual(result.map(\.id), ["tl"],
                       "The asking role must be excluded — their Answer chip is the right target")
    }

    // MARK: - computeChipOptions — ordering, fallbacks, labels

    func testComputeChipOptions_questionPending_answerChipFirst() {
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [pm, tl],
            workingRoleIDs: ["pm", "tl"],
            activeQuestion: TeamActivityActiveQuestion(
                stepID: "pm", role: .productManager, question: "?"
            )
        )
        guard let first = options.first else {
            return XCTFail("Expected at least one chip option")
        }
        XCTAssertEqual(first.recipient, .answer(stepID: "pm"),
                       "Answer chip must lead when there is a pending question")
        XCTAssertTrue(first.label.contains("PM"),
                      "Answer chip label should name the asking role")
    }

    func testComputeChipOptions_singleWorkingRole_noTeamChip_noRedundancy() {
        let pm = normalRole(id: "pm", name: "PM")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [pm], workingRoleIDs: ["pm"], activeQuestion: nil
        )
        XCTAssertEqual(options.map(\.recipient), [.role(id: "pm")],
                       "With 1 selectable role, Team + role chips would deliver to the same place → show only the role chip")
    }

    func testComputeChipOptions_zeroRoles_zeroCandidates_returnsEmpty() {
        let options = TeamActivityComposer.computeChipOptions(
            roles: [], workingRoleIDs: [], activeQuestion: nil
        )
        XCTAssertTrue(options.isEmpty,
                      "Nothing to target → no chips. The chip row collapses and submit is disabled.")
    }

    func testComputeChipOptions_multipleSelectable_omitsTeamChip() {
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [pm, tl], workingRoleIDs: ["pm", "tl"], activeQuestion: nil
        )
        // Every queue must name a recipient — no Team broadcast chip is emitted.
        XCTAssertEqual(options.map(\.recipient),
                       [.role(id: "pm"), .role(id: "tl")])
    }

    func testComputeChipOptions_singleRoleTeamIdle_surfacesRoleChip_notTeam() {
        // Personal-Assistant-style: one-role team, role currently idle.
        let assistant = normalRole(id: "assistant", name: "Assistant")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [assistant], workingRoleIDs: [], activeQuestion: nil
        )
        XCTAssertEqual(options.map(\.recipient), [.role(id: "assistant")],
                       "Single-role team fallback: surface the role's own chip by name, not ambiguous Team")
    }

    func testComputeChipOptions_askingRoleExcludedEvenWhenWorking() {
        // PM is asking. TL is also working. Team chip should NOT appear because
        // after excluding PM, only 1 selectable role remains (TL).
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [pm, tl], workingRoleIDs: ["pm", "tl"],
            activeQuestion: TeamActivityActiveQuestion(
                stepID: "pm", role: .productManager, question: "?"
            )
        )
        // Expected: Answer PM, then TL (no Team because only 1 selectable after exclusion).
        let recipients = options.map(\.recipient)
        XCTAssertEqual(recipients, [.answer(stepID: "pm"), .role(id: "tl")])
    }

    // MARK: - computeCanSubmit — content gate + nil-recipient block

    func testComputeCanSubmit_emptyContent_returnsFalse() {
        XCTAssertFalse(TeamActivityComposer.computeCanSubmit(
            text: "", hasAttachments: false, hasClips: false,
            effectiveRecipient: .role(id: "pm")
        ))
    }

    func testComputeCanSubmit_whitespaceOnlyText_returnsFalse() {
        XCTAssertFalse(TeamActivityComposer.computeCanSubmit(
            text: "   \n\t  ", hasAttachments: false, hasClips: false,
            effectiveRecipient: .role(id: "pm")
        ))
    }

    func testComputeCanSubmit_textOnly_returnsTrue() {
        XCTAssertTrue(TeamActivityComposer.computeCanSubmit(
            text: "hi", hasAttachments: false, hasClips: false,
            effectiveRecipient: .role(id: "pm")
        ))
    }

    func testComputeCanSubmit_attachmentOnly_returnsTrue() {
        XCTAssertTrue(TeamActivityComposer.computeCanSubmit(
            text: "", hasAttachments: true, hasClips: false,
            effectiveRecipient: .role(id: "pm")
        ))
    }

    func testComputeCanSubmit_clipOnly_returnsTrue() {
        XCTAssertTrue(TeamActivityComposer.computeCanSubmit(
            text: "", hasAttachments: false, hasClips: true,
            effectiveRecipient: .role(id: "pm")
        ))
    }

    func testComputeCanSubmit_nilRecipientWithContent_returnsFalse() {
        // The disabled-recipient state: resolver returned nil because there was no
        // question and no working/candidate role. Even with content, submit must be
        // blocked — there's nowhere to send.
        XCTAssertFalse(TeamActivityComposer.computeCanSubmit(
            text: "queued from idle state", hasAttachments: true, hasClips: true,
            effectiveRecipient: nil
        ))
    }

    func testComputeCanSubmit_answerRecipient_alwaysAllowedWithContent() {
        XCTAssertTrue(TeamActivityComposer.computeCanSubmit(
            text: "answer", hasAttachments: false, hasClips: false,
            effectiveRecipient: .answer(stepID: "pm")
        ))
    }

    // MARK: - sanitizeSelection — stale chip cleanup

    func testSanitizeSelection_nilStaysNil() {
        XCTAssertNil(TeamActivityComposer.sanitizeSelection(
            selected: nil, availableRecipients: [.role(id: "pm")]
        ))
    }

    func testSanitizeSelection_validSelectionPassesThrough() {
        let result = TeamActivityComposer.sanitizeSelection(
            selected: .role(id: "pm"),
            availableRecipients: [.role(id: "pm"), .role(id: "tl")]
        )
        XCTAssertEqual(result, .role(id: "pm"))
    }

    func testSanitizeSelection_staleAnswerSelectionDropped() {
        // Scenario: Supervisor selected "Answer PM", answered, activeQuestion went
        // nil. Without cleanup, `selectedRecipient = .answer("pm")` would persist
        // and resolver-explicit-wins keeps the placeholder/avatar/submit pointed at
        // a non-existent question.
        let result = TeamActivityComposer.sanitizeSelection(
            selected: .answer(stepID: "pm"),
            availableRecipients: [.role(id: "pm"), .role(id: "tl")]
        )
        XCTAssertNil(result, "Answer chip is no longer in the row → drop the selection")
    }

    func testSanitizeSelection_staleRoleSelectionDropped() {
        // Scenario: Supervisor selected role TL, then TL completed and is no longer
        // in workingRoleIDs. The chip vanished — drop the selection.
        let result = TeamActivityComposer.sanitizeSelection(
            selected: .role(id: "tl"),
            availableRecipients: [.role(id: "pm")]
        )
        XCTAssertNil(result)
    }

    func testSanitizeSelection_emptyAvailableDropsEverything() {
        XCTAssertNil(TeamActivityComposer.sanitizeSelection(
            selected: .answer(stepID: "pm"), availableRecipients: []
        ))
        XCTAssertNil(TeamActivityComposer.sanitizeSelection(
            selected: .role(id: "pm"), availableRecipients: []
        ))
    }

    // MARK: - TeamActivityActiveQuestion — invariant

    func testActiveQuestion_askingRoleIDEqualsStepID() {
        // Compile-enforced by the type itself: `askingRoleID` is a computed
        // projection of `stepID`. This test pins the contract.
        let q = TeamActivityActiveQuestion(
            stepID: "role-42", role: .productManager, question: "?"
        )
        XCTAssertEqual(q.askingRoleID, q.stepID)
        XCTAssertEqual(q.askingRoleID, "role-42")
    }
}
