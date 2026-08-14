import SwiftUI

// MARK: - Active Question

/// Snapshot of the single active `ask_supervisor` question, if any.
/// For team tasks `StepExecution.id == effectiveRoleID == roleID` (see CLAUDE.md
/// §Common API pitfalls), so `askingRoleID` is a computed projection of `stepID`
/// rather than a stored field — this keeps the two values from ever drifting.
///
/// `paired` carries the assistant turn that emitted the question — its `id`
/// drives bubble-suppression in `ActivityFeedBuilder.emitItems` (so the same
/// turn doesn't appear twice while the question is active) and its `thinking`
/// feeds the composer's thinking disclosure. `paired == nil` means "no preamble
/// turn" — there's no bubble to suppress and the thinking disclosure is hidden.
struct TeamActivityActiveQuestion: Equatable {
    let stepID: String
    let role: Role
    let question: String
    let paired: PairedAssistantMessage?

    /// Role id of the role currently asking. For team tasks this equals `stepID`
    /// by design (`StepExecution.id == roleID`); exposed as a computed property
    /// so callers don't accidentally pass different values.
    var askingRoleID: String { stepID }

    /// Memberwise init expressed explicitly so `paired:` defaults to `nil` for
    /// routing/ordering tests that don't exercise the thinking-disclosure path.
    /// Production code always passes `paired:` from `ActiveSupervisorQuestion.paired`,
    /// so no default is leaked into a silent-failure path.
    init(
        stepID: String,
        role: Role,
        question: String,
        paired: PairedAssistantMessage? = nil
    ) {
        self.stepID = stepID
        self.role = role
        self.question = question
        self.paired = paired
    }

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
    /// Role IDs currently `.working` — the only valid *targeted* queue targets (live
    /// steering). Supervisor cannot narrow-queue to an idle / done role.
    let workingRoleIDs: Set<String>
    /// Role IDs currently `.failed`. The composer names one as the retry target
    /// ("Send a message to X to retry…") and offers a chip for it; sending queues
    /// untargeted (the role isn't `.working`) and rides the `.failed` resume path.
    let failedRoleIDs: Set<String>
    /// Whether the composer may auto-resolve to `candidateRoles.first` when nothing is
    /// working/asking/failed. True for chat mode and resumable-by-send states
    /// (`.paused`/`.pending`/`.failed`); false for `.needsAcceptance` (done, awaiting
    /// review) so the composer goes inert instead of naming an arbitrary role.
    let allowsRoleFallback: Bool
    /// One Answer chip is rendered per pending question, in input order. Empty = no
    /// pending input. Multiple entries are possible whenever the dependency graph
    /// has parallel branches (CLAUDE.md #45 — TeamEngine starts ready roles
    /// concurrently). Caller is responsible for ordering; chip-row order mirrors
    /// this array verbatim.
    let activeQuestions: [TeamActivityActiveQuestion]
    /// Hard cap on overall composer height; the TextField scrolls internally past this.
    let maxHeight: CGFloat

    /// Pane-anchored override for `MessageComposer.maxTextFieldHeight`. Tracks the pane
    /// instead of using `MessageComposer`'s shared default — past the cap the field
    /// scrolls internally and the cursor stays visible (iMessage-style). Floor and
    /// chrome subtraction come from `MessageComposerLayout` (single source of truth
    /// shared with `QuickCaptureFormView.taskFieldMaxHeight`); fallback when the
    /// pane height is non-finite is the same default `MessageComposer` would have
    /// applied on its own.
    private var messageFieldMaxHeight: CGFloat {
        guard maxHeight.isFinite else { return MessageComposerLayout.defaultMaxTextFieldHeight }
        let halfPane = maxHeight * 0.5
        return max(
            MessageComposerLayout.minPaneAnchoredFieldHeight,
            halfPane - MessageComposerLayout.paneAnchoredFieldChrome
        )
    }

