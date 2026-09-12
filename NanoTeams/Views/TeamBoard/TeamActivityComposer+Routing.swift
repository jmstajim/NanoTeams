import SwiftUI

// MARK: - Pure Routing Helpers (unit-testable)

extension TeamActivityComposer {

    /// The two routing answers a body pass needs, derived together — see `computeRouting`.
    nonisolated struct Routing: Equatable {
        let chipOptions: [ChipOption]
        let effectiveRecipient: Recipient?
    }

    /// Banner to surface to `lastErrorMessage` when some files failed inline embedding.
    /// `AnswerTextBuilder.build` falls back to path-attachment when inline embed fails,
    /// so the files ARE still delivered — the wording must signal that, otherwise users
    /// assume the files were lost. Returns `nil` for the empty case so callers can
    /// unconditionally check `if let banner = …`.
    static func bannerForFailedFiles(_ failedFiles: [String]) -> String? {
        guard !failedFiles.isEmpty else { return nil }
        return "Could not embed \(failedFiles.count) file(s) inline — attached as paths: \(failedFiles.joined(separator: ", "))."
    }

    /// Auto-selects the effective recipient when the user hasn't explicitly chosen one.
    /// Priority order matches the chip row's left-to-right order, so "the first chip
    /// is always selected" holds when there is no explicit pick:
    /// 1. Explicit selection wins.
    /// 2. If any question is pending → `.answer(stepID:)` for the AIMED one, which with no
    ///    aim is the FIRST (Answer chips are leftmost in the row, in input order). The aim is
    ///    `SupervisorAnswerFocus.resolve` — the same rule Quick Capture applies to its own
    ///    pick, so both surfaces honour a preference only while that question is still
    ///    waiting and fall back to the leader the instant it stops.
    /// 3. Otherwise the first selectable (working) role — matches the next chip in the row.
    /// 4. Otherwise the first `.failed` role — the retry target (named; chip emitted).
    /// 5. Otherwise, when `allowsRoleFallback` (chat / resumable-by-send state), the first
    ///    candidate role — so an idle chat team or a paused/pending/failed multi-role team
    ///    can still send. The gate is uniform across single- AND multi-candidate: a
    ///    single-role *non-chat* team awaiting acceptance (e.g. Startup) must NOT resolve to
    ///    its sole role (sending there is a no-op), so it falls through to `nil`.
    /// 6. Otherwise `nil` — `.needsAcceptance` and transient gaps: no recipient, the chip
    ///    row collapses, `canSubmit` is false (composer inert instead of naming a role).
    static func resolveEffectiveRecipient(
        selected: Recipient?,
        aimedStepID: String? = nil,
        activeQuestions: [TeamActivityActiveQuestion],
        selectableRoles: [TeamRoleDefinition],
        failedRoles: [TeamRoleDefinition] = [],
        candidateRoles: [TeamRoleDefinition],
        allowsRoleFallback: Bool = false
    ) -> Recipient? {
        if let explicit = selected { return explicit }
        if let aimed = SupervisorAnswerFocus.resolve(
            preferred: aimedStepID, among: activeQuestions.map(\.stepID)
        ) {
            return .answer(stepID: aimed)
        }
        if let first = selectableRoles.first { return .role(id: first.id) }
        if let first = failedRoles.first { return .role(id: first.id) }
        if allowsRoleFallback, let first = candidateRoles.first { return .role(id: first.id) }
        return nil
    }

    /// Queue target for the `.role` submit branch. Deliver to the role only when it's
    /// currently working (live-role steering). When no role is working — a paused/failed
    /// resume, or an idle team between chat turns, where the resolved recipient is just
    /// `candidateRoles.first` — return `nil` so the message is queued untargeted and
    /// consumed by whichever role resumes, rather than mis-targeted to an arbitrary role.
    static func queueTarget(roleID: String, workingRoleIDs: Set<String>) -> String? {
        workingRoleIDs.contains(roleID) ? roleID : nil
    }

