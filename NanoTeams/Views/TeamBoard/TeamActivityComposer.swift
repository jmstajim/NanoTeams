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

/// Persistent composer in the same visual slot as the active `ask_supervisor`
/// card. The "To:" chip row routes submission to one of two recipients:
///
/// | Recipient | Action |
/// |---|---|
/// | `.answer(stepID)` | `store.answerSupervisorQuestion(stepID:…)` |
/// | `.role(id)` | `QuickCaptureController.queueChatMessage(targetRoleID: id)` |
///
/// `.role` queues are consumed at the top of the role's next
/// `runOneLLMToolIteration`. For mid-pause conversation-preserving correction
/// use `CorrectRoleSheet` (calls `NTMSOrchestrator.correctRole`) instead.
struct TeamActivityComposer: View {
    let roleDefinitions: [TeamRoleDefinition]
    let isChatMode: Bool
    let taskID: Int
    /// Role IDs currently `.working` — only these are valid queue targets.
    /// Supervisor cannot message an idle / done / failed role through this composer.
    let workingRoleIDs: Set<String>
    /// When present, surfaces an **Answer** chip and previews the question header.
    let activeQuestion: TeamActivityActiveQuestion?
    /// Hard cap on overall composer height; the TextField scrolls internally past this.
    let maxHeight: CGFloat