    @State private var text: String = ""
    @State private var attachments: [StagedAttachment] = []
    @State private var clippedTexts: [String] = []
    /// `nil` = auto (first chip wins via `resolveEffectiveRecipient`); else explicit pick.
    @State private var selectedRecipient: Recipient? = nil
    /// Intrinsic height of the question preview content — used both to decide whether
    /// to draw the "more below" fade hint when the text overflows the cap, and to
    /// shrink the preview frame to content size for short questions (instead of a
    /// `ScrollView` greedily filling the 140pt cap). Seeded with `.infinity` so the
    /// first render doesn't flash at zero height (CLAUDE.md #18). Deliberately NOT
    /// reset on chip switch: when two questions render at the same intrinsic height,
    /// `onGeometryChange` does not fire (no value change), and a `.infinity` reseed
    /// would clamp the frame to `maxPreviewHeight` until the next geometry callback.
    @State private var questionContentHeight: CGFloat = .infinity
    /// Tracks which chip the cursor is hovering over for hover feedback.
    @State private var hoveredChipRecipient: Recipient? = nil
    /// Whether the question preview card is collapsed to a single header line.
    @State private var isQuestionCollapsed: Bool = false
    /// Whether the paired-message thinking disclosure is expanded. Only relevant
    /// when `q.paired?.thinking != nil`. Default collapsed: thinking is
    /// supplementary; user reaches for it only when the body alone is unclear.
    @State private var isThinkingExpanded: Bool = false

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
            activeQuestions: activeQuestions,
            selectableRoles: selectableRoles,
            failedRoles: failedRoles,
            candidateRoles: candidateRoles,
            allowsRoleFallback: allowsRoleFallback
        )
    }

    /// All role IDs currently asking a Supervisor question — excluded from queue-role
    /// chips so the same role doesn't appear twice (once as Answer, once as queue target).
    private var askingRoleIDs: Set<String> {
        Set(activeQuestions.map(\.askingRoleID))
    }

    private var selectableRoles: [TeamRoleDefinition] {
        Self.computeSelectableRoles(
            roles: roleDefinitions,
            workingRoleIDs: workingRoleIDs,
            askingRoleIDs: askingRoleIDs
        )
    }

    private var candidateRoles: [TeamRoleDefinition] {
        Self.computeCandidateRoles(
            roles: roleDefinitions,
            askingRoleIDs: askingRoleIDs
        )
    }

    /// `.failed` roles eligible as a named retry target — non-supervisor, non-observer,
    /// not currently asking (askers route through their own Answer chip).
    private var failedRoles: [TeamRoleDefinition] {
        Self.computeFailedRoles(
            roles: roleDefinitions,
            failedRoleIDs: failedRoleIDs,
            askingRoleIDs: askingRoleIDs
        )
    }

    private func roleName(_ id: String) -> String {
        roleDefinitions.first(where: { $0.id == id })?.name ?? id
    }

    private func roleIcon(_ id: String) -> String {
        roleDefinitions.first(where: { $0.id == id })?.icon ?? "person"
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
        Self.placeholderText(
            recipient: effectiveRecipient,
            workingRoleIDs: workingRoleIDs,
            failedRoleIDs: failedRoleIDs,
            roleDefinitions: roleDefinitions
        )
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

            if case .answer(let stepID) = effectiveRecipient,
               let q = activeQuestions.first(where: { $0.stepID == stepID }) {
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
                minLineCount: 1,
                maxTextFieldHeight: messageFieldMaxHeight,
                skillsProjectRoot: store.hasRealWorkFolder ? store.workFolderURL : nil
            )
        }
        // Lock the recipient on first keystroke. Without this, `selectedRecipient`
        // stays `nil`, the resolver picks `activeQuestions.first`, and any change to
        // the leftmost chip (e.g. another role hits `.needsSupervisorInput`, or the
        // current first question is answered via Watchtower) silently retargets the
        // half-typed reply to a different role.
        .onChange(of: text) { oldText, newText in
            let wasEmpty = oldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isEmpty = newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if wasEmpty, !isEmpty, selectedRecipient == nil, let auto = effectiveRecipient {
                selectedRecipient = auto
            }
        }
        // When the chip the user previously tapped disappears (e.g. Answer chip
        // after answering, role chip after the role finishes), clear the explicit
        // selection so `resolveEffectiveRecipient`'s auto-resolution kicks back in.
        // Without this the placeholder/avatar/submit reflect a stale selection.
        .onChange(of: chipOptionsComputed.map(\.recipient)) { _, recipients in
            let prior = selectedRecipient
            // Retarget to the SAME role's other chip shape (`.role` ↔ `.answer`)
            // before treating the selection as lost. The Autovisor (and any
            // single-role chat task) flips working↔asking constantly — its idle
            // `wait_for_events` park swaps the working-role chip for an Answer chip
            // mid-compose — and a bare `sanitizeSelection` would drop the explicit
            // lock and wipe the half-typed draft on every such transition.
            let sanitized = Self.remapEquivalentRecipient(
                prior: prior, availableRecipients: recipients
            )
            let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty
                || !clippedTexts.isEmpty
            if Self.shouldClearDraftAfterSelectionLoss(
                prior: prior, sanitized: sanitized, hasContent: hasContent
            ) {
                clearComposer()
                store.lastInfoMessage = "Your selected recipient is no longer waiting — draft discarded. Pick another recipient and retry."
            }
            selectedRecipient = sanitized
            hoveredChipRecipient = Self.sanitizeSelection(
                selected: hoveredChipRecipient, availableRecipients: recipients
            )
        }
    }

    // MARK: - Recipient Chips (horizontal pill row)

    private var chipOptionsComputed: [ChipOption] {
        Self.computeChipOptions(
            roles: roleDefinitions,
            workingRoleIDs: workingRoleIDs,
            failedRoleIDs: failedRoleIDs,
            activeQuestions: activeQuestions,
            allowsRoleFallback: allowsRoleFallback
        )
    }

    @ViewBuilder
    private var recipientChipRow: some View {
        if !chipOptionsComputed.isEmpty {
            HStack(spacing: Spacing.xs) {
                MonoLabel(text: "To", size: .xs)
                    .padding(.trailing, Spacing.xxs)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(chipOptionsComputed) { option in
                            chip(for: option)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    // Lock to intrinsic vertical extent — `HStack` can't wrap, but
                    // without `.fixedSize` it can be stretched by parent layout pressure
                    // when the chip count grows. Keeps the row strictly single-line.
                    .fixedSize(horizontal: false, vertical: true)
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
                Image(systemName: option.icon)
                    .font(Typography.caption2.weight(.semibold))
                Text(option.label)
                    .font(Typography.termXs.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Colors.textOnAccent : Colors.textPrimary)
            .padding(.horizontal, Spacing.s - 2)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(chipFill)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.small)
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
        let thinking = q.paired?.thinking

        return VStack(alignment: .leading, spacing: 0) {
            // Header: role icon + "Role asks:" + collapse chevron.
            // Collapsed header truncates the question to a single line.
            Button {
                withAnimation(Animations.spring) {
                    isQuestionCollapsed.toggle()
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: roleIcon(q.askingRoleID))
                        .font(Typography.captionSemibold)
                        .foregroundStyle(askingColor)
                    Text("\(roleName(q.askingRoleID)) asks:")
                        .font(Typography.captionSemibold)
                        .foregroundStyle(askingColor)
                    if isQuestionCollapsed {
                        Text(q.question)
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(Typography.caption2.weight(.semibold))
                        .foregroundStyle(Colors.textTertiary)
                        .rotationEffect(.degrees(isQuestionCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs + 2)

            // Body (hidden when collapsed): optional Thinking disclosure + question text.
            if !isQuestionCollapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if let thinking {
                            thinkingDisclosure(thinking: thinking, tint: askingColor)
                        }
                        Text(q.question)
                            .font(Typography.termBase)
                            .foregroundStyle(Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Spacing.s)
                    .padding(.top, Spacing.xxs)
                    .padding(.bottom, Spacing.xl)
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

    /// Collapsible thinking section above the body. Mirrors `MessageThinkingSection`
    /// styling (left accent stripe, chevron, secondary text) at a more compact
    /// scale so it fits inside the composer card. Local `@State` toggles
    /// `isThinkingExpanded`; default collapsed.
    @ViewBuilder
    private func thinkingDisclosure(thinking: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Animations.spring) {
                    isThinkingExpanded.toggle()
                }
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "chevron.right")
                        .font(Typography.caption2.weight(.semibold))
                        .foregroundStyle(tint.opacity(DynamicTintOpacity.stroke))
                        .rotationEffect(.degrees(isThinkingExpanded ? 90 : 0))
                    Text("Thinking")
                        .font(Typography.caption.weight(.medium))
                        .foregroundStyle(Colors.textSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isThinkingExpanded {
                Text(thinking)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Spacing.s)
                    .padding(.top, Spacing.xxs)
                    .overlay(alignment: .leading) {
                        RoundedRectangle.squircle(CornerRadius.micro)
                            .fill(tint.opacity(DynamicTintOpacity.stroke))
                            .frame(width: 2)
                    }
            }
        }
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
                .font(Typography.caption2)
                .foregroundStyle(Colors.textTertiary)
            Text("To \(recipient):")
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textSecondary)
            Text(preview)
                .font(Typography.caption)
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
                    .font(Typography.caption2.weight(.semibold))
                    .foregroundStyle(Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Discard this queued message")
            .accessibilityLabel("Discard queued message to \(recipient)")
        }
        .padding(.horizontal, Spacing.s - 2)
        .padding(.vertical, Spacing.xxs)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
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
        if let banner = Self.bannerForFailedFiles(built.failedFiles) {
            store.lastErrorMessage = banner
        }

        switch effectiveRecipient {
        case .answer(let stepID):
            // Compile-guaranteed: `.answer` always carries a step id (no runtime guard).
            let finalized = attachments
            let snapshotText = text
            let snapshotClips = clippedTexts
            Task {
                await Self.performAnswerSubmit(
                    snapshotText: snapshotText,
                    snapshotAttachments: finalized,
                    snapshotClips: snapshotClips,
                    clear: { clearComposer() },
                    submit: {
                        await store.answerSupervisorQuestion(
                            stepID: stepID, taskID: taskID,
                            answer: built.answer, attachments: finalized
                        )
                    },
                    restore: { t, a, c in
                        text = t
                        attachments = a
                        clippedTexts = c
                    }
                )
                // On failure `answerSupervisorQuestion` already set `lastErrorMessage`
                // (specific — e.g. attachment finalize error). Don't clobber it with a
                // generic message here.
            }
        case .role(let id):
            // Queue a message for a role. When the role is currently working, narrow
            // delivery to it (steering for a live role). When NO role is working — a
            // paused/failed resume, or an idle team between chat turns — the resolved
            // `id` is just `candidateRoles.first`, so queue UNTARGETED: whichever role
            // resumes consumes it via the untargeted tier of
            // `injectQueuedSupervisorMessage`, rather than mis-targeting an arbitrary
            // role. For conversation-preserving correction of a paused role, use the
            // "Correct Role…" sheet (routes through `NTMSOrchestrator.correctRole`).
            let isWorking = workingRoleIDs.contains(id)
            let queued = QuickCaptureController.shared.queueChatMessage(
                text: text, attachments: attachments, clippedTexts: clippedTexts,
                taskID: taskID,
                targetRoleID: Self.queueTarget(roleID: id, workingRoleIDs: workingRoleIDs)
            )
            if queued {
                clearComposer()
                store.lastInfoMessage = Self.queuedRoleInfoMessage(roleName: roleName(id), isWorking: isWorking)
            }
        case nil:
            // unreachable: canSubmit gates nil
            assertionFailure("handleSubmit invoked with nil recipient — canSubmit should have gated")
        }
    }

    private func clearComposer() {
        let cleared = Self.clearedComposerState()
        text = cleared.text
        attachments = cleared.attachments
        clippedTexts = cleared.clips
        selectedRecipient = cleared.selectedRecipient
    }

    // MARK: - Chip Option (internal for test access)

    struct ChipOption: Identifiable, Equatable {
        let recipient: Recipient
        let label: String
        let icon: String
        var id: Recipient { recipient }
    }
}

// MARK: - Bash approval card list

/// The held-`bash`-command approval cards for `taskID`. Rendered at the activity-feed
/// level (NOT inside the composer) so they stay visible even when the composer is
/// hidden — e.g. while the Supervisor browses a historical run of a task whose LIVE
/// run is holding a command, where the gate is awaiting a decision with no other UI
/// to give it. Self-hides when nothing is held.
struct BashApprovalCardList: View {
    let taskID: Int
    let roleDefinitions: [TeamRoleDefinition]

    @Environment(NTMSOrchestrator.self) private var store

    /// Held requests for `taskID`, oldest first. Pure (no view state) so the
    /// task-isolation + ordering is unit-testable without rendering.
    nonisolated static func sortedRequests(
        for taskID: Int, from all: [TaskStepKey: BashApprovalRequest]
    ) -> [BashApprovalRequest] {
        all.filter { $0.key.taskID == taskID }
            .map(\.value)
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ForEach(Self.sortedRequests(for: taskID, from: store.bashApprovalRequests)) { request in
            BashApprovalCard(
                taskID: taskID,
                request: request,
                roleName: roleDefinitions.first(where: { $0.id == request.stepID })?.name ?? request.stepID)
        }
    }
}

// MARK: - Bash approval card (Allow / Deny buttons that bypass the model)

/// A `bash` command HELD by the gate awaiting the human's decision. The buttons
/// resolve the gate's in-loop await DIRECTLY — Allow runs the real command (its
/// output goes to the model); Deny returns a denial. "Always allow" (non-Manual
/// modes only) persists a standing allow rule first. The "Ask AI" advisory is a
/// read-only second opinion.
private struct BashApprovalCard: View {
    let taskID: Int
    let request: BashApprovalRequest
    let roleName: String

    @Environment(NTMSOrchestrator.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "terminal")
                    .accessibilityHidden(true)
                Text("\(roleName) wants to run a command")
            }
            .font(Typography.caption.weight(.medium))
            .foregroundStyle(Colors.textSecondary)

            Text(request.command)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textPrimary)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .padding(Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.surfaceOverlay))

            // The cwd changes the meaning of every relative path in the command, and the
            // Auto judge already receives it — the human decider must see it too.
            if let cwd = request.displayWorkingDirectory {
                Text("cwd: \(cwd)")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Colors.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Action row: Allow / Deny (+ Always allow) on the left, the read-only
            // "Ask AI" second opinion pushed to the right. Verdicts render below,
            // sized to their content.
            BashApprovalAdviceView(taskID: taskID, stepID: request.stepID) {
                Button("Allow") { resolve(.allow) }
                    .buttonStyle(.terminalPrimary)
                Button("Deny") { resolve(.deny) }
                    .buttonStyle(.terminalDanger)
                if request.offerAlways {
                    Button("Always allow") { resolve(.alwaysAllow) }
                        .buttonStyle(.terminalGhost)
                }
            }
            .id(request.createdAt)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceElevated))
    }

    private func resolve(_ choice: BashApprovalChoice) {
        store.resolveBashApproval(
            taskID: taskID, stepID: request.stepID, commandKey: request.commandKey, choice: choice)
    }
}