    /// Confirmation banner for a queued `.role` submit. Working role → targeted-delivery
    /// wording; non-working role (paused/failed resume, or an idle team between chat turns)
    /// → "resuming the task" wording, since the message queues untargeted and rides the
    /// resumed run.
    static func queuedRoleInfoMessage(roleName: String, isWorking: Bool) -> String {
        isWorking
            ? "Queued for \(roleName) — will deliver on the next request."
            : "Message queued — resuming the task; it'll be picked up on the next request."
    }

    /// Placeholder shown in the composer's text field:
    /// - `.answer` → "Answer…"
    /// - `.role(X)` where X is working → "Queue a message for X…" (targeted live steering)
    /// - `.role(X)` where X is failed → "Send a message to X to retry…" (resume path)
    /// - `.role(X)` in a single-role team → "Send a message to X…" (chat, named)
    /// - `.role` multi-role fallback (paused/chat resume) → "Send a message…"
    ///   (role-agnostic — the resolved id is just `candidateRoles.first`, never surfaced)
    /// - `nil` → the no-recipient hint (composer inert).
    static func placeholderText(
        recipient: Recipient?,
        workingRoleIDs: Set<String>,
        failedRoleIDs: Set<String> = [],
        roleDefinitions: [TeamRoleDefinition]
    ) -> String {
        switch recipient {
        case .answer:
            return "Answer…"
        case .role(let id):
            let name = roleDefinitions.first(where: { $0.id == id })?.name ?? id
            if workingRoleIDs.contains(id) { return "Queue a message for \(name)…" }
            if failedRoleIDs.contains(id) { return "Send a message to \(name) to retry…" }
            // Single-role team (e.g. chat assistant idle between turns): name the role.
            // Otherwise the recipient is an arbitrary `candidateRoles.first` resume target —
            // stay role-agnostic so the composer never names a role the user didn't pick.
            // Counted through `isMessageableRole` so this agrees with the chip row: when
            // exactly one role is addressable the fallback chip names it, and a placeholder
            // that went role-agnostic there would contradict the chip beside it.
            if roleDefinitions.count(where: isMessageableRole) <= 1 {
                return "Send a message to \(name)…"
            }
            return "Send a message…"
        case nil:
            return "No active recipient — accept, restart a role, or request changes."
        }
    }

    /// Pure submit-gate. The composer can submit when there is content (text,
    /// attachment, clip, or a questionnaire with something ticked) AND there is a recipient
    /// to deliver to. `nil` recipient means no chip is selectable (no question, no working
    /// role, no candidate) — submission is blocked.
    ///
    /// A ticked questionnaire with no prose beside it is a complete answer — the card IS the
    /// answer field there — so gating on text alone would leave the Supervisor looking at a
    /// filled-in form beside a dead send button.
    static func computeCanSubmit(
        text: String,
        hasAttachments: Bool,
        hasClips: Bool,
        hasInquiryAnswer: Bool = false,
        effectiveRecipient: Recipient?
    ) -> Bool {
        guard let effectiveRecipient else { return false }
        // A questionnaire is content for the ONE recipient that can carry one. A `.role` chip
        // queues a chat MESSAGE, and `queueChatMessage` refuses an empty one without a word —
        // so counting the ticks there lit a Send button whose every press did nothing, and the
        // `.role` branch would have dropped the answer on the way out anyway.
        let answersAQuestion: Bool
        if case .answer = effectiveRecipient { answersAQuestion = true } else { answersAQuestion = false }
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasAttachments
            || hasClips
            || (hasInquiryAnswer && answersAQuestion)
        return hasContent
    }

