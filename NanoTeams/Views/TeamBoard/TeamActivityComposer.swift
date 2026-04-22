import SwiftUI

// MARK: - Active Question

/// Snapshot of the single active `ask_supervisor` question, if any.
/// For team tasks `StepExecution.id == effectiveRoleID == roleID` (see CLAUDE.md
/// §Common API pitfalls), so `askingRoleID` is a computed projection of `stepID`
/// rather than a stored field — this keeps the two values from ever drifting.
struct TeamActivityActiveQuestion: Equatable {
    let stepID: String
    let role: Role
    let question: String

    /// Role id of the role currently asking. For team tasks this equals `stepID`
    /// by design (`StepExecution.id == roleID`); exposed as a computed property
    /// so callers don't accidentally pass different values.
    var askingRoleID: String { stepID }
}

// MARK: - Team Activity Composer

/// Persistent composer rendered in the same visual slot as the active
/// `ask_supervisor` card. Replaces the passive question banner with a single
/// unified input: the Supervisor always sees one card, and the **"To:"** menu
/// lets them choose between **Answer [the asking role]**, **Team (queue)**,
/// or **queue for a specific working role**.
///
/// ### Recipient → Action (engine-state-independent)
///
/// | Recipient | Action | Failure mode |
/// |---|---|---|
/// | `.answer(stepID)` | `store.answerSupervisorQuestion(stepID:…)` | Attachment finalize failure only |
/// | `.team` | `QuickCaptureController.queueChatMessage(targetRoleID: nil)` | Empty payload rejected |
/// | `.role(id)` | `QuickCaptureController.queueChatMessage(targetRoleID: id)` | Empty payload rejected |
///
/// This composer does NOT invoke `NTMSOrchestrator.correctRole` — that flow lives
/// on `RoleContextBanner` / `RoleNodeRuntimeView` via `CorrectRoleSheet`, which is
/// the correct path for mid-pause interventions that need conversation-preserving
/// continuation. The composer's `.role` / `.team` queue is a softer tool: queued
/// messages are consumed at the **top of the role's next `runOneLLMToolIteration`**
/// — the model sees them on its next request, no `ask_supervisor` required. If
/// the role is already `.needsSupervisorInput`, the older
/// `QuickCaptureController.flushQueuedChatMessage` path handles delivery via
/// `answerSupervisorQuestion` as a backstop.
struct TeamActivityComposer: View {
    let roleDefinitions: [TeamRoleDefinition]
    let isChatMode: Bool
    let taskID: Int
    /// Role IDs currently `.working` — only these are valid queue targets.
    /// Supervisor cannot message an idle / done / failed role through this composer.
    let workingRoleIDs: Set<String>
    /// When present, the "To:" menu offers an **Answer** option for this question
    /// and the question text is previewed in the card header.
    let activeQuestion: TeamActivityActiveQuestion?