// MARK: - Bash approval "Ask AI" advice

/// The bash-approval action row plus its on-demand "Ask AI" second opinion. The
/// caller supplies the Allow/Deny(/Always) buttons as `actions` — they sit on the
/// left of the row and the read-only "Ask AI" button is pushed to the right, on the
/// same level. The judge verdict (read-only, no effect on the gate) renders below,
/// sized to its content. Host with `.id(request.createdAt)` so the in-flight advice
/// request + verdicts are scoped to a single held-command instance and never leak
/// across an identical re-held command.
private struct BashApprovalAdviceView<Actions: View>: View {
    let taskID: Int
    let stepID: String
    let actions: Actions

    @Environment(NTMSOrchestrator.self) private var store
    @State private var verdicts: [BashAdvice]? = nil
    /// The in-flight "Ask AI" request, or nil when idle. Owning the Task lets us
    /// cancel it (a) on a second tap of the button (toggle to stop), and (b) when
    /// the card is removed — which is exactly what pressing Allow/Deny does (it
    /// resolves the gate, the gate stops holding the command, the card disappears).
    /// `isLoading` is derived so there is a single source of truth.
    @State private var adviceTask: Task<Void, Never>? = nil

    private var isLoading: Bool { adviceTask != nil }

    init(taskID: Int, stepID: String, @ViewBuilder actions: () -> Actions) {
        self.taskID = taskID
        self.stepID = stepID
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                actions
                Spacer(minLength: Spacing.s)
                askAIButton
            }
            .controlSize(.small)