    /// Retargets a lost selection to the SAME underlying role under its other chip
    /// shape before the draft leaves the composer. For team tasks `StepExecution.id == roleID`,
    /// so `.role(id: X)` and `.answer(stepID: X)` address the same role/conversation —
    /// a role flipping working↔asking (the Autovisor's frequent running↔parked idle
    /// cycle) swaps one chip shape for the other, which would otherwise invalidate the
    /// explicit selection and take the in-progress draft out of the field (the "my message
    /// disappears" bug). Returns the still-present `prior`, else the same role's
    /// counterpart-shape recipient if present, else `nil` (genuinely gone — `recipientToPark`
    /// then decides). It subsumes the plain stale-selection drop this file used to spell
    /// beside it — with no counterpart in the row the two are the same function, and the
    /// simple one lost its last caller when the chip row's hover moved into
    /// `RecipientChipRow`, where a hover naming a departed chip matches nothing and needs no
    /// cleaning at all.
    ///
    /// The two shapes agreeing here and `AnswerDraftKey.role` keying on the same role id are
    /// one fact, not two: a reply and a queued message travel one branch of conversation.
    static func remapEquivalentRecipient(
        prior: Recipient?,
        availableRecipients: [Recipient]
    ) -> Recipient? {
        guard let prior else { return nil }
        if availableRecipients.contains(prior) { return prior }
        return availableRecipients.first { $0.roleID == prior.roleID }
    }

    /// The recipient whose half-written reply must be PARKED, because its chip left the row
    /// while the user was writing to it.
    ///
    /// Same three inputs the discard guard read and the same predicate — what changed is the
    /// verb. Discarding was the only option a composer with no draft store had, and it threw
    /// away work on an event the user did not cause and could not predict: a parallel role
    /// finishing, or the question being answered from Watchtower or Quick Capture. Now the
    /// text goes to `SupervisorAnswerDraftStore` under the lost recipient's branch and comes
    /// back as a row above the composer with "Return" and "Discard".
    ///
    /// Nil when the user never committed to a recipient (`prior == nil`): the resolver's
    /// first-chip auto-pick is still appropriate and there is nothing to protect. Nil with no
    /// content: an empty draft is not worth a row (`SupervisorAnswerDraftStore.save` would
    /// drop it anyway, but not offering it is cheaper than parking and un-parking it).
    static func recipientToPark(
        prior: Recipient?,
        sanitized: Recipient?,
        hasContent: Bool
    ) -> Recipient? {
        guard let prior, sanitized == nil, hasContent else { return nil }
        return prior
    }

    /// Post-submit reset contract. Pinned by
    /// `TeamActivityComposerRoutingTests.testClearedComposerState_*`:
    /// resets `selectedRecipient` AND the soft answer aim to nil along with
    /// text/attachments/clips/questionnaire.
    /// Without the recipient reset, a `.role` lock from a previous queue submit
    /// survives and the explicit-selection priority in
    /// `resolveEffectiveRecipient` keeps the stale chip dominant — even when
    /// a new `ask_supervisor` adds an Answer chip to `chipOptions`, the
    /// Answer chip never auto-selects, the placeholder stays "Queue a
    /// message…", and the user can't see they're answering until they
    /// manually click the new chip.
    static func clearedComposerState() -> (
        text: String,
        attachments: [StagedAttachment],
        clips: [String],
        inquiry: SupervisorInquiryDraft?,
        selectedRecipient: Recipient?,
        answerAim: String?
    ) {
        ("", [], [], nil, nil, nil)
    }

    /// The pending question the composer is aimed at, or nil when it is aimed at a role.
    ///
    /// `nonisolated static` so the pairing of a resolved recipient with its question — which is
    /// what decides WHICH questionnaire is on screen, and therefore which answers count as
    /// content and which are someone else's — is reachable from a test rather than spelled
    /// inside a view body.
    static func question(
        for recipient: Recipient?, among questions: [TeamActivityActiveQuestion]
    ) -> TeamActivityActiveQuestion? {
        guard case .answer(let stepID) = recipient else { return nil }
        return questions.first { $0.stepID == stepID }
    }

    // MARK: - The aim lock

