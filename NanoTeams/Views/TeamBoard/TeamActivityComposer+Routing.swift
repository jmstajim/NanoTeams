import SwiftUI

// MARK: - Pure Routing Helpers (unit-testable)

extension TeamActivityComposer {
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
    /// 2. If any question is pending → `.answer(stepID:)` for the FIRST pending question
    ///    (Answer chips are leftmost in the row, in input order).
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
        activeQuestions: [TeamActivityActiveQuestion],
        selectableRoles: [TeamRoleDefinition],
        failedRoles: [TeamRoleDefinition] = [],
        candidateRoles: [TeamRoleDefinition],
        allowsRoleFallback: Bool = false
    ) -> Recipient? {
        if let explicit = selected { return explicit }
        if let q = activeQuestions.first { return .answer(stepID: q.stepID) }
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
            if roleDefinitions.filter(isMessageableRole).count <= 1 {
                return "Send a message to \(name)…"
            }
            return "Send a message…"
        case nil:
            return "No active recipient — accept, restart a role, or request changes."
        }
    }

    /// Pure submit-gate. The composer can submit when there is content (text,
    /// attachment, or clip) AND there is a recipient to deliver to. `nil` recipient
    /// means no chip is selectable (no question, no working role, no candidate) —
    /// submission is blocked.
    static func computeCanSubmit(
        text: String,
        hasAttachments: Bool,
        hasClips: Bool,
        effectiveRecipient: Recipient?
    ) -> Bool {
        guard effectiveRecipient != nil else { return false }
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasAttachments
            || hasClips
        return hasContent
    }

    /// Drops a stale chip selection: if the previously-selected chip is no longer
    /// in the available chip row (e.g. Answer chip after answering, role chip after
    /// the role finishes), return `nil` so the resolver's auto-resolution kicks back
    /// in. Returns the input unchanged when it's still valid (or already nil).
    static func sanitizeSelection(
        selected: Recipient?,
        availableRecipients: [Recipient]
    ) -> Recipient? {
        guard let sel = selected else { return nil }
        return availableRecipients.contains(sel) ? sel : nil
    }

    /// Retargets a lost selection to the SAME underlying role under its other chip
    /// shape before the draft is discarded. For team tasks `StepExecution.id == roleID`,
    /// so `.role(id: X)` and `.answer(stepID: X)` address the same role/conversation —
    /// a role flipping working↔asking (the Autovisor's frequent running↔parked idle
    /// cycle) swaps one chip shape for the other, which would otherwise invalidate the
    /// explicit selection and wipe the in-progress draft (the "my message disappears"
    /// bug). Returns the still-present `prior`, else the same role's counterpart-shape
    /// recipient if present, else `nil` (genuinely gone — `shouldClearDraftAfterSelectionLoss`
    /// then decides). Superset of `sanitizeSelection`: identical when no counterpart exists.
    static func remapEquivalentRecipient(
        prior: Recipient?,
        availableRecipients: [Recipient]
    ) -> Recipient? {
        guard let prior else { return nil }
        if availableRecipients.contains(prior) { return prior }
        let roleID: String
        switch prior {
        case .role(let id): roleID = id
        case .answer(let stepID): roleID = stepID
        }
        return availableRecipients.first { candidate in
            switch candidate {
            case .role(let id): return id == roleID
            case .answer(let stepID): return stepID == roleID
            }
        }
    }

    /// Whether to discard the draft (text + attachments + clips) after the user's
    /// explicit recipient selection lost its chip. Triggers only when there was a
    /// real explicit lock AND a draft AND the lock is now invalid — implicit
    /// auto-selection (no `selected`) lets `resolveEffectiveRecipient` fall through
    /// silently because the user never committed to a specific role.
    static func shouldClearDraftAfterSelectionLoss(
        prior: Recipient?,
        sanitized: Recipient?,
        hasContent: Bool
    ) -> Bool {
        prior != nil && sanitized == nil && hasContent
    }

    /// Post-submit reset contract. Pinned by
    /// `TeamActivityComposerRoutingTests.testClearedComposerState_*`:
    /// resets `selectedRecipient` to nil along with text/attachments/clips.
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
        selectedRecipient: Recipient?
    ) {
        ("", [], [], nil)
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
        let selectable = computeSelectableRoles(
            roles: roles, workingRoleIDs: workingRoleIDs, askingRoleIDs: askingRoleIDs
        )
        let failed = computeFailedRoles(
            roles: roles, failedRoleIDs: failedRoleIDs, askingRoleIDs: askingRoleIDs
        )
        let candidates = computeCandidateRoles(roles: roles, askingRoleIDs: askingRoleIDs)

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
}