            if let verdicts {
                if verdicts.isEmpty {
                    // Reachable race: the held command resolved between the tap and the
                    // await, so there was nothing to assess. Say so instead of going blank.
                    Text("Nothing to review — the command was already resolved.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(verdicts) { verdict in
                            row(verdict)
                        }
                    }
                }
            }
        }
        // Allow/Deny resolve the gate and remove this card → cancel any in-flight
        // Ask AI so it doesn't keep running (or apply a now-stale verdict).
        .onDisappear { cancelAdvice() }
    }

    private var askAIButton: some View {
        // While loading the button stays tappable so a second tap stops Ask AI.
        Button { toggle() } label: {
            HStack(spacing: Spacing.xxs) {
                if isLoading {
                    NTMSLoader(font: Typography.termXs, color: Colors.accent)
                } else {
                    Image(systemName: "sparkles").accessibilityHidden(true)
                }
                Text(isLoading ? "Stop" : "Ask AI")
            }
        }
        .buttonStyle(.terminalSecondary)
        .fixedSize()
    }

    private func row(_ verdict: BashAdvice) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            StatusGlyph(
                glyph: verdict.allowed ? TerminalGlyph.done : TerminalGlyph.failed,
                color: verdict.allowed ? Colors.success : Colors.error)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                // The AI's read — what the command does + a safety opinion. Marked with
                // the Ask AI sparkles so it's clearly the SECOND OPINION; the ✅/❌ glyph
                // and the gate rationale below are the authoritative verdict. Hidden when
                // the explainer returned nothing (fail-soft empty).
                if !verdict.explanation.isEmpty {
                    HStack(alignment: .top, spacing: Spacing.xxs) {
                        Image(systemName: "sparkles")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.accent)
                            .accessibilityHidden(true)
                        Text(verdict.explanation)
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textSecondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The authoritative gate verdict's rationale (dimmer — the basis for the glyph).
                Text(verdict.reason)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tap handler: start Ask AI when idle, or stop it when already running.
    private func toggle() {
        if isLoading {
            cancelAdvice()
            return
        }
        // Keep any prior verdict visible while re-asking — it's replaced when the new
        // result lands. Blanking it here would leave the user with nothing if they then
        // tap Stop mid-refresh.
        adviceTask = Task {
            let result = await store.requestBashJudgeAdvice(taskID: taskID, stepID: stepID)
            // A second tap / Allow / Deny cancels us mid-flight — drop the result
            // so a stale verdict can't land after the user moved on.
            if Task.isCancelled { return }
            verdicts = result
            adviceTask = nil
        }
    }

    private func cancelAdvice() {
        adviceTask?.cancel()
        adviceTask = nil
    }
}
