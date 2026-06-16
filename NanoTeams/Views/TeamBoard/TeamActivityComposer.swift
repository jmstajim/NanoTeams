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
                maxTextFieldHeight: messageFieldMaxHeight
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

            // Body (hidden when collapsed): optional Thinking disclosure + question text.
            if !isQuestionCollapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if let thinking {
                            thinkingDisclosure(thinking: thinking, tint: askingColor)
                        }
                        Text(q.question)
                            .font(.callout)
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
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint.opacity(DynamicTintOpacity.stroke))
                        .rotationEffect(.degrees(isThinkingExpanded ? 90 : 0))
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Colors.textSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isThinkingExpanded {
                Text(thinking)
                    .font(.caption)
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
            if roleDefinitions.filter({ !$0.isSupervisor }).count <= 1 {
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

    /// Currently-working, non-supervisor, non-observer roles, excluding any role
    /// currently asking a Supervisor question (those roles have their own "Answer" chips).
    /// Only these are valid queue targets — queueing to an idle role would never flush.
    static func computeSelectableRoles(
        roles: [TeamRoleDefinition],
        workingRoleIDs: Set<String>,
        askingRoleIDs: Set<String>
    ) -> [TeamRoleDefinition] {
        roles.filter {
            !$0.isSupervisor
                && !$0.isObserver
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
                && !$0.isSupervisor
                && !$0.isObserver
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
            !$0.isSupervisor && !$0.isObserver && !askingRoleIDs.contains($0.id)
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
                icon: "arrowshape.turn.up.left.fill"
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
        failedRoleIDs: [],
        allowsRoleFallback: true,
        activeQuestions: [],
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
        failedRoleIDs: [],
        allowsRoleFallback: false,
        activeQuestions: [],
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