    /// The recipient the composer is locked to once it stops being empty.
    ///
    /// Locking on the first CONTENT, not the first character. The rule exists because an
    /// unlocked composer re-resolves to `activeQuestions.first` on every pass, so an event the
    /// user did not cause — a parallel role parking (CLAUDE.md #45), the leading question
    /// answered from another surface — silently re-aims what they are writing. A questionnaire
    /// is content that can be produced with zero keystrokes, and a keystroke-only lock left
    /// exactly that content unaimed: `recipientToPark` needs a `prior` to park, so tick-only
    /// work was neither parked nor offered back.
    ///
    /// Idempotent by construction: once `prior` is non-nil this returns it unchanged, so it can
    /// be called from every content observer without racing them against each other.
    static func lockedRecipient(
        prior: Recipient?, auto: Recipient?, hasContent: Bool
    ) -> Recipient? {
        guard prior == nil, hasContent, let auto else { return prior }
        return auto
    }

    // MARK: - The row's two derived facts

    /// The chips holding an unsent reply nobody is editing — the dots.
    ///
    /// Derived once per body pass from the store's key list rather than asked per chip: a
    /// `contains` inside the `ForEach` is a linear scan per pill, and the set is the same
    /// answer for all of them.
    ///
    /// `.role(X)` and `.answer(X)` share ONE draft key by design, so a role's two chip shapes
    /// wear the same dot. That is not a rounding error: the reply parked when the role was
    /// asking IS the message waiting for it now that it is working, and a dot on one shape but
    /// not the other would say the draft evaporated when the chip changed clothes.
    static func unsentDraftRecipients(
        among recipients: [Recipient], taskID: Int, parked: [AnswerDraftKey]
    ) -> Set<Recipient> {
        guard !parked.isEmpty else { return [] }
        let keys = Set(parked)
        var dotted: Set<Recipient> = []
        for recipient in recipients where keys.contains(draftKey(taskID: taskID, recipient: recipient)) {
            dotted.insert(recipient)
        }
        return dotted
    }

    /// Where the composer aims after answering `answeredStepID` — a step id, deliberately
    /// NOT a `selectedRecipient`.
    ///
    /// The aim has to be expressed as a soft preference, because `selectedRecipient` means
    /// something else: it is the USER'S lock, it wins over every later question by
    /// construction (`resolveEffectiveRecipient`'s first line), and nothing releases it on
    /// grounds of an empty composer. Written there, an app-made aim outlived its question —
    /// answer that role's question from Quick Capture, let the role resume, and
    /// `remapEquivalentRecipient` retargets the lock to that role's `.role` chip, after which
    /// every later question got an Answer chip that never auto-selected and a Send button that
    /// queued a message to a role nobody had asked. As a preference it simply stops matching.
    ///
    /// Aiming RIGHT and not at the leader is the other half: clearing the selection lands on
    /// `activeQuestions.first`, the question the Supervisor deliberately stepped over on their
    /// way to this one — and lands there through a list that still contains the question just
    /// answered, because the mutation removing it has not landed yet.
    ///
    /// Nil when nothing else is waiting: the resolver is free to pick whatever chip remains.
    static func nextAimAfterAnswer(
        answeredStepID: String, among questions: [TeamActivityActiveQuestion]
    ) -> String? {
        SupervisorAnswerFocus.next(after: answeredStepID, among: questions.map(\.stepID))
    }

    /// Phase-ordered runner for the `.answer` branch of `handleSubmit`.
    /// `clear` MUST run synchronously before the `await` so SwiftUI's
    /// `.onChange(of: chipOptionsComputed.map(\.recipient))` reaction
    /// (which fires when the Answer chip disappears mid-submit) observes
    /// `hasContent=false` and doesn't fire the false-positive "recipient
    /// no longer waiting" banner for a successful submit. The rest of the
    /// body is self-evident; contract pinned by
    /// `TeamActivityComposerRoutingTests.testPerformAnswerSubmit_*`.
    static func performAnswerSubmit(
        snapshotText: String,
        snapshotAttachments: [StagedAttachment],
        snapshotClips: [String],
        clear: () -> Void,
        submit: () async -> Bool,
        restore: (String, [StagedAttachment], [String]) -> Void
    ) async {
        clear()
        let ok = await submit()
        if !ok {
            restore(snapshotText, snapshotAttachments, snapshotClips)
        }
    }

