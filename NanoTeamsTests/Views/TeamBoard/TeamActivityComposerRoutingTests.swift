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

    // MARK: - computeRouting — the aggregator the composer body calls

    /// `computeRouting` derives `askingRoleIDs` and the three role arrays ONCE and feeds
    /// both the chip row and the recipient resolver. That is a perf fix (the composer used
    /// to re-derive them ~11 times per body pass, ~9 heap allocations each), but the
    /// property worth pinning is the STRUCTURAL one: `computeFailedRoles`' doc comment
    /// claims the resolver and the chip row "can never disagree on which roles count as
    /// failed", and until this aggregator existed that was true only by convention —
    /// two independent derivations that happened to call the same helper.
    ///
    /// The table below runs the shapes the rest of this file already covers and asserts
    /// `computeRouting` agrees with BOTH original entry points on every one. RED: drop
    /// `askingRoleIDs` from one of `computeRouting`'s three derivations, or reorder its
    /// chip assembly — the fixtures with an asking role diverge.
    func testComputeRouting_agreesWithBothEntryPointsItReplaces() {
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        let obs = observerRole(id: "obs")
        let sup = supervisorRole()
        let roster = [sup, pm, tl, obs]
        let q = question(stepID: "pm")

        let cases: [(String, [TeamRoleDefinition], Set<String>, Set<String>,
                     [TeamActivityActiveQuestion], Bool, TeamActivityComposer.Recipient?)] = [
            ("idle team, no fallback",        roster, [],           [],     [],  false, nil),
            ("idle team, fallback on",        roster, [],           [],     [],  true,  nil),
            ("one working role",              roster, ["tl"],       [],     [],  false, nil),
            ("asking role excluded from queue", roster, ["pm"],     [],     [q], false, nil),
            ("failed retry target",           roster, [],           ["tl"], [],  false, nil),
            ("failed AND asking",             roster, [],           ["pm"], [q], false, nil),
            ("explicit selection held",       roster, ["tl"],       [],     [q], false, .role(id: "tl")),
            ("selection on the answer chip",  roster, ["tl"],       [],     [q], false, .answer(stepID: "pm")),
            ("empty roster",                  [],     [],           [],     [],  true,  nil),
            // Selects the CANDIDATE derivation specifically: fallback on, the only
            // messageable role is the one asking, so `candidates` must be EMPTY and no
            // fallback chip may appear. Added after a mutation of `computeRouting`'s
            // `askingRoleIDs` argument produced zero reds — the table above never reached
            // that branch, which is CLAUDE.md #56 reading 3, not a redundant pin.
            ("fallback on, sole role is asking", [sup, pm], [],      [],     [q], true,  nil),
        ]

        for (label, roles, working, failed, questions, fallback, selected) in cases {
            let routing = TeamActivityComposer.computeRouting(
                roles: roles, workingRoleIDs: working, failedRoleIDs: failed,
                activeQuestions: questions, allowsRoleFallback: fallback, selected: selected)

            XCTAssertEqual(
                routing.chipOptions,
                TeamActivityComposer.computeChipOptions(
                    roles: roles, workingRoleIDs: working, failedRoleIDs: failed,
                    activeQuestions: questions, allowsRoleFallback: fallback),
                "chip options diverged from `computeChipOptions` — \(label)")

            let asking = Set(questions.map(\.askingRoleID))
            XCTAssertEqual(
                routing.effectiveRecipient,
                TeamActivityComposer.resolveEffectiveRecipient(
                    selected: selected,
                    activeQuestions: questions,
                    selectableRoles: TeamActivityComposer.computeSelectableRoles(
                        roles: roles, workingRoleIDs: working, askingRoleIDs: asking),
                    failedRoles: TeamActivityComposer.computeFailedRoles(
                        roles: roles, failedRoleIDs: failed, askingRoleIDs: asking),
                    candidateRoles: TeamActivityComposer.computeCandidateRoles(
                        roles: roles, askingRoleIDs: asking),
                    allowsRoleFallback: fallback),
                "effective recipient diverged from `resolveEffectiveRecipient` — \(label)")
        }
    }

    /// Anti-vacuum for the table above: if every case produced an empty chip row and a nil
    /// recipient, the equality assertions would hold for a `computeRouting` that returned
    /// nothing at all (CLAUDE.md #104).
    func testComputeRouting_actuallyProducesChipsAndRecipients() {
        let pm = normalRole(id: "pm", name: "PM")
        let routing = TeamActivityComposer.computeRouting(
            roles: [supervisorRole(), pm], workingRoleIDs: ["pm"], failedRoleIDs: [],
            activeQuestions: [], allowsRoleFallback: false, selected: nil)
        XCTAssertEqual(routing.chipOptions.map(\.recipient), [.role(id: "pm")])
        XCTAssertEqual(routing.effectiveRecipient, .role(id: "pm"))
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

    func testResolveEffectiveRecipient_singleCandidateNotWorking_chatFallback_returnsThatRole() {
        // One-role team whose sole role is currently idle (between chat turns). Chat mode →
        // allowsRoleFallback true, so the role is surfaced even when idle.
        let assistant = normalRole(id: "assistant")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],                // not working right now
            candidateRoles: [assistant],
            allowsRoleFallback: true
        )
        XCTAssertEqual(result, .role(id: "assistant"),
                       "Single-role chat team fallback: surface the role even when idle")
    }

    func testResolveEffectiveRecipient_singleCandidateNotWorking_fallbackDisallowed_returnsNil() {
        // Single-role NON-chat team awaiting acceptance (e.g. Startup): the sole candidate
        // must NOT be resolved — sending there is a no-op, so the composer goes inert.
        let swe = normalRole(id: "swe")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],
            candidateRoles: [swe],
            allowsRoleFallback: false
        )
        XCTAssertNil(result,
                     "Single-role non-chat team in .needsAcceptance → no recipient (no enabled no-op send)")
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

    func testResolveEffectiveRecipient_multipleCandidatesNotWorking_fallbackDisallowed_returnsNil() {
        let a = normalRole(id: "a")
        let b = normalRole(id: "b")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],            // none working
            candidateRoles: [a, b],         // multiple candidates, but…
            allowsRoleFallback: false       // …not a resumable/chat state (e.g. .needsAcceptance)
        )
        // The done/awaiting-review case from the screenshot: no chip is rendered and the
        // resolver must NOT name an arbitrary first candidate. Composer goes inert.
        XCTAssertNil(result,
                     "Multi-candidate with fallback disallowed (.needsAcceptance) → no recipient, composer disabled")
    }

    func testResolveEffectiveRecipient_multipleCandidatesNotWorking_fallbackAllowed_picksFirst() {
        let a = normalRole(id: "a")
        let b = normalRole(id: "b")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],            // none working
            candidateRoles: [a, b],         // multiple candidates
            allowsRoleFallback: true        // resumable-by-send (.paused/.pending) or chat
        )
        // Paused/pending multi-role resume (or chat): keep send enabled by resolving to the
        // first candidate (queued untargeted, rides resumeRun). Placeholder stays role-agnostic.
        XCTAssertEqual(result, .role(id: "a"))
    }

    func testResolveEffectiveRecipient_failedRoleBeatsCandidateFallback() {
        // A failed run names the failed role as the retry target — even though it's also a
        // plain candidate, the dedicated failed branch picks it before the generic fallback.
        let pm = normalRole(id: "pm")
        let tpm = normalRole(id: "tpm")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],
            failedRoles: [tpm],
            candidateRoles: [pm, tpm],
            allowsRoleFallback: true
        )
        XCTAssertEqual(result, .role(id: "tpm"),
                       "Failed role is the named retry target, ahead of candidateRoles.first")
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

    func testComputeChipOptions_singleRoleTeamIdle_chatFallback_surfacesRoleChip() {
        // Personal-Assistant-style: one-role chat team, role idle → allowsRoleFallback true.
        let assistant = normalRole(id: "assistant", name: "Assistant")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [assistant], workingRoleIDs: [], activeQuestions: [], allowsRoleFallback: true
        )
        XCTAssertEqual(options.map(\.recipient), [.role(id: "assistant")],
                       "Single-role chat team fallback: surface the role's own chip by name")
    }

    func testComputeChipOptions_singleRoleTeamIdle_fallbackDisallowed_noChip() {
        // Single-role NON-chat team awaiting acceptance (e.g. Startup): no chip — otherwise
        // the chip would be a tap-trap resolving to a no-op send.
        let swe = normalRole(id: "swe", name: "SWE")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [swe], workingRoleIDs: [], activeQuestions: [], allowsRoleFallback: false
        )
        XCTAssertTrue(options.isEmpty,
                      "Single-role non-chat team in .needsAcceptance → no chip, composer inert")
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
        XCTAssertEqual(options[0].icon, "arrowshape.turn.up.left")
        XCTAssertEqual(options[1].icon, "arrowshape.turn.up.left")
        XCTAssertEqual(options[2].icon, "arrowshape.turn.up.left")
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

    // MARK: - remapEquivalentRecipient — draft-preserving role↔answer retarget

    func testRemap_nilPrior_returnsNil() {
        XCTAssertNil(TeamActivityComposer.remapEquivalentRecipient(
            prior: nil, availableRecipients: [.role(id: "autovisor")]
        ))
    }

    func testRemap_priorStillPresent_keepsSameShape() {
        // Same shape still available → no change (matches sanitizeSelection's keep).
        XCTAssertEqual(
            TeamActivityComposer.remapEquivalentRecipient(
                prior: .role(id: "autovisor"),
                availableRecipients: [.role(id: "autovisor"), .answer(stepID: "autovisor")]
            ),
            .role(id: "autovisor"),
            "When the exact prior recipient is still in the row, keep it (don't switch shapes)")
    }

    func testRemap_roleLost_answerForSameRolePresent_remapsToAnswer() {
        // THE bug-1 case: the Autovisor was working (.role chip), then parked → the
        // working chip is replaced by the Answer chip for the SAME role (stepID == roleID).
        XCTAssertEqual(
            TeamActivityComposer.remapEquivalentRecipient(
                prior: .role(id: "autovisor"),
                availableRecipients: [.answer(stepID: "autovisor")]
            ),
            .answer(stepID: "autovisor"),
            "running→parked flip must retarget .role(X) → .answer(X), not discard")
    }

    func testRemap_answerLost_roleForSameRolePresent_remapsToRole() {
        // The reverse flip: parked (.answer) → resumes to running (.role) for the same role.
        XCTAssertEqual(
            TeamActivityComposer.remapEquivalentRecipient(
                prior: .answer(stepID: "autovisor"),
                availableRecipients: [.role(id: "autovisor")]
            ),
            .role(id: "autovisor"),
            "parked→running flip must retarget .answer(X) → .role(X)")
    }

    func testRemap_roleLost_onlyDifferentRoleAvailable_returnsNil() {
        // The prior role is genuinely gone (a different role's chip is present) → nil,
        // so shouldClearDraftAfterSelectionLoss can discard as before.
        XCTAssertNil(
            TeamActivityComposer.remapEquivalentRecipient(
                prior: .role(id: "autovisor"),
                availableRecipients: [.answer(stepID: "other"), .role(id: "other")]
            ),
            "No chip for the same role X remains → genuinely lost, return nil")
    }

    func testRemap_emptyAvailable_returnsNil() {
        XCTAssertNil(TeamActivityComposer.remapEquivalentRecipient(
            prior: .role(id: "autovisor"), availableRecipients: []
        ))
    }

    func testRemap_answerLost_prefersSameRoleCounterpartOverUnrelatedAnswer() {
        // Mixed row: an unrelated Answer chip AND the same role's .role chip. The remap
        // must pick the same-role counterpart, never the unrelated answer.
        XCTAssertEqual(
            TeamActivityComposer.remapEquivalentRecipient(
                prior: .answer(stepID: "autovisor"),
                availableRecipients: [.answer(stepID: "other"), .role(id: "autovisor")]
            ),
            .role(id: "autovisor"),
            "Remap targets the same role's counterpart, not an unrelated chip")
    }

    /// Integration: the running↔parked flip combined with the discard guard must NOT
    /// discard the draft (the user-reported "message disappears"). With the remap in
    /// place, `sanitized` is the counterpart recipient, so `shouldClearDraftAfterSelectionLoss`
    /// returns false even though the original `.role` chip vanished.
    func testRemap_runningToParkedFlip_doesNotTriggerDraftDiscard() {
        let prior: TeamActivityComposer.Recipient = .role(id: "autovisor")
        let recipients: [TeamActivityComposer.Recipient] = [.answer(stepID: "autovisor")]
        let sanitized = TeamActivityComposer.remapEquivalentRecipient(
            prior: prior, availableRecipients: recipients
        )
        XCTAssertEqual(sanitized, .answer(stepID: "autovisor"))
        XCTAssertFalse(
            TeamActivityComposer.shouldClearDraftAfterSelectionLoss(
                prior: prior, sanitized: sanitized, hasContent: true
            ),
            "Remapped flip keeps the draft — discard must NOT fire when the same role is still reachable")
    }

    /// Integration: a genuine recipient loss (the role is gone, no counterpart) still
    /// discards — the remap doesn't weaken the existing guard.
    func testRemap_genuineLoss_stillTriggersDraftDiscard() {
        let prior: TeamActivityComposer.Recipient = .role(id: "autovisor")
        let recipients: [TeamActivityComposer.Recipient] = []   // role finished, nothing left
        let sanitized = TeamActivityComposer.remapEquivalentRecipient(
            prior: prior, availableRecipients: recipients
        )
        XCTAssertNil(sanitized)
        XCTAssertTrue(
            TeamActivityComposer.shouldClearDraftAfterSelectionLoss(
                prior: prior, sanitized: sanitized, hasContent: true
            ),
            "A genuinely lost recipient with content still discards (guard unchanged)")
    }

    func testRemap_answerPriorStillPresent_keepsSameShape() {
        // Symmetry with testRemap_priorStillPresent_keepsSameShape (which uses .role): an
        // .answer prior that's still in the row is kept EXACTLY, even though its .role
        // counterpart is also present — "prior present" wins over "find a counterpart".
        XCTAssertEqual(
            TeamActivityComposer.remapEquivalentRecipient(
                prior: .answer(stepID: "autovisor"),
                availableRecipients: [.answer(stepID: "autovisor"), .role(id: "autovisor")]
            ),
            .answer(stepID: "autovisor"),
            "An .answer prior still present must be kept, not swapped to its .role counterpart")
    }

    func testRemap_roleLost_prefersSameRoleCounterpartOverUnrelatedChips() {
        // Role-lost direction of testRemap_answerLost_prefersSameRoleCounterpartOverUnrelatedAnswer:
        // a mixed row with an unrelated .role, the same role's .answer, and an unrelated .answer
        // must resolve to the SAME role's .answer, never an unrelated chip.
        XCTAssertEqual(
            TeamActivityComposer.remapEquivalentRecipient(
                prior: .role(id: "autovisor"),
                availableRecipients: [.role(id: "other"), .answer(stepID: "autovisor"), .answer(stepID: "other")]
            ),
            .answer(stepID: "autovisor"),
            "role-lost remap must pick the same role's .answer counterpart, ignoring unrelated chips")
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

    // MARK: - cardThinking (which surface owns the reasoning row)

    /// A contentless turn is fully covered by the card, so the card renders its
    /// reasoning — the feed bubble is suppressed and would otherwise show none.
    /// RED: invert the predicate to `content != nil` → the card yields a turn it owns
    /// and `cardThinking` is nil, so the reasoning row disappears from both surfaces.
    func testCardThinking_contentlessPairedTurn_cardOwnsTheReasoning() {
        let q = TeamActivityActiveQuestion(
            stepID: "pm", role: .productManager, question: "?",
            paired: PairedAssistantMessage(id: UUID(), thinking: "Reasoning.", content: nil)
        )
        XCTAssertEqual(q.cardThinking, "Reasoning.")
    }

    /// A prose-carrying turn keeps its feed bubble, and that bubble renders the
    /// reasoning via `MessageThinkingSection`. The card must yield, or the same
    /// reasoning appears twice — once in a height-constrained card.
    /// RED: force `isFullyRenderedByQuestionCard` to `true` → the card claims a turn the
    /// feed bubble also renders, and `XCTAssertNil` fails on the duplicated reasoning.
    func testCardThinking_prosePairedTurn_yieldsToTheFeedBubble() {
        let q = TeamActivityActiveQuestion(
            stepID: "pm", role: .productManager, question: "?",
            paired: PairedAssistantMessage(
                id: UUID(), thinking: "Reasoning.", content: "Looked into it. Answering."
            )
        )
        XCTAssertNil(q.cardThinking,
                     "The visible bubble owns the reasoning row when the turn carried prose")
    }

    /// No preamble turn at all — nothing to render, nothing to suppress.
    func testCardThinking_nilPaired_isNil() {
        let q = TeamActivityActiveQuestion(
            stepID: "pm", role: .productManager, question: "?", paired: nil
        )
        XCTAssertNil(q.cardThinking)
    }

    /// Symmetry: `paired == nil` vs `paired != nil` are unequal (the Optional
    /// shape alone distinguishes them, independent of any `paired` field).
    func testActiveQuestion_equatable_nilPairedVsNonNil_areNotEqual() {
        let a = TeamActivityActiveQuestion(
            stepID: "s", role: .productManager, question: "?", paired: nil
        )
        let b = TeamActivityActiveQuestion(
            stepID: "s", role: .productManager, question: "?",
            paired: PairedAssistantMessage(id: UUID(), thinking: nil, content: nil)
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - performAnswerSubmit (phase-ordering contract)

    /// Pins the synchronous-clear-before-async-submit contract. If `clear` were
    /// to run after the await (the old `nextComposerState` design), the
    /// `.onChange(of: chipOptionsComputed.map(\.recipient))` reaction that
    /// fires while the Answer chip disappears mid-submit would observe
    /// `hasContent=true` and surface a false-positive "recipient no longer
    /// waiting" info banner for a successful submit.
    func testPerformAnswerSubmit_clearsSynchronouslyBeforeSubmit() async {
        var events: [String] = []
        await TeamActivityComposer.performAnswerSubmit(
            snapshotText: "zxc",
            snapshotAttachments: [],
            snapshotClips: [],
            clear: { events.append("clear") },
            submit: { events.append("submit"); return true },
            restore: { _, _, _ in events.append("restore") }
        )
        XCTAssertEqual(
            events, ["clear", "submit"],
            "Clear must run synchronously before the async submit — otherwise the chip-disappearance .onChange sees hasContent=true and fires a false-positive 'recipient no longer waiting' banner."
        )
    }

    /// On failure the snapshot is restored AFTER the synchronous clear has run.
    /// The user gets their draft back to retry without retyping, and the
    /// recipient picker auto-resolves to the next chip via `.onChange`
    /// sanitization (covered by `testSanitizeSelection_*`).
    func testPerformAnswerSubmit_onFailure_restoresSnapshotAfterClear() async {
        var events: [String] = []
        var restoredText: String?
        var restoredClips: [String]?
        await TeamActivityComposer.performAnswerSubmit(
            snapshotText: "zxc",
            snapshotAttachments: [],
            snapshotClips: ["clipA"],
            clear: { events.append("clear") },
            submit: { events.append("submit"); return false },
            restore: { t, _, c in
                events.append("restore")
                restoredText = t
                restoredClips = c
            }
        )
        XCTAssertEqual(events, ["clear", "submit", "restore"])
        XCTAssertEqual(restoredText, "zxc")
        XCTAssertEqual(restoredClips, ["clipA"])
    }

    /// On success `restore` is NOT called — the draft stays cleared. Pinning
    /// this prevents a future refactor from accidentally double-clearing or
    /// re-running restore on `ok == true`.
    func testPerformAnswerSubmit_onSuccess_doesNotRestore() async {
        var events: [String] = []
        await TeamActivityComposer.performAnswerSubmit(
            snapshotText: "zxc",
            snapshotAttachments: [],
            snapshotClips: [],
            clear: { events.append("clear") },
            submit: { events.append("submit"); return true },
            restore: { _, _, _ in events.append("restore") }
        )
        XCTAssertEqual(events, ["clear", "submit"])
    }

    // MARK: - clearedComposerState (post-submit reset contract)

    /// Pins the post-submit reset contract: `clearComposer()` must reset
    /// `selectedRecipient` to nil in addition to clearing text/attachments/clips.
    /// Without this, a `.role(codingAgent)` lock from a previous queue submit
    /// survives through to the next render — when a new `ask_supervisor` adds
    /// an Answer chip to `chipOptions`, `resolveEffectiveRecipient` keeps the
    /// stale `.role` lock (explicit-selection priority 1) and the Answer chip
    /// never auto-selects. User sees only the queue chip and can't answer
    /// without manually clicking the Answer chip.
    func testClearedComposerState_resetsAllFieldsIncludingRecipient() {
        let state = TeamActivityComposer.clearedComposerState()
        XCTAssertEqual(state.text, "", "Text must be cleared")
        XCTAssertTrue(state.attachments.isEmpty, "Attachments must be cleared")
        XCTAssertTrue(state.clips.isEmpty, "Clips must be cleared")
        XCTAssertNil(
            state.selectedRecipient,
            "selectedRecipient MUST be reset — otherwise the explicit-selection priority in resolveEffectiveRecipient keeps a stale .role lock from a previous queue submit, preventing auto-resolution to a newly-arrived Answer chip when the role asks again."
        )
    }

    // MARK: - bannerForFailedFiles

    /// Replaces the deleted VM coverage for the failedFiles banner. The exact
    /// wording is asserted because changing it silently would degrade UX —
    /// users rely on the "attached as paths" phrasing to know files were still
    /// delivered (not lost).
    func testBannerForFailedFiles_empty_returnsNil() {
        XCTAssertNil(TeamActivityComposer.bannerForFailedFiles([]),
                     "No failed files → no banner; submitting clean is a non-event")
    }

    func testBannerForFailedFiles_oneFile_explainsPathFallback() {
        let banner = TeamActivityComposer.bannerForFailedFiles(["budget.xlsx"])
        XCTAssertEqual(
            banner,
            "Could not embed 1 file(s) inline — attached as paths: budget.xlsx.",
            "Banner must signal that the file was NOT lost — it was attached as a path"
        )
    }

    func testBannerForFailedFiles_multipleFiles_listsAll() {
        let banner = TeamActivityComposer.bannerForFailedFiles(["a.bin", "b.bin", "c.bin"])
        XCTAssertEqual(
            banner,
            "Could not embed 3 file(s) inline — attached as paths: a.bin, b.bin, c.bin."
        )
    }

    // MARK: - queueTarget — targeted vs untargeted on submit

    /// A working role gets a role-targeted queue entry (steering for a live role) —
    /// delivered to that role via the role-targeted tier of `injectQueuedSupervisorMessage`.
    func testQueueTarget_workingRole_targetsThatRole() {
        XCTAssertEqual(
            TeamActivityComposer.queueTarget(roleID: "pm", workingRoleIDs: ["pm", "tl"]),
            "pm",
            "A working role must receive a role-targeted queue entry"
        )
    }

    /// When the resolved role is NOT working — the paused/failed resume case, where the
    /// recipient is just `candidateRoles.first` — queue untargeted (`nil`) so whichever
    /// role resumes consumes it, instead of mis-targeting an arbitrary role.
    func testQueueTarget_nonWorkingRole_returnsNilForTeamWideDelivery() {
        XCTAssertNil(
            TeamActivityComposer.queueTarget(roleID: "pm", workingRoleIDs: []),
            "No working role → untargeted queue so any resuming role picks it up"
        )
        XCTAssertNil(
            TeamActivityComposer.queueTarget(roleID: "pm", workingRoleIDs: ["tl"]),
            "Resolved role isn't among the working set → untargeted"
        )
    }

    // MARK: - placeholderText

    func testPlaceholderText_workingRole_saysQueue() {
        let pm = normalRole(id: "pm", name: "PM")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(recipient: .role(id: "pm"), workingRoleIDs: ["pm"], roleDefinitions: [pm]),
            "Queue a message for PM…")
    }

    func testPlaceholderText_nonWorkingRole_saysSend() {
        // Paused/failed resume: resolved role isn't working → message queues untargeted.
        let pm = normalRole(id: "pm", name: "PM")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(recipient: .role(id: "pm"), workingRoleIDs: [], roleDefinitions: [pm]),
            "Send a message to PM…")
    }

    func testPlaceholderText_answer_saysAnswer() {
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(recipient: .answer(stepID: "pm"), workingRoleIDs: [], roleDefinitions: []),
            "Answer…")
    }

    func testPlaceholderText_nilRecipient_explainsNoRecipient() {
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(recipient: nil, workingRoleIDs: [], roleDefinitions: []),
            "No active recipient — accept, restart a role, or request changes.")
    }

    func testPlaceholderText_failedRole_saysRetry() {
        let tpm = normalRole(id: "tpm", name: "TPM")
        let pm = normalRole(id: "pm", name: "PM")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "tpm"), workingRoleIDs: [],
                failedRoleIDs: ["tpm"], roleDefinitions: [pm, tpm]
            ),
            "Send a message to TPM to retry…")
    }

    func testPlaceholderText_multiRoleFallback_isRoleAgnostic() {
        // Paused multi-role resume: recipient is an arbitrary candidateRoles.first, so the
        // placeholder must NOT name it (that was the original "Send a message to Product
        // Manager…" bug). A single-role team still names its sole role (covered above).
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "pm"), workingRoleIDs: [],
                failedRoleIDs: [], roleDefinitions: [pm, tl]
            ),
            "Send a message…")
    }

    // MARK: - placeholderText — transitions (the string is load-bearing when it CHANGES)

    /// Transition pin; the AppKit half is `EditableMessageTextViewTests.
    /// testPlaceholder_changedWhileEmpty_invalidatesDisplay`. Every other
    /// `placeholderText` test asserts ONE state, but the string matters precisely
    /// when it changes under an empty composer — that is the only on-screen signal
    /// that an inert composer went live. The reported case: nothing working yet, so
    /// the composer reads "No active recipient — accept, restart a role, or request
    /// changes."; the engine then starts the role and the recipient resolves.
    /// Driven through `resolveEffectiveRecipient` so a change on either side of the
    /// pair has to be deliberate.
    func testPlaceholderText_noRecipientToWorkingRole_stringChanges() {
        let marketolog = normalRole(id: "marketolog", name: "Marketolog")
        let writer = normalRole(id: "writer", name: "Writer")
        let roles = [marketolog, writer]

        let before = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [], candidateRoles: roles, allowsRoleFallback: false
        )
        XCTAssertNil(before, "Nothing working + fallback disallowed → composer inert.")
        let beforeText = TeamActivityComposer.placeholderText(
            recipient: before, workingRoleIDs: [], roleDefinitions: roles)

        let after = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [marketolog], candidateRoles: roles, allowsRoleFallback: false
        )
        XCTAssertEqual(after, .role(id: "marketolog"))
        let afterText = TeamActivityComposer.placeholderText(
            recipient: after, workingRoleIDs: ["marketolog"], roleDefinitions: roles)

        XCTAssertEqual(beforeText, "No active recipient — accept, restart a role, or request changes.")
        XCTAssertEqual(afterText, "Queue a message for Marketolog…")
        XCTAssertNotEqual(
            beforeText, afterText,
            "The placeholder is the composer's only 'you can type now' signal while the field is empty — these two states must never collapse to the same string.")
    }

    /// Sweep: the states one role walks through during a run must each produce a
    /// DISTINCT placeholder. Any pair collapsing to the same string makes that
    /// transition invisible in an empty composer — and no repaint would even be
    /// requested, since `EditableNSTextView.placeholderText`'s `didSet` is
    /// `!= oldValue`-guarded.
    func testPlaceholderText_lifecycleStates_allDistinct() {
        let swe = normalRole(id: "swe", name: "SWE")
        let pm = normalRole(id: "pm", name: "PM")
        let roles = [swe, pm]
        let texts = [
            TeamActivityComposer.placeholderText(
                recipient: nil, workingRoleIDs: [], roleDefinitions: roles),
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "swe"), workingRoleIDs: ["swe"], roleDefinitions: roles),
            TeamActivityComposer.placeholderText(
                recipient: .answer(stepID: "swe"), workingRoleIDs: [], roleDefinitions: roles),
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "swe"), workingRoleIDs: [],
                failedRoleIDs: ["swe"], roleDefinitions: roles),
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "swe"), workingRoleIDs: [],
                failedRoleIDs: [], roleDefinitions: roles)
        ]
        XCTAssertEqual(
            Set(texts).count, texts.count,
            "no-recipient / working / asking / failed-retry / resume placeholders must all differ — a collapsed pair makes the state transition invisible in an empty composer: \(texts)")
    }

    // MARK: - queuedRoleInfoMessage

    func testQueuedRoleInfoMessage_workingRole_targetedWording() {
        XCTAssertEqual(
            TeamActivityComposer.queuedRoleInfoMessage(roleName: "PM", isWorking: true),
            "Queued for PM — will deliver on the next request.")
    }

    func testQueuedRoleInfoMessage_nonWorkingRole_resumingWording() {
        XCTAssertEqual(
            TeamActivityComposer.queuedRoleInfoMessage(roleName: "PM", isWorking: false),
            "Message queued — resuming the task; it'll be picked up on the next request.")
    }

    // MARK: - Multi-candidate, none working: done/review vs resumable

    /// Done/awaiting-review (`.needsAcceptance`, screenshot case): a multi-role team with NO
    /// working role, no question, no failed role, and fallback disallowed → the resolver
    /// returns `nil` (composer inert) AND no chip is rendered. The two sides agree.
    func testMultiCandidateNoneWorking_done_resolverNil_andNoChip() {
        let a = normalRole(id: "a", name: "Engineer")
        let b = normalRole(id: "b", name: "Designer")

        let resolved = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],            // none working
            candidateRoles: [a, b],
            allowsRoleFallback: false       // .needsAcceptance
        )
        XCTAssertNil(resolved,
                     "Done/awaiting-review → no recipient (no arbitrary role named), composer disabled")

        let chips = TeamActivityComposer.computeChipOptions(
            roles: [a, b], workingRoleIDs: [], activeQuestions: []
        )
        XCTAssertTrue(chips.isEmpty,
                      "No chip rendered for >1 candidate with none working / none failed")
    }

    /// Failed multi-role team: a chip is emitted for the failed role (retry target), and the
    /// resolver names it — so the screenshot's "Send a message to <arbitrary role>" never
    /// happens on a failed task either.
    func testFailedRole_emitsRetryChip_andResolves() {
        let pm = normalRole(id: "pm", name: "PM")
        let tpm = normalRole(id: "tpm", name: "TPM")

        let chips = TeamActivityComposer.computeChipOptions(
            roles: [pm, tpm], workingRoleIDs: [], failedRoleIDs: ["tpm"], activeQuestions: []
        )
        XCTAssertEqual(chips.map(\.recipient), [.role(id: "tpm")],
                       "Failed role gets its own retry chip")
        XCTAssertEqual(chips.first?.icon, "arrow.clockwise",
                       "Retry chip uses the retry glyph")
    }

    // MARK: - computeSelectableRoles — all filters in one team

    func testComputeSelectableRoles_complexTeam_allFiltersApplied() {
        let supervisor = supervisorRole()
        let observer = observerRole(id: "obs")
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        let eng = normalRole(id: "eng", name: "Eng")

        let result = TeamActivityComposer.computeSelectableRoles(
            roles: [supervisor, observer, pm, tl, eng],
            workingRoleIDs: ["pm", "tl"],   // eng is idle
            askingRoleIDs: ["pm"]           // pm is asking
        )
        XCTAssertEqual(result.map(\.id), ["tl"],
                       "Only TL passes all four filters: not supervisor, not observer, working, not asking")
    }

    // MARK: - Corner cases: resolver priority interactions

    func testResolver_questionBeatsFailed() {
        // A failed role AND a pending question coexist (a sibling asked before another failed).
        // Answer must win — it's higher priority than retry.
        let tpm = normalRole(id: "tpm")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil,
            activeQuestions: [question(stepID: "pm")],
            selectableRoles: [],
            failedRoles: [tpm],
            candidateRoles: [tpm],
            allowsRoleFallback: true
        )
        XCTAssertEqual(result, .answer(stepID: "pm"),
                       "Pending question outranks a failed-role retry target")
    }

    func testResolver_workingBeatsFailed() {
        // One role still working while another failed → live steering of the working role
        // outranks retrying the failed one.
        let working = normalRole(id: "eng")
        let failed = normalRole(id: "cr")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [working],
            failedRoles: [failed],
            candidateRoles: [working, failed],
            allowsRoleFallback: true
        )
        XCTAssertEqual(result, .role(id: "eng"),
                       "Working role outranks failed role")
    }

    func testResolver_failedResolvesEvenWhenFallbackDisallowed() {
        // Defensive: a failed role is reachable regardless of `allowsRoleFallback` (the failed
        // branch precedes the gate) — the composer is always shown on `.failed`, so the retry
        // target must always resolve. (In practice a failed role ⟹ engine `.failed` ⟹
        // allowsRoleFallback true; pin the independence so a flag change can't strand retry.)
        let tpm = normalRole(id: "tpm")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],
            failedRoles: [tpm],
            candidateRoles: [tpm],
            allowsRoleFallback: false
        )
        XCTAssertEqual(result, .role(id: "tpm"))
    }

    func testResolver_explicitSelectionBeatsFailed() {
        let pm = normalRole(id: "pm")
        let tpm = normalRole(id: "tpm")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: .role(id: "pm"),
            activeQuestions: [],
            selectableRoles: [],
            failedRoles: [tpm],
            candidateRoles: [pm, tpm],
            allowsRoleFallback: true
        )
        XCTAssertEqual(result, .role(id: "pm"),
                       "Explicit pick overrides the failed-role auto-resolution")
    }

    // MARK: - Corner cases: computeChipOptions with failed roles

    func testChipOptions_orderAnswerThenWorkingThenFailed() {
        let asker = normalRole(id: "pm", name: "PM")
        let working = normalRole(id: "eng", name: "Eng")
        let failed = normalRole(id: "cr", name: "CR")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [asker, working, failed],
            workingRoleIDs: ["eng"],
            failedRoleIDs: ["cr"],
            activeQuestions: [TeamActivityActiveQuestion(stepID: "pm", role: .productManager, question: "?")]
        )
        XCTAssertEqual(options.map(\.recipient),
                       [.answer(stepID: "pm"), .role(id: "eng"), .role(id: "cr")],
                       "Chip order: Answer chips, then working roles, then failed roles")
    }

    func testChipOptions_roleBothWorkingAndFailed_noDuplicateChip() {
        // Defensive: a role can't really be both, but if the two sets overlap, emit only the
        // working chip — the `where !workingRoleIDs.contains` guard prevents a duplicate.
        let role = normalRole(id: "x", name: "X")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [role], workingRoleIDs: ["x"], failedRoleIDs: ["x"], activeQuestions: []
        )
        XCTAssertEqual(options.map(\.recipient), [.role(id: "x")],
                       "No duplicate chip when a role appears in both working and failed sets")
        XCTAssertEqual(options.first?.icon, "person.fill",
                       "The working chip (role icon) wins, not the retry glyph")
    }

    func testChipOptions_failedSupervisorAndObserverExcluded() {
        let sup = supervisorRole()
        let obs = observerRole(id: "obs")
        let real = normalRole(id: "swe", name: "SWE")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [sup, obs, real],
            workingRoleIDs: [],
            failedRoleIDs: ["supervisor", "obs", "swe"],
            activeQuestions: []
        )
        XCTAssertEqual(options.map(\.recipient), [.role(id: "swe")],
                       "Failed chips skip supervisor + observer roles")
    }

    func testChipOptions_failedRoleAlsoAsking_answerChipWins_noRetryChip() {
        // The failed role is also the one asking → it gets an Answer chip, NOT a retry chip
        // (an answer resolves the wait; a blind retry would fight it).
        let role = normalRole(id: "cr", name: "CR")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [role],
            workingRoleIDs: [],
            failedRoleIDs: ["cr"],
            activeQuestions: [TeamActivityActiveQuestion(stepID: "cr", role: .productManager, question: "?")]
        )
        XCTAssertEqual(options.map(\.recipient), [.answer(stepID: "cr")],
                       "An asking-and-failed role surfaces only its Answer chip")
    }

    func testChipOptions_multipleFailed_emitsRetryChipPerRole_inOrder() {
        let a = normalRole(id: "a", name: "A")
        let b = normalRole(id: "b", name: "B")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [a, b], workingRoleIDs: [], failedRoleIDs: ["a", "b"], activeQuestions: []
        )
        XCTAssertEqual(options.map(\.recipient), [.role(id: "a"), .role(id: "b")],
                       "One retry chip per failed role, in role order")
    }

    func testChipOptions_failedChipSuppressesSingleCandidateFallback() {
        // A two-role team with one failed + one idle candidate, chat/resumable: the failed
        // chip is present so the single-candidate fallback must NOT also fire (it would
        // double-offer / the guard checks alreadyHasRoleChip). Only the failed chip shows.
        let failed = normalRole(id: "cr", name: "CR")
        let idle = normalRole(id: "pm", name: "PM")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [failed, idle],
            workingRoleIDs: [],
            failedRoleIDs: ["cr"],
            activeQuestions: [],
            allowsRoleFallback: true
        )
        XCTAssertEqual(options.map(\.recipient), [.role(id: "cr")],
                       "Failed chip present ⇒ single-candidate fallback suppressed (>1 candidate anyway)")
    }

    // MARK: - Corner cases: placeholderText precedence

    func testPlaceholder_workingBeatsFailed() {
        let role = normalRole(id: "x", name: "X")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "x"), workingRoleIDs: ["x"],
                failedRoleIDs: ["x"], roleDefinitions: [role]
            ),
            "Queue a message for X…",
            "Working wording outranks failed wording when a role is somehow in both")
    }

    func testPlaceholder_singleFailedRoleSaysRetry_notNamedSend() {
        // Even in a one-role team, a failed role says "to retry…", not the plain single-role wording.
        let role = normalRole(id: "swe", name: "SWE")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "swe"), workingRoleIDs: [],
                failedRoleIDs: ["swe"], roleDefinitions: [role]
            ),
            "Send a message to SWE to retry…")
    }

    func testPlaceholder_supervisorRoleDefDoesNotInflateCount_namesSoleWorker() {
        // roleDefinitions may include the Supervisor role def. A single *worker* team must
        // still take the named single-role branch (count of non-supervisor roles == 1).
        let sup = supervisorRole()
        let swe = normalRole(id: "swe", name: "SWE")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "swe"), workingRoleIDs: [],
                failedRoleIDs: [], roleDefinitions: [sup, swe]
            ),
            "Send a message to SWE…",
            "Supervisor role def must not push a single-worker team into the role-agnostic branch")
    }

    func testPlaceholder_multiWorkerWithUnrelatedFailedRole_isRoleAgnostic() {
        // Recipient is an idle non-failed candidate while a DIFFERENT role is failed; multi
        // worker → role-agnostic wording (never names the arbitrary recipient).
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "pm"), workingRoleIDs: [],
                failedRoleIDs: ["tl"], roleDefinitions: [pm, tl]
            ),
            "Send a message…")
    }

    /// Sibling of `testPlaceholder_supervisorRoleDefDoesNotInflateCount_namesSoleWorker`.
    /// Observers are excluded from `computeCandidateRoles`/`computeSelectableRoles`
    /// everywhere else, so a team of {one worker, one observer} has exactly ONE
    /// messageable role and must take the named single-role branch. Counting the
    /// observer pushes it into the role-agnostic wording while the chip row is
    /// simultaneously naming that same sole worker.
    func testPlaceholder_observerRoleDefDoesNotInflateCount_namesSoleWorker() {
        let obs = observerRole(id: "obs")
        let swe = normalRole(id: "swe", name: "SWE")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "swe"), workingRoleIDs: [],
                failedRoleIDs: [], roleDefinitions: [obs, swe]
            ),
            "Send a message to SWE…",
            "An observer is never a messageable role, so it must not push a single-worker team into the role-agnostic branch")
    }

    func testPlaceholder_supervisorAndObserversTogether_stillNamesSoleWorker() {
        let sup = supervisorRole()
        let swe = normalRole(id: "swe", name: "SWE")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "swe"), workingRoleIDs: [],
                failedRoleIDs: [],
                roleDefinitions: [sup, observerRole(id: "o1"), observerRole(id: "o2"), swe]
            ),
            "Send a message to SWE…",
            "Neither the Supervisor nor any number of observers is a messageable role")
    }

    /// Cross-surface pin — the chip row and the placeholder must agree on whether
    /// the recipient is nameable. Whenever `computeChipOptions` emits exactly one
    /// role chip through the single-candidate fallback, it labels that chip with
    /// the role's name; the placeholder is then the only other thing on screen and
    /// must not refuse to name the very role the chip just named. Catches the whole
    /// class rather than the observer instance: any future divergence between the
    /// two "who counts as a role" filters fails here.
    func testPlaceholder_singleCandidateFallbackChip_andPlaceholderNameTheSameRole() {
        let roles = [supervisorRole(), observerRole(id: "obs"), normalRole(id: "swe", name: "SWE")]
        let options = TeamActivityComposer.computeChipOptions(
            roles: roles, workingRoleIDs: [], failedRoleIDs: [],
            activeQuestions: [], allowsRoleFallback: true
        )
        XCTAssertEqual(options.map(\.label), ["SWE"],
                       "Precondition: exactly one named fallback chip.")

        let recipient = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [], selectableRoles: [],
            candidateRoles: TeamActivityComposer.computeCandidateRoles(roles: roles, askingRoleIDs: []),
            allowsRoleFallback: true
        )
        XCTAssertEqual(recipient, .role(id: "swe"))

        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: recipient, workingRoleIDs: [], roleDefinitions: roles),
            "Send a message to SWE…",
            "The chip names this role — the placeholder beside it must not go role-agnostic.")
    }

    /// `.answer` short-circuits before any role lookup, so neither status set can
    /// colour the wording. Pinned because the working/failed branches sit directly
    /// below it and an accidental reorder would be invisible in the single-state tests.
    func testPlaceholder_answerRecipient_ignoresWorkingAndFailedSets() {
        let role = normalRole(id: "pm", name: "PM")
        for working in [Set<String>(), ["pm"]] {
            for failed in [Set<String>(), ["pm"]] {
                XCTAssertEqual(
                    TeamActivityComposer.placeholderText(
                        recipient: .answer(stepID: "pm"), workingRoleIDs: working,
                        failedRoleIDs: failed, roleDefinitions: [role]
                    ),
                    "Answer…",
                    "Answering outranks every role-status wording (working: \(working), failed: \(failed))")
            }
        }
    }

    /// Degenerate input: the roster hasn't resolved (empty) while a recipient is
    /// held. The name falls back to the raw id, and an empty roster trivially
    /// satisfies the single-role branch — so the wording names the id rather than
    /// rendering an empty gap.
    func testPlaceholder_emptyRoleDefinitions_namesTheRawID() {
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "swe"), workingRoleIDs: [], roleDefinitions: []),
            "Send a message to swe…")
    }

    // MARK: - computeFailedRoles — shared filter (resolver ↔ chips single source of truth)

    func testComputeFailedRoles_filtersSupervisorObserverAndAskers() {
        let sup = supervisorRole()
        let obs = observerRole(id: "obs")
        let asking = normalRole(id: "cr", name: "CR")
        let real = normalRole(id: "swe", name: "SWE")
        let result = TeamActivityComposer.computeFailedRoles(
            roles: [sup, obs, asking, real],
            failedRoleIDs: ["supervisor", "obs", "cr", "swe"],
            askingRoleIDs: ["cr"]
        )
        XCTAssertEqual(result.map(\.id), ["swe"],
                       "Failed-role filter drops supervisor, observer, and asking roles")
    }

    func testComputeFailedRoles_onlyFailedIDs() {
        let a = normalRole(id: "a")
        let b = normalRole(id: "b")
        let result = TeamActivityComposer.computeFailedRoles(
            roles: [a, b], failedRoleIDs: ["b"], askingRoleIDs: []
        )
        XCTAssertEqual(result.map(\.id), ["b"])
    }

    // MARK: - allowsRoleFallback — engine-state → Bool mapping (the inert/retry fix)

    func testAllowsRoleFallback_chatModeAlwaysTrue() {
        // Chat is always messageable, regardless of engine state (incl. .needsAcceptance,
        // which chat teams don't actually reach, and .done after a restart).
        for state: TeamEngineState? in [.pending, .running, .paused, .needsAcceptance,
                                        .needsSupervisorInput, .done, .failed, nil] {
            XCTAssertTrue(
                TeamActivityFeedView.allowsRoleFallback(isChatMode: true, engineState: state),
                "Chat mode must allow the role fallback in every engine state (state: \(String(describing: state)))")
        }
    }

    func testAllowsRoleFallback_nonChat_resumableStatesTrue() {
        for state: TeamEngineState in [.paused, .pending, .failed] {
            XCTAssertTrue(
                TeamActivityFeedView.allowsRoleFallback(isChatMode: false, engineState: state),
                "Resumable-by-send state \(state) must allow the candidate fallback")
        }
    }

    func testAllowsRoleFallback_nonChat_inertStatesFalse() {
        // .needsAcceptance is the screenshot bug; .running(transient no-working gap) and
        // .done must also stay inert; nil (no engine) → false.
        for state: TeamEngineState? in [.needsAcceptance, .running, .needsSupervisorInput, .done, nil] {
            XCTAssertFalse(
                TeamActivityFeedView.allowsRoleFallback(isChatMode: false, engineState: state),
                "Non-chat \(String(describing: state)) must NOT name an arbitrary role (composer inert)")
        }
    }

    // MARK: - Corner cases: remaining resolver branch interactions

    func testResolver_questionBeatsWorkingRole() {
        // A role is working AND a (different) role has a pending question. Answer outranks
        // live steering — pin the priority since both branches are "active role" candidates.
        let working = normalRole(id: "eng")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil,
            activeQuestions: [question(stepID: "pm")],
            selectableRoles: [working],
            candidateRoles: [working],
            allowsRoleFallback: true
        )
        XCTAssertEqual(result, .answer(stepID: "pm"),
                       "Pending question outranks a working role")
    }

    func testResolver_multipleFailed_picksFirst() {
        let a = normalRole(id: "a")
        let b = normalRole(id: "b")
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],
            failedRoles: [a, b],
            candidateRoles: [a, b],
            allowsRoleFallback: true
        )
        XCTAssertEqual(result, .role(id: "a"),
                       "First failed role is the retry target (matches the leftmost retry chip)")
    }

    func testResolver_fallbackAllowedButNoCandidates_returnsNil() {
        // Resumable state but every candidate was filtered out (all asking/supervisor/observer).
        // The gate is permissive but there's literally nothing to resolve to → nil.
        let result = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],
            failedRoles: [],
            candidateRoles: [],
            allowsRoleFallback: true
        )
        XCTAssertNil(result,
                     "allowsRoleFallback can't conjure a recipient from an empty candidate set")
    }

    // MARK: - Corner cases: resolver ↔ chips documented asymmetry

    /// Multi-candidate, resumable (`.paused`/`.pending`), nothing working/failed/asking:
    /// the resolver returns the first candidate (so the run can be resumed by sending) while
    /// the chip row stays EMPTY (the single-candidate fallback fires only for exactly one
    /// candidate). This asymmetry is intentional — there's no chip to mis-tap, the placeholder
    /// is role-agnostic, and the send queues untargeted + resumes. Pin it so a future change
    /// to either side is a conscious decision.
    func testAsymmetry_multiCandidatePausedResume_resolverResolves_chipRowEmpty() {
        let a = normalRole(id: "a", name: "Engineer")
        let b = normalRole(id: "b", name: "Designer")

        let resolved = TeamActivityComposer.resolveEffectiveRecipient(
            selected: nil, activeQuestions: [],
            selectableRoles: [],
            failedRoles: [],
            candidateRoles: [a, b],
            allowsRoleFallback: true
        )
        XCTAssertEqual(resolved, .role(id: "a"),
                       "Resumable multi-role → resolve to first candidate so send-to-resume works")

        let chips = TeamActivityComposer.computeChipOptions(
            roles: [a, b], workingRoleIDs: [], failedRoleIDs: [],
            activeQuestions: [], allowsRoleFallback: true
        )
        XCTAssertTrue(chips.isEmpty,
                      "No chip rendered for >1 candidate — the role-agnostic placeholder carries the intent")

        // And the placeholder for that resolved recipient is role-agnostic (no arbitrary name).
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: resolved, workingRoleIDs: [], failedRoleIDs: [], roleDefinitions: [a, b]
            ),
            "Send a message…")
    }

    // MARK: - Corner cases: chips with a pending question + fallback

    func testChipOptions_questionPlusSingleIdleCandidate_fallback_emitsAnswerThenFallbackChip() {
        // One role asking, one OTHER role idle, resumable/chat: the answer chip leads and the
        // lone idle candidate still earns a fallback chip (the asker is excluded from candidates).
        let asker = normalRole(id: "pm", name: "PM")
        let idle = normalRole(id: "tl", name: "TL")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [asker, idle],
            workingRoleIDs: [],
            failedRoleIDs: [],
            activeQuestions: [TeamActivityActiveQuestion(stepID: "pm", role: .productManager, question: "?")],
            allowsRoleFallback: true
        )
        XCTAssertEqual(options.map(\.recipient), [.answer(stepID: "pm"), .role(id: "tl")],
                       "Answer chip + single-candidate fallback for the remaining idle role")
    }

    func testChipOptions_questionPlusMultipleCandidates_fallback_onlyAnswerChips() {
        // Question + >1 remaining candidate, resumable/chat: only the answer chip(s) — the
        // single-candidate fallback needs exactly one candidate, so no role chip is added.
        let asker = normalRole(id: "pm", name: "PM")
        let c1 = normalRole(id: "tl", name: "TL")
        let c2 = normalRole(id: "eng", name: "Eng")
        let options = TeamActivityComposer.computeChipOptions(
            roles: [asker, c1, c2],
            workingRoleIDs: [],
            failedRoleIDs: [],
            activeQuestions: [TeamActivityActiveQuestion(stepID: "pm", role: .productManager, question: "?")],
            allowsRoleFallback: true
        )
        XCTAssertEqual(options.map(\.recipient), [.answer(stepID: "pm")],
                       "Multiple candidates ⇒ no single-candidate fallback chip; only the answer chip")
    }

    // MARK: - Corner cases: misc helper edges

    func testComputeFailedRoles_emptyFailedIDs_returnsEmpty() {
        let a = normalRole(id: "a")
        XCTAssertTrue(
            TeamActivityComposer.computeFailedRoles(roles: [a], failedRoleIDs: [], askingRoleIDs: []).isEmpty)
    }

    func testPlaceholder_unknownRecipientID_fallsBackToID() {
        // recipient references a role not in roleDefinitions (e.g. a stale id mid-transition):
        // name falls back to the id, and the empty roster's non-supervisor count is 0 (≤1) so
        // it takes the named single-role branch rather than crashing or going agnostic.
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "ghost"), workingRoleIDs: [],
                failedRoleIDs: [], roleDefinitions: []
            ),
            "Send a message to ghost…")
    }

    func testPlaceholder_multiWorkingRole_saysQueue() {
        // The working branch doesn't depend on team size — a working role in a multi-role team
        // still says "Queue a message for X…".
        let pm = normalRole(id: "pm", name: "PM")
        let tl = normalRole(id: "tl", name: "TL")
        XCTAssertEqual(
            TeamActivityComposer.placeholderText(
                recipient: .role(id: "pm"), workingRoleIDs: ["pm", "tl"],
                failedRoleIDs: [], roleDefinitions: [pm, tl]
            ),
            "Queue a message for PM…")
    }

    // MARK: - BashApprovalCardList.sortedRequests (held-command cards)

    private func bashRequest(taskID: Int, stepID: String, command: String, at: Date) -> BashApprovalRequest {
        BashApprovalRequest(
            taskID: taskID, stepID: stepID, commandKey: "key:\(command)", command: command,
            workingDirectory: nil, offerAlways: false, createdAt: at)
    }

    func testSortedRequests_filtersByTaskAndOrdersByCreatedAt() {
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        let t2 = Date(timeIntervalSince1970: 300)
        let all: [TaskStepKey: BashApprovalRequest] = [
            TaskStepKey(taskID: 1, stepID: "b"): bashRequest(taskID: 1, stepID: "b", command: "later", at: t2),
            TaskStepKey(taskID: 1, stepID: "a"): bashRequest(taskID: 1, stepID: "a", command: "earlier", at: t1),
            TaskStepKey(taskID: 2, stepID: "c"): bashRequest(taskID: 2, stepID: "c", command: "other", at: t0),
        ]
        // Only task 1's requests, oldest-first — NOT the globally-oldest task-2 entry.
        XCTAssertEqual(
            BashApprovalCardList.sortedRequests(for: 1, from: all).map(\.command),
            ["earlier", "later"])
        XCTAssertEqual(
            BashApprovalCardList.sortedRequests(for: 2, from: all).map(\.command),
            ["other"])
    }

    func testSortedRequests_noMatch_isEmpty() {
        let all: [TaskStepKey: BashApprovalRequest] = [
            TaskStepKey(taskID: 1, stepID: "a"):
                bashRequest(taskID: 1, stepID: "a", command: "ls", at: Date(timeIntervalSince1970: 1)),
        ]
        XCTAssertTrue(BashApprovalCardList.sortedRequests(for: 99, from: all).isEmpty)
        XCTAssertTrue(BashApprovalCardList.sortedRequests(for: 1, from: [:]).isEmpty)
    }
}