    @State private var text: String = ""
    @State private var attachments: [StagedAttachment] = []
    @State private var clippedTexts: [String] = []
    /// `nil` = auto (first chip wins via `resolveEffectiveRecipient`); else explicit pick.
    @State private var selectedRecipient: Recipient? = nil
    /// Intrinsic height of the question preview content — used both to decide whether
    /// to draw the "more below" fade hint when the text overflows the cap, and to
    /// shrink the preview frame to content size for short questions (instead of a
    /// `ScrollView` greedily filling the 140pt cap). Seeded with `.infinity` so the
    /// first render doesn't flash at zero height (CLAUDE.md #18).
    @State private var questionContentHeight: CGFloat = .infinity
    /// Tracks which chip the cursor is hovering over (Spotify-style hover feedback).
    @State private var hoveredChipRecipient: Recipient? = nil
    /// Whether the question preview card is collapsed to a single header line.
    @State private var isQuestionCollapsed: Bool = false

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StoreConfiguration.self) private var config

    private var formState: QuickCaptureFormState { QuickCaptureController.shared.formState }

    // MARK: - Recipient

    /// `.answer` cannot exist without a step id — answering without a question is unrepresentable.
    enum Recipient: Hashable {
        case answer(stepID: String)
        case role(id: String)
    }

    /// `nil` when there's no usable recipient (no question, no working role, no
    /// candidate). The chip row collapses and `canSubmit` is `false` in that state.
    private var effectiveRecipient: Recipient? {
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

    private var canSubmit: Bool {
        Self.computeCanSubmit(
            text: text,
            hasAttachments: !attachments.isEmpty,
            hasClips: !clippedTexts.isEmpty,
            effectiveRecipient: effectiveRecipient
        )
    }

    private var queuedMessages: [QuickCaptureFormState.QueuedChatMessage] {
        formState.queuedMessages(for: taskID)
    }

    private var placeholderText: String {
        switch effectiveRecipient {
        case .answer:
            return "Answer…"
        case .role(let id):
            // If the role isn't currently working, there's no queue to wait on.
            let isWorking = workingRoleIDs.contains(id)
            return isWorking
                ? "Queue a message for \(roleName(id))…"
                : "Send a message to \(roleName(id))…"
        case nil:
            return "No active recipient — wait for a role to start working…"
        }
    }

    // MARK: - Body

    var body: some View {
        contentColumn
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.s)
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            recipientChipRow

            if let q = activeQuestion, case .answer = effectiveRecipient {
                questionPreviewCard(q)
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
                onRemoveAttachment: { staged in store.removeStagedAttachment(staged) },
                textFieldLineLimit: 1...6
            )
        }
        // When the chip the user previously tapped disappears (e.g. Answer chip
        // after answering, role chip after the role finishes), clear the explicit
        // selection so `resolveEffectiveRecipient`'s auto-resolution kicks back in.
        // Without this the placeholder/avatar/submit reflect a stale selection.
        .onChange(of: chipOptionsComputed.map(\.recipient)) { _, recipients in
            selectedRecipient = Self.sanitizeSelection(
                selected: selectedRecipient, availableRecipients: recipients
            )
            hoveredChipRecipient = Self.sanitizeSelection(
                selected: hoveredChipRecipient, availableRecipients: recipients
            )
        }
    }

    // MARK: - Recipient Chips (Spotify-style horizontal pill row)

    private var chipOptionsComputed: [ChipOption] {
        Self.computeChipOptions(
            roles: roleDefinitions,
            workingRoleIDs: workingRoleIDs,
            activeQuestion: activeQuestion
        )
    }

    @ViewBuilder
    private var recipientChipRow: some View {
        if !chipOptionsComputed.isEmpty {
            HStack(spacing: Spacing.xs) {
                Text("To")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Colors.textTertiary)
                    .padding(.trailing, Spacing.xxs)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(chipOptionsComputed) { option in
                            chip(for: option)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                }
                .mask(
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
    }

    private func chip(for option: ChipOption) -> some View {
        let isSelected = effectiveRecipient == option.recipient
        let isHovered = hoveredChipRecipient == option.recipient
        let isWorkingRole: Bool = {
            if case .role(let id) = option.recipient { return workingRoleIDs.contains(id) }
            return false
        }()
        // Answer chip uses the asking role's tint; others use accent.
        let selectedFill: Color = {
            if case .answer(let stepID) = option.recipient,
               let roleDef = roleDefinitions.first(where: { $0.id == stepID }) {
                return roleDef.resolvedTintColor
            }
            return Colors.accent
        }()
        let chipFill: Color = isSelected
            ? selectedFill
            : (isHovered ? Colors.surfaceHover : Colors.surfaceElevated)

        return Button {
            withAnimation(Animations.quick) {
                selectedRecipient = option.recipient
            }
        } label: {
            HStack(spacing: Spacing.xxs) {
                if isWorkingRole && !isSelected {
                    Circle()
                        .fill(Colors.success)
                        .frame(width: 5, height: 5)
                }
                Image(systemName: option.icon)
                    .font(.caption2.weight(.semibold))
                Text(option.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Colors.textOnAccent : Colors.textPrimary)
            .padding(.horizontal, Spacing.s - 2)
            .padding(.vertical, Spacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill(chipFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.clear : Colors.borderSubtle,
                        lineWidth: 0.5
                    )
            )
            .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredChipRecipient = hovering ? option.recipient : nil
        }
        .animationWithReduceMotion(Animations.quick, value: isSelected)
        .animationWithReduceMotion(Animations.quick, value: isHovered)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func questionPreviewCard(_ q: TeamActivityActiveQuestion) -> some View {
        let askingColor = roleDefinitions.first(where: { $0.id == q.askingRoleID })?.resolvedTintColor ?? Colors.accent
        let chromeOverhead: CGFloat = 120
        let maxPreviewHeight: CGFloat = maxHeight.isFinite ? max(80, maxHeight - chromeOverhead) : 200

        return VStack(alignment: .leading, spacing: 0) {
            // Header: role icon + "Role asks:" + collapse chevron
            Button {
                withAnimation(Animations.spring) {
                    isQuestionCollapsed.toggle()
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: roleIcon(q.askingRoleID))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(askingColor)
                    Text("\(roleName(q.askingRoleID)) asks:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(askingColor)
                    if isQuestionCollapsed {
                        Text(q.question)
                            .font(.caption)
                            .foregroundStyle(Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Colors.textTertiary)
                        .rotationEffect(.degrees(isQuestionCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs + 2)

            // Body: question text (hidden when collapsed)
            if !isQuestionCollapsed {
                ScrollView {
                    Text(q.question)
                        .font(.callout)
                        .foregroundStyle(Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.s)
                        .padding(.top, Spacing.xxs)
                        .padding(.bottom, Spacing.s)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newHeight in
                            questionContentHeight = newHeight
                        }
                }
                .frame(height: min(questionContentHeight, maxPreviewHeight))
                .mask {
                    if questionContentHeight > maxPreviewHeight {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
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
            }
        }
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
        )
        .clipShape(RoundedRectangle.squircle(CornerRadius.small))
    }

    /// Lists every queued message with its recipient and first-line preview. Each row
    /// has its own X button so individual messages can be discarded without wiping the
    /// whole queue. Uses `QueuedChatMessage.id` (UUID) for `ForEach` identity — this
    /// is the stable-id requirement from CLAUDE.md #22 (never use array index as id).
    private var queuedList: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(queuedMessages) { message in
                queuedRow(message: message)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(Animations.spring, value: queuedMessages.map(\.id))
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
                .foregroundStyle(Colors.textTertiary)
            Text("To \(recipient):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Colors.textSecondary)
            Text(preview)
                .font(.caption)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.xxs)
            Button {
                withAnimation(Animations.spring) {
                    QuickCaptureController.shared.formState.removeQueuedMessage(
                        withID: message.id, for: taskID
                    )
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Discard this queued message")
            .accessibilityLabel("Discard queued message to \(recipient)")
        }
        .padding(.horizontal, Spacing.s - 2)
        .padding(.vertical, Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(Colors.surfaceElevated)
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
        case nil:
            // unreachable: canSubmit gates nil
            assertionFailure("handleSubmit invoked with nil recipient — canSubmit should have gated")
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
    /// Priority order matches the chip row's left-to-right order, so "the first chip
    /// is always selected" holds when there is no explicit pick:
    /// 1. Explicit selection wins.
    /// 2. If a question is pending → `.answer(stepID:)` (Answer chip is first in the row).
    /// 3. Otherwise the first selectable (working) role — matches the next chip in the row.
    /// 4. Otherwise the first candidate role — matches the single-candidate fallback chip.
    /// 5. Otherwise `nil` — no chip exists, the chip row collapses, `canSubmit` is false.
    static func resolveEffectiveRecipient(
        selected: Recipient?,
        activeQuestion: TeamActivityActiveQuestion?,
        selectableRoles: [TeamRoleDefinition],
        candidateRoles: [TeamRoleDefinition]
    ) -> Recipient? {
        if let explicit = selected { return explicit }
        if let q = activeQuestion { return .answer(stepID: q.stepID) }
        if let first = selectableRoles.first { return .role(id: first.id) }
        if let first = candidateRoles.first { return .role(id: first.id) }
        return nil
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

    /// Ordered chips: Answer (if pending), then one per working role, with a
    /// single-candidate fallback for idle one-role teams. Returns `[]` when no
    /// recipient exists — the chip row collapses and `canSubmit` is false.
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
        for role in selectable {
            options.append(.init(recipient: .role(id: role.id), label: role.name, icon: role.icon))
        }
        // Fallback for single-role teams whose one role is idle: surface that role's
        // chip by name so the composer still has a recipient between chat turns.
        let alreadyHasRoleChip = options.contains {
            if case .role = $0.recipient { return true } else { return false }
        }
        if !alreadyHasRoleChip, candidates.count == 1, let only = candidates.first {
            options.append(.init(recipient: .role(id: only.id), label: only.name, icon: only.icon))
        }
        return options
    }
}

// MARK: - Preview

#Preview("Composer — no pending question (chat)") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    TeamActivityComposer(
        roleDefinitions: Team.default.roles,
        isChatMode: true,
        taskID: 0,
        workingRoleIDs: Set(Team.default.roles.map(\.id)),
        activeQuestion: nil,
        maxHeight: .infinity
    )
    .environment(store)
    .environment(config)
    .environment(dictation)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Composer — queued messages") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    let roles = Team.default.roles
    let sweID = roles.first(where: { $0.name == "Software Engineer" })?.id
    let taskID = 42
    TeamActivityComposer(
        roleDefinitions: roles,
        isChatMode: false,
        taskID: taskID,
        workingRoleIDs: Set(roles.map(\.id)),
        activeQuestion: nil,
        maxHeight: .infinity
    )
    .environment(store)
    .environment(config)
    .environment(dictation)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .onAppear {
        let fs = QuickCaptureController.shared.formState
        if let m = QuickCaptureFormState.QueuedChatMessage(
            text: "Focus on the login flow first, skip the admin panel",
            attachments: [], clippedTexts: []
        ) { fs.appendQueuedMessage(m, for: taskID) }
        if let m = QuickCaptureFormState.QueuedChatMessage(
            text: "Use the existing auth service, don't build a new one",
            attachments: [], clippedTexts: [], targetRoleID: sweID
        ) { fs.appendQueuedMessage(m, for: taskID) }
        if let m = QuickCaptureFormState.QueuedChatMessage(
            text: "Remember to check the error handling edge cases",
            attachments: [], clippedTexts: []
        ) { fs.appendQueuedMessage(m, for: taskID) }
    }
}