    /// Is this role addressable by the composer at all? The Supervisor is the user,
    /// and an observer never executes a step, so a message aimed at either would
    /// never be consumed. Single source of truth for every "which roles count"
    /// filter in this file — `placeholderText`'s single-role test used to spell the
    /// predicate itself and diverged by counting observers, which made the chip row
    /// name a sole worker the placeholder beside it refused to name.
    /// `nonisolated` because it is pure — two reads of a `nonisolated` Domain value — and
    /// because line 93 passes it as a FUNCTION VALUE to `filter`, which the mirror's
    /// `-swift-version 5` build rejects for a main-actor-isolated member (`call to main
    /// actor-isolated static method … in a synchronous nonisolated context`). The four
    /// `isMessageableRole($0)` call sites below are unaffected either way.
    nonisolated static func isMessageableRole(_ role: TeamRoleDefinition) -> Bool {
        !role.isSupervisor && !role.isObserver
    }

    /// Currently-working, messageable roles, excluding any role currently asking a
    /// Supervisor question (those roles have their own "Answer" chips).
    /// Only these are valid queue targets — queueing to an idle role would never flush.
    static func computeSelectableRoles(
        roles: [TeamRoleDefinition],
        workingRoleIDs: Set<String>,
        askingRoleIDs: Set<String>
    ) -> [TeamRoleDefinition] {
        roles.filter {
            isMessageableRole($0)
                && workingRoleIDs.contains($0.id)
                && !askingRoleIDs.contains($0.id)
        }
    }

    /// `.failed` roles eligible as a named retry target — non-supervisor, non-observer, not
    /// currently asking (askers route through their own Answer chip). Single source of truth
    /// shared by the instance `failedRoles` (which feeds `resolveEffectiveRecipient`) and
    /// `computeChipOptions`, so the resolver and the chip row can never disagree on which
    /// roles count as failed.
    static func computeFailedRoles(
        roles: [TeamRoleDefinition],
        failedRoleIDs: Set<String>,
        askingRoleIDs: Set<String>
    ) -> [TeamRoleDefinition] {
        roles.filter {
            failedRoleIDs.contains($0.id)
                && isMessageableRole($0)
                && !askingRoleIDs.contains($0.id)
        }
    }

    /// Every non-supervisor, non-observer role in the team, excluding the askers.
    /// Used as a fallback when no role is currently `.working` but we still want
    /// to offer a sensible chip (e.g. a one-role team whose sole role is idle
    /// between chat turns).
    static func computeCandidateRoles(
        roles: [TeamRoleDefinition],
        askingRoleIDs: Set<String>
    ) -> [TeamRoleDefinition] {
        roles.filter {
            isMessageableRole($0) && !askingRoleIDs.contains($0.id)
        }
    }

    /// Ordered chips: one Answer chip per pending question (in input order), then one per
    /// working role, then one per `.failed` role (retry target), with a single-candidate
    /// fallback for idle one-role teams. Returns `[]` when no recipient exists — the chip
    /// row collapses and `canSubmit` is false.
    static func computeChipOptions(
        roles: [TeamRoleDefinition],
        workingRoleIDs: Set<String>,
        failedRoleIDs: Set<String> = [],
        activeQuestions: [TeamActivityActiveQuestion],
        allowsRoleFallback: Bool = false
    ) -> [ChipOption] {
        let askingRoleIDs = Set(activeQuestions.map(\.askingRoleID))
        return chipOptions(
            roles: roles,
            workingRoleIDs: workingRoleIDs,
            activeQuestions: activeQuestions,
            allowsRoleFallback: allowsRoleFallback,
            selectable: computeSelectableRoles(
                roles: roles, workingRoleIDs: workingRoleIDs, askingRoleIDs: askingRoleIDs),
            failed: computeFailedRoles(
                roles: roles, failedRoleIDs: failedRoleIDs, askingRoleIDs: askingRoleIDs),
            candidates: computeCandidateRoles(roles: roles, askingRoleIDs: askingRoleIDs)
        )
    }

