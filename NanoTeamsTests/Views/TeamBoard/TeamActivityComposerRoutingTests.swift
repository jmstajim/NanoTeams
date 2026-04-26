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
            activeQuestions: [question(stepID: "sw")],   // would normally force .answer
            selectableRoles: [pm],                       // would normally force .role(pm)
            candidateRoles: [pm, tl]
        )
        XCTAssertEqual(result, .role(id: "tl"),
                       "Explicit selectedRecipient must override every auto-resolution")
    }

    func testResolveEffectiveRecipient_questionPending_returnsAnswerWithStepID() {
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil,
            activeQuestions: [question(stepID: "pm-role-id")],
            selectableRoles: [],
            candidateRoles: []
        )
        XCTAssertEqual(result, .answer(stepID: "pm-role-id"),
                       ".answer must carry the step id so submit has no runtime lookup")
    }

    func testResolveEffectiveRecipient_singleWorkingRole_returnsThatRole() {
        let pm = normalRole(id: "pm")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [pm], candidateRoles: [pm]
        )
        XCTAssertEqual(result, .role(id: "pm"),
                       "One working role → auto-pick it as the only viable recipient")
    }

    func testResolveEffectiveRecipient_singleCandidateNotWorking_returnsThatRole() {
        // One-role team whose sole role is currently idle (between chat turns).
        let assistant = normalRole(id: "assistant")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
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
            selected: nil, activeQuestions: [],
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
            selected: nil, activeQuestions: [],
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
            selected: nil, activeQuestions: [],
            selectableRoles: [], candidateRoles: []
        )
        // No chip is emittable in this state — `nil` means the chip row collapses
        // and `canSubmit` is false. There is no broadcast/Team recipient anymore.
        XCTAssertNil(result)
    }

    func testResolveEffectiveRecipient_multiplePending_returnsFirstAnswer() {
        // The engine runs ready roles in parallel (CLAUDE.md #45) — N parallel
        // ask_supervisor calls produce N pending questions. Without explicit
        // selection, the FIRST in the row (input order) must be auto-picked.
        let q1 = question(stepID: "role-1")
        let q2 = question(stepID: "role-2")
        let q3 = question(stepID: "role-3")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil,
            activeQuestions: [q1, q2, q3],
            selectableRoles: [], candidateRoles: []
        )
        XCTAssertEqual(result, .answer(stepID: "role-1"),
                       "First pending question wins — matches the leftmost Answer chip")
    }

    // MARK: - computeSelectableRoles — filter invariants

    func testComputeSelectableRoles_excludesSupervisor() {
        let roles = [supervisorRole(), normalRole(id: "pm")]
        let result = TeamActivityComposer.computeSelectableRoles(
            roles: roles, workingRoleIDs: ["supervisor", "pm"], askingRoleIDs: []
        )
        XCTAssertEqual(result.map(\.id), ["pm"],
                       "Supervisor is the user — never a queue target")
    }

    func testComputeSelectableRoles_excludesObservers() {
        let roles = [observerRole(id: "obs"), normalRole(id: "pm")]
        let result = TeamActivityComposer.computeSelectableRoles(
            roles: roles, workingRoleIDs: ["obs", "pm"], askingRoleIDs: []
        )
        XCTAssertEqual(result.map(\.id), ["pm"],
                       "Observers don't execute steps — they can't asked for input")
    }

    func testComputeSelectableRoles_excludesNonWorkingRoles() {
        let pm = normalRole(id: "pm")
        let tl = normalRole(id: "tl")
        // Only pm is .working — tl is idle.
        let result = TeamActivityComposer.computeSelectableRoles(
            roles: [pm, tl], workingRoleIDs: ["pm"], askingRoleIDs: []
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
            roles: [pm, tl], workingRoleIDs: ["pm", "tl"], askingRoleIDs: ["pm"]
        )
        XCTAssertEqual(result.map(\.id), ["tl"],
                       "The asking role must be excluded — their Answer chip is the right target")
    }

    func testComputeSelectableRoles_excludesAllAskingRoles() {
        // Multiple parallel ask_supervisor: every asking role must be excluded from
        // the queue-role chip set, not just one. Otherwise duplicate chips collide.
        let a = normalRole(id: "a", name: "A")
        let b = normalRole(id: "b", name: "B")
        let c = normalRole(id: "c", name: "C")
        let d = normalRole(id: "d", name: "D")
        let result = TeamActivityComposer.computeSelectableRoles(
            roles: [a, b, c, d],
            workingRoleIDs: ["a", "b", "c", "d"],
            askingRoleIDs: ["a", "b", "c"]
        )
        XCTAssertEqual(result.map(\.id), ["d"],
                       "All asking roles must be filtered, only D remains as a queue target")
    }

    // MARK: - computeChipOptions — ordering, fallbacks, labels

    func testComputeChipOptions_questionPending_answerChipFirst() {
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [pm, tl],
            workingRoleIDs: ["pm", "tl"],
            activeQuestions: [TeamActivityActiveQuestion(
                stepID: "pm", role: .productManager, question: "?"
            )]
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
            roles: [pm], workingRoleIDs: ["pm"], activeQuestions: []
        )
        XCTAssertEqual(options.map(\.recipient), [.role(id: "pm")],
                       "With 1 selectable role, Team + role chips would deliver to the same place → show only the role chip")
    }

    func testComputeChipOptions_zeroRoles_zeroCandidates_returnsEmpty() {
        let options = TeamActivityComposer.computeChipOptions(
            roles: [], workingRoleIDs: [], activeQuestions: []
        )
        XCTAssertTrue(options.isEmpty,
                      "Nothing to target → no chips. The chip row collapses and submit is disabled.")
    }

    func testComputeChipOptions_multipleSelectable_omitsTeamChip() {
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [pm, tl], workingRoleIDs: ["pm", "tl"], activeQuestions: []
        )
        // Every queue must name a recipient — no Team broadcast chip is emitted.
        XCTAssertEqual(options.map(\.recipient),
                       [.role(id: "pm"), .role(id: "tl")])
    }

    func testComputeChipOptions_singleRoleTeamIdle_surfacesRoleChip_notTeam() {
        // Personal-Assistant-style: one-role team, role currently idle.
        let assistant = normalRole(id: "assistant", name: "Assistant")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [assistant], workingRoleIDs: [], activeQuestions: []
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
            activeQuestions: [TeamActivityActiveQuestion(
                stepID: "pm", role: .productManager, question: "?"
            )]
        )
        // Expected: Answer PM, then TL (no Team because only 1 selectable after exclusion).
        let recipients = options.map(\.recipient)
        XCTAssertEqual(recipients, [.answer(stepID: "pm"), .role(id: "tl")])
    }

    func testComputeChipOptions_multiplePending_emitsAnswerChipPerRole() {
        // Three roles all in .needsSupervisorInput simultaneously (engine runs ready
        // roles in parallel, CLAUDE.md #45). Expect three Answer chips in input order,
        // each with the asking role's name; no asking role appears as a queue chip.
        let a = normalRole(id: "a", name: "Tactical Execution Lead")
        let b = normalRole(id: "b", name: "Market Intelligence Analyst")
        let c = normalRole(id: "c", name: "Strategic Visionary")
        let d = normalRole(id: "d", name: "Other")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [a, b, c, d],
            workingRoleIDs: ["a", "b", "c", "d"],
            activeQuestions: [
                TeamActivityActiveQuestion(stepID: "a", role: .productManager, question: "?"),
                TeamActivityActiveQuestion(stepID: "b", role: .productManager, question: "?"),
                TeamActivityActiveQuestion(stepID: "c", role: .productManager, question: "?")
            ]
        )
        let recipients = options.map(\.recipient)
        XCTAssertEqual(recipients, [
            .answer(stepID: "a"),
            .answer(stepID: "b"),
            .answer(stepID: "c"),
            .role(id: "d")
        ], "One Answer chip per pending role, in input order, before queue chips")

        // Asking-role names must surface in their Answer chip labels.
        XCTAssertEqual(options[0].label, "Answer Tactical Execution Lead")
        XCTAssertEqual(options[1].label, "Answer Market Intelligence Analyst")
        XCTAssertEqual(options[2].label, "Answer Strategic Visionary")
        // Reply icon on every Answer chip.
        XCTAssertEqual(options[0].icon, "arrowshape.turn.up.left.fill")
        XCTAssertEqual(options[1].icon, "arrowshape.turn.up.left.fill")
        XCTAssertEqual(options[2].icon, "arrowshape.turn.up.left.fill")
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

    func testSanitizeSelection_oneOfMultipleAnswerChipsRemoved_droppedSelection() {
        // Realistic mid-multi-pending scenario: PM, TL, and SWE all asked. Supervisor
        // explicitly clicked "Answer TL" and started typing. While drafting, TL was
        // answered through another surface (Watchtower / QuickCapture). The TL Answer
        // chip vanishes from the row — the explicit selection must drop to nil so the
        // resolver doesn't silently keep pointing at a non-existent recipient.
        let result = TeamActivityComposer.sanitizeSelection(
            selected: .answer(stepID: "tl"),
            availableRecipients: [
                .answer(stepID: "pm"), .answer(stepID: "swe"), .role(id: "eng")
            ]
        )
        XCTAssertNil(result, "Selection of an Answer chip that is no longer in the row must drop")
    }

    func testSanitizeSelection_oneOfMultipleAnswerChipsRemoved_otherSurvivors() {
        // Sibling case: Supervisor selected "Answer PM" out of {PM, TL, SWE}. SWE was
        // answered elsewhere; PM's chip is still in the row. Selection must pass through
        // unchanged — only stale selections are dropped, surviving ones are preserved
        // so the user's intent stays locked.
        let result = TeamActivityComposer.sanitizeSelection(
            selected: .answer(stepID: "pm"),
            availableRecipients: [.answer(stepID: "pm"), .answer(stepID: "tl")]
        )
        XCTAssertEqual(result, .answer(stepID: "pm"),
                       "Surviving Answer chips must keep their selection — don't auto-fall-through")
    }

    // MARK: - shouldClearDraftAfterSelectionLoss — mid-typing retarget guard

    /// Why this exists: with multiple parallel `ask_supervisor` chips, the user can be
    /// mid-typing into the auto-selected leftmost chip when the underlying question is
    /// answered through another surface (Watchtower, QuickCapture). Without this guard,
    /// `effectiveRecipient` falls through to the next pending question and the drafted
    /// reply silently retargets to a different role. Returning `true` tells the
    /// composer to discard the draft + surface a banner.
    func testShouldClearDraft_explicitSelectionLost_withContent_returnsTrue() {
        let result = TeamActivityComposer.shouldClearDraftAfterSelectionLoss(
            prior: .answer(stepID: "pm"),
            sanitized: nil,
            hasContent: true
        )
        XCTAssertTrue(result,
                      "User had locked-in selection + content; chip vanished → clear draft to prevent silent retarget")
    }

    func testShouldClearDraft_emptyDraft_returnsFalse() {
        // Nothing to lose if there's no content — let auto-resolution proceed silently.
        let result = TeamActivityComposer.shouldClearDraftAfterSelectionLoss(
            prior: .answer(stepID: "pm"), sanitized: nil, hasContent: false
        )
        XCTAssertFalse(result)
    }

    func testShouldClearDraft_selectionSurvivesSanitize_returnsFalse() {
        // The chip is still in the row after sanitize — no draft loss to warn about.
        let result = TeamActivityComposer.shouldClearDraftAfterSelectionLoss(
            prior: .answer(stepID: "pm"),
            sanitized: .answer(stepID: "pm"),
            hasContent: true
        )
        XCTAssertFalse(result)
    }

    func testShouldClearDraft_neverHadExplicitSelection_returnsFalse() {
        // No prior explicit lock means the user never committed to a recipient — the
        // resolver's first-chip auto-pick is still appropriate; we don't clear pre-typing.
        let result = TeamActivityComposer.shouldClearDraftAfterSelectionLoss(
            prior: nil, sanitized: nil, hasContent: true
        )
        XCTAssertFalse(result)
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