    @State private var text: String = ""
    @State private var attachments: [StagedAttachment] = []
    @State private var clippedTexts: [String] = []
    /// Selected recipient. `nil` = auto (Answer if question pending, else Team/queue).
    @State private var selectedRecipient: Recipient? = nil
    /// Intrinsic height of the question preview content — used both to decide whether
    /// to draw the "more below" fade hint when the text overflows the cap, and to
    /// shrink the preview frame to content size for short questions (instead of a
    /// `ScrollView` greedily filling the 140pt cap). Seeded with `.infinity` so the
    /// first render doesn't flash at zero height (CLAUDE.md #18).
    @State private var questionContentHeight: CGFloat = .infinity

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StoreConfiguration.self) private var config

    private var formState: QuickCaptureFormState { QuickCaptureController.shared.formState }

    // MARK: - Recipient

    /// The compile-enforced invariant: `.answer` cannot exist without a step id.
    /// This replaces a runtime `guard let q = activeQuestion else { error }` and
    /// makes "answer without a question" unrepresentable at the type level.
    enum Recipient: Hashable {
        case answer(stepID: String)  // Reply to the active question identified by step id.
        case team                    // Queue a message for next `.needsSupervisorInput` (any role).
        case role(id: String)        // Queue a message targeted at a specific working role.
    }

    private var effectiveRecipient: Recipient {
        Self.resolveEffectiveRecipient(
            selected: selectedRecipient,
            activeQuestion: activeQuestion,
            selectableRoles: selectableRoles,
            candidateRoles: candidateRoles
        )
    }

    private var selectableRoles: [TeamRoleDefinition] {
        Self.computeSelectableRoles(
            roles: roleDefinitions,
            workingRoleIDs: workingRoleIDs,
            askingRoleID: activeQuestion?.askingRoleID
        )
    }

    private var candidateRoles: [TeamRoleDefinition] {
        Self.computeCandidateRoles(
            roles: roleDefinitions,
            askingRoleID: activeQuestion?.askingRoleID
        )
    }

    private func roleName(_ id: String) -> String {
        roleDefinitions.first(where: { $0.id == id })?.name ?? id
    }

    private func roleIcon(_ id: String) -> String {
        roleDefinitions.first(where: { $0.id == id })?.icon ?? "person.fill"
    }

    // MARK: - Derived

    private var avatarIcon: String {
        switch effectiveRecipient {
        case .answer:
            return activeQuestion.map { roleIcon($0.askingRoleID) } ?? "person.3.fill"
        case .team:
            return "person.3.fill"
        case .role(let id):
            return roleIcon(id)
        }
    }

    private var cardTint: Color { Colors.accent }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || !clippedTexts.isEmpty
    }

    private var queuedMessages: [QuickCaptureFormState.QueuedChatMessage] {
        formState.queuedMessages(for: taskID)
    }

    private var placeholderText: String {
        switch effectiveRecipient {
        case .answer:
            return "Answer…"
        case .team:
            if activeQuestion != nil { return "Queue a message instead…" }
            // No one is currently working → "queue" has no target. Treat it as a
            // plain message that will land whenever the team next needs input.
            if selectableRoles.isEmpty {
                return isChatMode ? "Send a message…" : "Send a message to the team…"
            }
            return isChatMode ? "Type your message…" : "Queue a message for the team…"
        case .role(let id):
            // If the role isn't currently working, there's no queue to wait on.
            let isWorking = workingRoleIDs.contains(id)
            return isWorking
                ? "Queue a message for \(roleName(id))…"
                : "Send a message to \(roleName(id))…"
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedIconAvatar(icon: avatarIcon, color: cardTint)

            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                recipientChipRow

                VStack(alignment: .leading, spacing: Spacing.s) {
                    if let q = activeQuestion {
                        questionPreview(q)
                            .padding(.bottom, Spacing.xs)
                    }
                    if !queuedMessages.isEmpty {
                        queuedList
                    }
                    MessageComposer(
                        text: $text,
                        attachments: $attachments,
                        clips: $clippedTexts,
                        placeholder: placeholderText,
                        canSubmit: canSubmit,
                        isSubmitting: false,
                        onSubmit: handleSubmit,
                        onStageAttachment: { url in store.stageAttachment(url: url, draftID: UUID()) },
                        onRemoveAttachment: { staged in store.removeStagedAttachment(staged) }
                    )
                }
                .padding(ActivityCardTokens.cardPadding)
                .background(
                    RoundedRectangle(cornerRadius: ActivityCardTokens.cornerRadius, style: .continuous)
                        .fill(cardTint.opacity(ActivityCardTokens.backgroundOpacity))
                )
            }
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.s)
    }

    // MARK: - Recipient Chips (Spotify-style horizontal pill row)

    private var chipOptionsComputed: [ChipOption] {
        Self.computeChipOptions(
            roles: roleDefinitions,
            workingRoleIDs: workingRoleIDs,
            activeQuestion: activeQuestion
        )
    }

    private var recipientChipRow: some View {
        HStack(spacing: Spacing.xs) {
            Text("To")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(chipOptionsComputed) { option in
                        chip(for: option)
                    }
                }
                .padding(.vertical, 2)
            }
            .mask(
                // Fade the trailing edge so users get a visual hint that the row scrolls.
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(for option: ChipOption) -> some View {
        let isSelected = effectiveRecipient == option.recipient
        return Button {
            selectedRecipient = option.recipient
        } label: {
            HStack(spacing: 4) {
                Image(systemName: option.icon)
                    .font(.caption2.weight(.semibold))
                Text(option.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Colors.textPrimary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? cardTint : Colors.surfaceElevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.clear : Colors.borderSubtle,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func questionPreview(_ q: TeamActivityActiveQuestion) -> some View {
        let maxPreviewHeight: CGFloat = 140
        // Cap the preview at ~6 lines — long questions (e.g. a whole poem) would
        // otherwise grow the composer until the textfield + send button slide off
        // the bottom of the window. Beyond the cap the text becomes scrollable and
        // a fade-out gradient hints at the cut-off content below.
        return ScrollView {
            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.body)
                    .foregroundStyle(cardTint)
                Text("\(roleName(q.askingRoleID)) asks: \(q.question)")
                    .font(.body)
                    .foregroundStyle(Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, Spacing.m)
            .padding(.top, Spacing.xs)
            // Extra bottom padding pushes the last line above the fade band. The
            // `.mask` gradient below fades the bottom ~12% of the frame for the
            // "more below" affordance — without this gutter, tall questions get
            // their last visible line rendered through the fade.
            .padding(.bottom, Spacing.m)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                questionContentHeight = newHeight
            }
        }
        // Shrink to content for short questions; cap at maxPreviewHeight for long ones.
        // ScrollView is greedy by default — `.frame(maxHeight:)` alone would always fill
        // the cap regardless of content size.
        .frame(height: min(questionContentHeight, maxPreviewHeight))
        .mask {
            if questionContentHeight > maxPreviewHeight {
                // Asymmetric fade — small hint at the top (content above) and a
                // bigger one at the bottom where the cut-off is more prominent.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Rectangle()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if questionContentHeight > maxPreviewHeight {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(cardTint)
                    .padding(4)
                    .background(Circle().fill(Colors.surfaceElevated))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Lists every queued message with its recipient and first-line preview. Each row
    /// has its own X button so individual messages can be discarded without wiping the
    /// whole queue. Uses `QueuedChatMessage.id` (UUID) for `ForEach` identity — this
    /// is the stable-id requirement from CLAUDE.md #22 (never use array index as id).
    private var queuedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(queuedMessages) { message in
                queuedRow(message: message)
            }
        }
    }

    private func queuedRow(message: QuickCaptureFormState.QueuedChatMessage) -> some View {
        let recipient: String = {
            if let id = message.targetRoleID { return roleName(id) }
            return "Team"
        }()
        let firstLine = message.text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            ?? ""
        let preview = firstLine.isEmpty
            ? "\(message.attachments.count + message.clippedTexts.count) attachment(s)"
            : firstLine

        return HStack(spacing: Spacing.xs) {
            Image(systemName: "tray.and.arrow.up")
                .font(.caption2)
                .foregroundStyle(cardTint)
            Text("To \(recipient):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(cardTint)
            Text(preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.xs)
            Button {
                QuickCaptureController.shared.formState.removeQueuedMessage(
                    withID: message.id, for: taskID
                )
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Discard this queued message")
            .accessibilityLabel("Discard queued message to \(recipient)")
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(cardTint.opacity(0.12))
        )
    }

    // MARK: - Submit

    private func handleSubmit() {
        let built = AnswerTextBuilder.build(
            text: text,
            clips: clippedTexts,
            attachments: attachments,
            embedFiles: config.embedFilesInPrompt
        )
        if !built.failedFiles.isEmpty {
            // Be explicit about what happened to the failed files. `AnswerTextBuilder`
            // falls back to path-attachment when inline embed fails, so the user's
            // files ARE still delivered as file paths — the banner should say so.
            store.lastErrorMessage = "Could not embed \(built.failedFiles.count) file(s) inline — attached as paths: \(built.failedFiles.joined(separator: ", "))."
        }

        switch effectiveRecipient {
        case .answer(let stepID):
            // Compile-guaranteed: `.answer` always carries a step id (no runtime guard).
            let finalized = attachments
            Task {
                let ok = await store.answerSupervisorQuestion(
                    stepID: stepID, taskID: taskID,
                    answer: built.answer, attachments: finalized
                )
                if ok {
                    clearComposer()
                }
                // On failure `answerSupervisorQuestion` already set `lastErrorMessage`
                // (specific — e.g. attachment finalize error). Don't clobber it with a
                // generic message here.
            }
        case .team:
            // Queue the message for delivery when the team next needs supervisor input.
            // Works in both chat and non-chat modes — on terminal engine states
            // `tryFlushQueuedMessages` surfaces `lastInfoMessage` with a count so the
            // user isn't silently stranded.
            let queued = QuickCaptureController.shared.queueChatMessage(
                text: text, attachments: attachments, clippedTexts: clippedTexts, taskID: taskID
            )
            if queued {
                clearComposer()
                if activeQuestion == nil {
                    // Without a pending question, nothing visibly changes after queueing.
                    // Tell the user their message is queued so they don't think it vanished.
                    store.lastInfoMessage = "Queued for Team — will deliver on the next request."
                }
            }
        case .role(let id):
            // Queue a message narrowed to a specific working role — delivered when THAT
            // role reaches `.needsSupervisorInput`. For stronger interventions
            // (cancelling mid-stream work, conversation-preserving correction), use
            // the "Correct Role…" sheet on the graph/banner — that path goes through
            // `NTMSOrchestrator.correctRole` and is the right tool for pause+redirect.
            let queued = QuickCaptureController.shared.queueChatMessage(
                text: text, attachments: attachments, clippedTexts: clippedTexts,
                taskID: taskID, targetRoleID: id
            )
            if queued {
                clearComposer()
                store.lastInfoMessage = "Queued for \(roleName(id)) — will deliver on the next request."
            }
        }
    }

    private func clearComposer() {
        text = ""
        attachments = []
        clippedTexts = []
    }

    // MARK: - Chip Option (internal for test access)

    struct ChipOption: Identifiable, Equatable {
        let recipient: Recipient
        let label: String
        let icon: String
        var id: Recipient { recipient }
    }
}

// MARK: - Pure Routing Helpers (unit-testable)

extension TeamActivityComposer {
    /// Auto-selects the effective recipient when the user hasn't explicitly chosen one.
    /// Priority order (documented separately because the chain is non-obvious):
    /// 1. Explicit selection wins.
    /// 2. If a question is pending → `.answer(stepID:)`.
    /// 3. If exactly one role is `.working` → that role (spares a lonely "Team" chip).
    /// 4. If there's exactly one candidate role total (e.g. a one-role team) → that role.
    /// 5. Otherwise `.team`.
    static func resolveEffectiveRecipient(
        selected: Recipient?,
        activeQuestion: TeamActivityActiveQuestion?,
        selectableRoles: [TeamRoleDefinition],
        candidateRoles: [TeamRoleDefinition]
    ) -> Recipient {
        if let explicit = selected { return explicit }
        if let q = activeQuestion { return .answer(stepID: q.stepID) }
        if selectableRoles.count == 1, let only = selectableRoles.first {
            return .role(id: only.id)
        }
        if candidateRoles.count == 1, let only = candidateRoles.first {
            return .role(id: only.id)
        }
        return .team
    }

    /// Currently-working, non-supervisor, non-observer roles, excluding the role
    /// currently asking a Supervisor question (that role has its own "Answer" chip).
    /// Only these are valid queue targets — queueing to an idle role would never flush.
    static func computeSelectableRoles(
        roles: [TeamRoleDefinition],
        workingRoleIDs: Set<String>,
        askingRoleID: String?
    ) -> [TeamRoleDefinition] {
        roles.filter {
            !$0.isSupervisor
                && !$0.isObserver
                && workingRoleIDs.contains($0.id)
                && $0.id != askingRoleID
        }
    }

    /// Every non-supervisor, non-observer role in the team, excluding the asker.
    /// Used as a fallback when no role is currently `.working` but we still want
    /// to offer a sensible chip (e.g. a one-role team whose sole role is idle
    /// between chat turns).
    static func computeCandidateRoles(
        roles: [TeamRoleDefinition],
        askingRoleID: String?
    ) -> [TeamRoleDefinition] {
        roles.filter {
            !$0.isSupervisor && !$0.isObserver && $0.id != askingRoleID
        }
    }

    /// Ordered chip options: Answer (if question pending) first, then Team (only if
    /// there are 2+ selectable roles to disambiguate between), then every working
    /// role. Falls back to a single role chip for one-role teams, and to a generic
    /// Team chip when nothing else is available — the composer always has at least
    /// one valid recipient.
    static func computeChipOptions(
        roles: [TeamRoleDefinition],
        workingRoleIDs: Set<String>,
        activeQuestion: TeamActivityActiveQuestion?
    ) -> [ChipOption] {
        let askingRoleID = activeQuestion?.askingRoleID
        let selectable = computeSelectableRoles(
            roles: roles, workingRoleIDs: workingRoleIDs, askingRoleID: askingRoleID
        )
        let candidates = computeCandidateRoles(roles: roles, askingRoleID: askingRoleID)

        var options: [ChipOption] = []
        if let q = activeQuestion {
            let askingName = roles.first(where: { $0.id == q.askingRoleID })?.name ?? q.askingRoleID
            options.append(.init(
                recipient: .answer(stepID: q.stepID),
                label: "Answer \(askingName)",
                icon: "arrowshape.turn.up.left.fill"
            ))
        }
        // Hide the Team chip with 0 or 1 selectable role:
        // - 0 roles: no one to queue for — Team would have no target.
        // - 1 role: Team and the role's own chip deliver to the same target — redundant.
        if selectable.count >= 2 {
            options.append(.init(recipient: .team, label: "Team", icon: "person.3.fill"))
        }
        for role in selectable {
            options.append(.init(recipient: .role(id: role.id), label: role.name, icon: role.icon))
        }
        // Fallback for single-role teams whose one role is idle: surface that role's
        // chip by name instead of an ambiguous "Team" that would misname the target.
        let alreadyHasRoleChip = options.contains {
            if case .role = $0.recipient { return true } else { return false }
        }
        if !alreadyHasRoleChip, candidates.count == 1, let only = candidates.first {
            options.append(.init(recipient: .role(id: only.id), label: only.name, icon: only.icon))
        }
        // Final fallback: no question, no working role, and 0 or 2+ candidates — keep a
        // generic Team chip so the composer always has at least one valid recipient.
        if options.isEmpty {
            options.append(.init(recipient: .team, label: "Team", icon: "person.3.fill"))
        }
        return options
    }
}

// MARK: - Preview

#Preview("Composer — no pending question (chat)") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    TeamActivityComposer(
        roleDefinitions: Team.default.roles,
        isChatMode: true,
        taskID: 0,
        workingRoleIDs: Set(Team.default.roles.map(\.id)),
        activeQuestion: nil
    )
    .environment(store)
    .environment(config)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Composer — pending question") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    let pmRole = Team.default.roles.first(where: { $0.name == "Product Manager" })!
    TeamActivityComposer(
        roleDefinitions: Team.default.roles,
        isChatMode: false,
        taskID: 0,
        workingRoleIDs: Set(Team.default.roles.map(\.id)),
        activeQuestion: TeamActivityActiveQuestion(
            stepID: pmRole.id,
            role: .productManager,
            question: "Should I prioritize mobile or web for v1?"
        )
    )
    .environment(store)
    .environment(config)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