    /// The chip-assembly half of `computeChipOptions`, over role sets a caller has ALREADY
    /// derived. Split out so `computeRouting` can derive `askingRoleIDs` / `selectable` /
    /// `failed` / `candidates` once and feed both the chip row and the recipient resolver —
    /// which is also what makes `computeFailedRoles`'s "the resolver and the chip row can
    /// never disagree" a structural property rather than a convention.
    static func chipOptions(
        roles: [TeamRoleDefinition],
        workingRoleIDs: Set<String>,
        activeQuestions: [TeamActivityActiveQuestion],
        allowsRoleFallback: Bool,
        selectable: [TeamRoleDefinition],
        failed: [TeamRoleDefinition],
        candidates: [TeamRoleDefinition]
    ) -> [ChipOption] {
        var options: [ChipOption] = []
        for q in activeQuestions {
            let askingName = roles.first(where: { $0.id == q.askingRoleID })?.name ?? q.askingRoleID
            options.append(.init(
                recipient: .answer(stepID: q.stepID),
                label: "Answer \(askingName)",
                icon: "arrowshape.turn.up.left"
            ))
        }
        for role in selectable {
            options.append(.init(recipient: .role(id: role.id), label: role.name, icon: role.icon))
        }
        for role in failed where !workingRoleIDs.contains(role.id) {
            options.append(.init(recipient: .role(id: role.id), label: role.name, icon: "arrow.clockwise"))
        }
        // Fallback for single-role teams whose one role is idle: surface that role's chip by
        // name so the composer still has a recipient between chat turns. Gated by
        // `allowsRoleFallback` (matches the resolver) so a single-role NON-chat team awaiting
        // acceptance shows no chip — otherwise the chip would be a tap-trap that resolves to
        // a recipient whose send is a no-op.
        let alreadyHasRoleChip = options.contains {
            if case .role = $0.recipient { return true } else { return false }
        }
        if allowsRoleFallback, !alreadyHasRoleChip, candidates.count == 1, let only = candidates.first {
            options.append(.init(recipient: .role(id: only.id), label: only.name, icon: only.icon))
        }
        return options
    }

    /// Both per-pass routing answers from ONE derivation of the shared role sets.
    ///
    /// The composer used to compute `chipOptionsComputed` and `effectiveRecipient` as
    /// separate computed properties, each independently deriving `askingRoleIDs` (a `.map`
    /// array plus a `Set`) and the three filtered role arrays. Swift evaluates all six of
    /// `resolveEffectiveRecipient`'s argument expressions eagerly, so every READ paid ~9
    /// heap allocations even when the resolver returned on its first line — ~8 reads per
    /// body pass (3 direct plus one per chip), plus 3 more for the chip options.
    static func computeRouting(
        roles: [TeamRoleDefinition],
        workingRoleIDs: Set<String>,
        failedRoleIDs: Set<String>,
        activeQuestions: [TeamActivityActiveQuestion],
        allowsRoleFallback: Bool,
        selected: Recipient?,
        aimedStepID: String? = nil
    ) -> Routing {
        let askingRoleIDs = Set(activeQuestions.map(\.askingRoleID))
        let selectable = computeSelectableRoles(
            roles: roles, workingRoleIDs: workingRoleIDs, askingRoleIDs: askingRoleIDs)
        let failed = computeFailedRoles(
            roles: roles, failedRoleIDs: failedRoleIDs, askingRoleIDs: askingRoleIDs)
        let candidates = computeCandidateRoles(roles: roles, askingRoleIDs: askingRoleIDs)
        return Routing(
            chipOptions: chipOptions(
                roles: roles,
                workingRoleIDs: workingRoleIDs,
                activeQuestions: activeQuestions,
                allowsRoleFallback: allowsRoleFallback,
                selectable: selectable,
                failed: failed,
                candidates: candidates
            ),
            effectiveRecipient: resolveEffectiveRecipient(
                selected: selected,
                aimedStepID: aimedStepID,
                activeQuestions: activeQuestions,
                selectableRoles: selectable,
                failedRoles: failed,
                candidateRoles: candidates,
                allowsRoleFallback: allowsRoleFallback
            )
        )
    }
}
