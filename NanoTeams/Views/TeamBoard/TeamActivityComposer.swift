import SwiftUI

// MARK: - Active Question

/// Snapshot of the single active `ask_supervisor` question, if any.
/// For team tasks `StepExecution.id == effectiveRoleID == roleID` (see CLAUDE.md
/// §Common API pitfalls), so `askingRoleID` is a computed projection of `stepID`
/// rather than a stored field — this keeps the two values from ever drifting.
///
/// `paired` carries the assistant turn that emitted the question. When that turn
/// carried no prose, `isFullyRenderedByQuestionCard` is true: the feed suppresses
/// its bubble (so the turn doesn't appear twice) and this card shows the turn's
/// `thinking` in its disclosure. When the turn DID carry prose, the bubble stays
/// in the feed and owns the reasoning row, so this card shows the question alone
/// — otherwise the same reasoning would render twice. `paired == nil` means "no
/// preamble turn": nothing to suppress, disclosure hidden.
struct TeamActivityActiveQuestion: Equatable {
    let stepID: String
    let role: Role
    let question: String
    /// The questionnaire this step parked on, when it parked on one. Nil for a plain
    /// `ask_supervisor` — which is what lets the card render exactly as it did before, and is
    /// the common case (a chat-mode team takes it on every single turn).
    let inquiry: SupervisorInquiry?
    let paired: PairedAssistantMessage?
    /// The role's own `ask_supervisor` call, when this park came from one
    /// (`SupervisorQuestionInbox.PendingQuestion.askCallID`). Nil on a park the app raised —
    /// a loop or drift cap, the Autovisor's idle park — and that is the difference
    /// `[ Ask as form ]` turns on: a role that asked nothing cannot be told to ask again.
    let askCallID: UUID?

    /// Role id of the role currently asking. For team tasks this equals `stepID`
    /// by design (`StepExecution.id == roleID`); exposed as a computed property
    /// so callers don't accidentally pass different values.
    var askingRoleID: String { stepID }

    /// The reasoning row this card should render, if any.
    ///
    /// Non-nil only when the card owns the whole turn. A turn that also carried
    /// prose keeps its feed bubble, and that bubble already renders the same
    /// `thinking` via `MessageThinkingSection` — surfacing it here too would show
    /// the reasoning twice, the second time in a height-constrained card. Reuses
    /// `isFullyRenderedByQuestionCard`, the same predicate that decides feed
    /// suppression, so the two surfaces cannot disagree about who owns the turn.
    var cardThinking: String? {
        paired.flatMap { $0.isFullyRenderedByQuestionCard ? $0.thinking : nil }
    }

    /// Memberwise init expressed explicitly so `paired:` defaults to `nil` for
    /// routing/ordering tests that don't exercise the thinking-disclosure path.
    /// Production code always passes `paired:` from `PendingQuestion.paired`,
    /// so no default is leaked into a silent-failure path.
    init(
        stepID: String,
        role: Role,
        question: String,
        inquiry: SupervisorInquiry? = nil,
        paired: PairedAssistantMessage? = nil,
        askCallID: UUID? = nil
    ) {
        self.stepID = stepID
        self.role = role
        self.question = question
        self.inquiry = inquiry
        self.paired = paired
        self.askCallID = askCallID
    }

    /// The whole production mapping, in one place.
    ///
    /// The defaults above exist for routing and ordering tests that exercise none of these
    /// fields; production never picks a subset by hand, because doing so is how a field
    /// arrives at a surface as `nil` forever and the only symptom is a control that stopped
    /// appearing. `TeamActivityComposerQuestionMappingTests` reads this initializer, so
    /// "production passes everything" is a check rather than a comment.
    init(pending: SupervisorQuestionInbox.PendingQuestion) {
        self.init(
            stepID: pending.stepID,
            role: pending.role,
            question: pending.headline,
            inquiry: pending.inquiry,
            paired: pending.paired,
            askCallID: pending.askCallID)
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
    @State private var clippedTexts: [Clip] = []
    /// What the human has ticked and typed into the selected question's questionnaire.
    ///
    /// Beside `text` rather than inside the card, and for the same reason `text` is here: the
    /// card is rebuilt on every body pass, and an answer living in it would reset. It rides
    /// with the prose through the park, the return and the submit — a half-filled form is
    /// exactly as much of the Supervisor's work as a half-typed sentence.
    ///
    /// Paired with the questionnaire it was filled against (`SupervisorInquiryDraft`), because
    /// the composer's fields follow whichever chip is SELECTED — which is right for a sentence
    /// and wrong for a set of ticks. Retargeting to another role shows that role's blank form,
    /// the submit gate reads only the answers given to the question being answered, and nothing
    /// is deleted on the way: the draft is still here to be parked under the branch it was
    /// aimed at.
    @State private var inquiryDraft: SupervisorInquiryDraft? = nil
    /// `nil` = auto (the aimed chip wins via `resolveEffectiveRecipient`); else explicit pick.
    @State private var selectedRecipient: Recipient? = nil
    /// Which waiting question the composer PREFERS, when the user has not locked one.
    ///
    /// Deliberately not `selectedRecipient`. That one is the user's lock: it beats every later
    /// question by construction and nothing releases it because the composer went empty — so an
    /// app-made aim written there outlived the question it named, and after
    /// `remapEquivalentRecipient` turned it into a `.role` lock, every subsequent question got
    /// an Answer chip that never auto-selected. A preference is resolved against the row that
    /// is actually waiting (`SupervisorAnswerFocus.resolve`, the same rule Quick Capture
    /// applies to its own pick), so it simply stops matching instead of having to be revoked.
    @State private var answerAim: String? = nil
    /// Intrinsic height of the question preview content — used both to decide whether
    /// to draw the "more below" fade hint when the text overflows the cap, and to
    /// shrink the preview frame to content size for short questions (instead of a
    /// `ScrollView` greedily filling `MessageComposerLayout.questionPreviewMaxHeight` — which
    /// this comment called a flat "140pt cap" long after the cap stopped being one). Seeded
    /// with `.infinity` so the first render doesn't flash at zero height (CLAUDE.md #18).
    /// The seed also makes the gate above true on that first pass, so a short question shows
    /// the fade for one frame; at a fixed 20pt band that is a hint, at the 58pt the fraction
    /// used to produce in a tall pane it was a flash. Deliberately NOT
    /// reset on chip switch: when two questions render at the same intrinsic height,
    /// `onGeometryChange` does not fire (no value change), and a `.infinity` reseed
    /// would clamp the frame to `maxPreviewHeight` until the next geometry callback.
    @State private var questionContentHeight: CGFloat = .infinity
    /// Whether the question preview card is collapsed to a single header line.
    @State private var isQuestionCollapsed: Bool = false
    /// Whether the paired-message thinking disclosure is expanded. Only relevant
    /// when `q.cardThinking != nil` — i.e. when this card owns the turn; a
    /// prose-carrying turn keeps its reasoning on the feed bubble instead.
    /// Default collapsed: thinking is supplementary; user reaches for it only
    /// when the body alone is unclear.
    @State private var isThinkingExpanded: Bool = false

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StoreConfiguration.self) private var config

    private var formState: QuickCaptureFormState { QuickCaptureController.shared.formState }

    // MARK: - Recipient

    /// `.answer` cannot exist without a step id — answering without a question is unrepresentable.
    nonisolated enum Recipient: Hashable {
        case answer(stepID: String)
        case role(id: String)

        /// The role BOTH shapes address. For a team task `StepExecution.id == effectiveRoleID
        /// == roleID` (CLAUDE.md §Common API pitfalls), so answering X and queueing to X name
        /// one role and one conversation — the fill indicator keys on either chip without the
        /// composer re-deriving the mapping, `remapEquivalentRecipient` retargets between the
        /// two shapes, and `AnswerDraftKey.role` gives them one draft.
        ///
        /// On the enum rather than beside its callers: a `static roleID(for:)` in `+Routing`
        /// answered the same question, and the second copy is how a third one gets written.
        var roleID: String {
            switch self {
            case .answer(let stepID): stepID
            case .role(let id): id
            }
        }
    }

    // MARK: - Drafts

    /// The branch this recipient's unsent reply belongs to.
    ///
    /// Every chip names a role, so every draft here is a role's. Chat mode does NOT collapse
    /// them onto the task: Quest Party is a chat team with five roles, each with its own step
    /// and its own question, and one key for all five means the second parked reply destroys
    /// the first. `.taskChat` belongs to the ONE composer that names no role — Quick Capture's
    /// chat-working field — and `AnswerDraftKey.continues(into:)` is what keeps that composer
    /// and a role's answer from parking anything as the panel flips between them.
    ///
    /// Static and `nonisolated` so the mapping that makes this composer and the panel agree
    /// about a draft's name is reachable from a test — `Views/` is outside the coverage
    /// denominator, and a view-private mapping is one nobody checks.
    nonisolated static func draftKey(taskID: Int, recipient: Recipient) -> AnswerDraftKey {
        .role(TaskStepKey(taskID: taskID, stepID: recipient.roleID))
    }

    private func draftKey(for recipient: Recipient) -> AnswerDraftKey {
        Self.draftKey(taskID: taskID, recipient: recipient)
    }

    /// Whether the composer is holding anything at all. Reads the live fields rather than
    /// `canSubmit`, which additionally requires a reachable recipient — a draft whose
    /// recipient just vanished is precisely the case that has content and cannot be sent.
    ///
    /// A questionnaire with something ticked counts: it is the answer, and the chip it was
    /// aimed at can vanish under it exactly like a sentence's can.
    private var composerHasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || !clippedTexts.isEmpty
            || !(inquiryDraft?.isEmpty ?? true)
    }

    private func roleName(_ id: String) -> String {
        roleDefinitions.first(where: { $0.id == id })?.name ?? id
    }

    private func roleIcon(_ id: String) -> String {
        roleDefinitions.first(where: { $0.id == id })?.icon ?? "person"
    }

    // MARK: - Derived

    private var queuedMessages: [QuickCaptureFormState.QueuedChatMessage] {
        formState.queuedMessages(for: taskID)
    }

    /// Branches of THIS task holding an unsent reply no composer is currently editing.
    ///
    /// Derived from the store rather than kept in `@State`: a parked draft has to outlive this
    /// view, which is torn down and rebuilt on every task switch and every pane resize. The
    /// store's take-and-return contract is what makes the derivation exact — an entry exists
    /// exactly when nobody holds the content, so this can never offer the user back the text
    /// already in front of them.
    private var parkedDraftKeys: [AnswerDraftKey] {
        formState.answerDraftStore.keys(forTask: taskID)
    }

    // MARK: - Body

    var body: some View {
        contentColumn
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.s)
    }

    private var contentColumn: some View {
        // Derived ONCE per body pass. `effectiveRecipient` and `chipOptionsComputed` were
        // computed properties that each re-derived the same three role arrays plus
        // `askingRoleIDs`; `computeRouting` derives them together, so the chip row and the
        // resolver now cannot disagree by construction rather than by convention.
        //
        // `chipRecipients` is hoisted OUT of the `.onChange` key below deliberately: an
        // `onChange` key is evaluated on EVERY body pass whether or not the handler fires
        // (CLAUDE.md #113), so a `.map(\.recipient)` spelled inside it is per-pass work
        // wearing the look of "we only react to changes" — the shape the `a6` axis exists
        // to catch, and the reason this site was in its baseline.
        let routing = Self.computeRouting(
            roles: roleDefinitions,
            workingRoleIDs: workingRoleIDs,
            failedRoleIDs: failedRoleIDs,
            activeQuestions: activeQuestions,
            allowsRoleFallback: allowsRoleFallback,
            selected: selectedRecipient,
            aimedStepID: answerAim
        )
        let recipient = routing.effectiveRecipient
        let chipRecipients = routing.chipOptions.map(\.recipient)
        // Derived once per pass beside the routing, for the same reason: it filters and sorts
        // the whole draft map, and reading it from both the `if` and the list would pay twice.
        let parkedKeys = parkedDraftKeys
        // The question the composer is aimed at, if it is aimed at one, plus the answers this
        // draft holds FOR THAT question — derived once and read by the card, the submit gate
        // and the submit itself, so the three cannot disagree about which form is on screen.
        // Which chips wear a dot, derived once beside the keys it reads rather than asked per
        // pill — a `contains` inside the `ForEach` is a linear scan over the same array N times.
        let dottedRecipients = Self.unsentDraftRecipients(
            among: chipRecipients, taskID: taskID, parked: parkedKeys)
        // The role index the chip row reads, for the same reason. `uniquingKeysWith` because a
        // team CAN hold two roles under one id (an import, a hand-edited `teams.json`); the
        // first wins, which is what a `first(where:)` did anyway.
        let rolesByID = Dictionary(
            roleDefinitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let answeredQuestion = Self.question(for: recipient, among: activeQuestions)
        let heldAnswer = inquiryDraft?.answer(for: answeredQuestion?.inquiry)

        return VStack(alignment: .leading, spacing: Spacing.s) {
            RecipientChipRow(
                chips: chips(
                    from: routing.chipOptions, dotted: dottedRecipients, rolesByID: rolesByID),
                selection: recipient,
                leadingLabel: "To",
                badge: SupervisorAnswerFocus.waitingBadge(count: activeQuestions.count),
                onSelect: { selectedRecipient = $0 },
                accessory: { chip in
                    // Inside the pill, right of the name: the fill belongs to the conversation
                    // this chip addresses. Its own leaf view, so the fill's once-per-request
                    // change does not re-evaluate the row.
                    ContextFillIndicator(
                        taskID: taskID,
                        roleID: chip.id.roleID,
                        roleName: chip.label,
                        isOnAccent: recipient == chip.id)
                })

            if let answeredQuestion {
                questionPreviewCard(answeredQuestion)
            }

            if !queuedMessages.isEmpty {
                queuedList
            }
            if !parkedKeys.isEmpty {
                parkedDraftList(keys: parkedKeys, chipRecipients: chipRecipients)
            }
            MessageComposer(
                text: $text,
                attachments: $attachments,
                clips: $clippedTexts,
                placeholder: Self.placeholderText(
                    recipient: recipient,
                    workingRoleIDs: workingRoleIDs,
                    failedRoleIDs: failedRoleIDs,
                    roleDefinitions: roleDefinitions
                ),
                canSubmit: Self.computeCanSubmit(
                    text: text,
                    hasAttachments: !attachments.isEmpty,
                    hasClips: !clippedTexts.isEmpty,
                    hasInquiryAnswer: !(heldAnswer?.isEmpty ?? true),
                    effectiveRecipient: recipient
                ),
                isSubmitting: false,
                onSubmit: {
                    handleSubmit(
                        recipient: recipient,
                        inquiry: answeredQuestion?.inquiry,
                        heldAnswer: heldAnswer)
                },
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
        .onChange(of: text) { _, _ in
            selectedRecipient = Self.lockedRecipient(
                prior: selectedRecipient, auto: recipient, hasContent: composerHasContent)
        }
        // The same lock, for content that arrives with no keystroke at all. A questionnaire is
        // answered by ticking, and a keystroke-only lock left exactly that work unaimed: with
        // `selectedRecipient` still nil, `recipientToPark` has no `prior` to park under, so the
        // decisions were neither kept nor offered back when the chip left the row.
        .onChange(of: inquiryDraft) { _, _ in
            selectedRecipient = Self.lockedRecipient(
                prior: selectedRecipient, auto: recipient, hasContent: composerHasContent)
        }
        // When the chip the user previously tapped disappears (e.g. Answer chip
        // after answering, role chip after the role finishes), clear the explicit
        // selection so `resolveEffectiveRecipient`'s auto-resolution kicks back in.
        // Without this the placeholder/avatar/submit reflect a stale selection.
        .onChange(of: chipRecipients) { _, recipients in
            let prior = selectedRecipient
            // Retarget to the SAME role's other chip shape (`.role` ↔ `.answer`)
            // before treating the selection as lost. The Autovisor (and any
            // single-role chat task) flips working↔asking constantly — its idle
            // `wait_for_events` park swaps the working-role chip for an Answer chip
            // mid-compose — and a bare stale-selection drop would lose the explicit
            // lock and wipe the half-typed draft on every such transition.
            let sanitized = Self.remapEquivalentRecipient(
                prior: prior, availableRecipients: recipients
            )
            if let lost = Self.recipientToPark(
                prior: prior, sanitized: sanitized, hasContent: composerHasContent
            ) {
                // Park, don't destroy. The event that took the chip away — a parallel role
                // finishing, the question answered from Watchtower or Quick Capture — is not
                // one the user caused, and the banner that used to announce the loss could
                // not give the words back.
                formState.answerDraftStore.save(
                    AnswerDraft(
                        text: text, attachments: attachments, clippedTexts: clippedTexts.texts,
                        inquiry: inquiryDraft
                    ),
                    for: draftKey(for: lost)
                )
                clearComposer()
            }
            selectedRecipient = sanitized
        }
    }

    // MARK: - Recipient Chips (horizontal pill row)

    /// The row's pills, from the chips the router produced plus the two facts only this view
    /// has: what colour each recipient wears, and which of them is holding an unsent reply.
    ///
    /// The mapping itself is mechanical; everything in it that can be WRONG is already pure
    /// and tested elsewhere — the order and the labels in `computeChipOptions`, the dots in
    /// `unsentDraftRecipients`, the badge in `SupervisorAnswerFocus`. What keeps it here is
    /// `resolvedTintColor`, which is a `Views/DesignSystem` member and so main-actor-isolated:
    /// a `nonisolated static` mapping could not have called it.
    /// - Parameter rolesByID: the pass's role index. A `first(where:)` per pill is a linear
    ///   scan of the team inside a loop over the team — the `a1` shape
    ///   (`coverage/tools/algorithmic_complexity.py`), and the chip row is rebuilt on every
    ///   body pass of a composer that sits under a streaming feed. One index, built once.
    private func chips(
        from options: [ChipOption], dotted: Set<Recipient>,
        rolesByID: [String: TeamRoleDefinition]
    ) -> [RecipientChip<Recipient>] {
        options.map { option in
            RecipientChip(
                id: option.recipient,
                label: option.label,
                icon: option.icon,
                tint: Self.chipTint(option.recipient, rolesByID: rolesByID),
                hasUnsentDraft: dotted.contains(option.recipient))
        }
    }

    /// The pill's selected fill. An Answer chip wears the asking role's tint so the chip and
    /// that role's avatar in the feed agree about who is being addressed; everything else
    /// wears the accent.
    private static func chipTint(
        _ recipient: Recipient, rolesByID: [String: TeamRoleDefinition]
    ) -> Color {
        guard case .answer(let stepID) = recipient, let roleDef = rolesByID[stepID]
        else { return Colors.accent }
        return roleDef.resolvedTintColor
    }

    private func questionPreviewCard(_ q: TeamActivityActiveQuestion) -> some View {
        let askingColor = roleDefinitions.first(where: { $0.id == q.askingRoleID })?.resolvedTintColor ?? Colors.accent
        // The SAME budget a plain question gets, questionnaire or not. A per-question
        // allowance was written and then deleted: `questionPreviewChrome` already means
        // "everything the message field does not need", so a form cannot be given more
        // without pushing the field below its floor, and every fraction-of-the-pane rule
        // that fits inside that bound is TIGHTER than this one at any pane over ~430pt —
        // a budget whose every setting shrank the form it was written to enlarge.
        let maxPreviewHeight = MessageComposerLayout.questionPreviewMaxHeight(maxHeight: maxHeight)
        let thinking = q.cardThinking

        return VStack(alignment: .leading, spacing: 0) {
            // Header: role icon + "Role asks:" + [ Ask as form ] + collapse chevron.
            // Collapsed header truncates the question to a single line.
            //
            // TWO buttons for ONE action, and the split is forced: `[ Ask as form ]` is an
            // interactive control that has to live on this row, and a Button inside another
            // Button's label does not receive clicks on macOS — the outer one takes them
            // (same family as CLAUDE.md #17). So the row is two tap regions around the
            // control, both calling `toggleQuestion()`, which is where the decision is
            // written once.
            HStack(spacing: Spacing.xs) {
                Button(action: toggleQuestion) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: roleIcon(q.askingRoleID))
                            .font(Typography.captionSemibold)
                            .foregroundStyle(askingColor)
                        // One line, truncating: the row used to be a single HStack where a
                        // long custom role name WRAPPED, which on a narrow board pushed the
                        // chevron and the button down a line. `fixedSize()` would trade that
                        // for overflow instead.
                        Text("\(roleName(q.askingRoleID)) asks:")
                            .font(Typography.captionSemibold)
                            .foregroundStyle(askingColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // On the row that NAMES the question rather than under it: the button asks
                // the role to re-ask, so it belongs beside "<Role> asks:" and not at the end
                // of a body the reader has to scroll. It stays put when collapsed — a
                // control that vanishes on fold reads as a bug — and the one-line preview
                // beside it truncates a little earlier for it.
                if SupervisorQuestionnaireRequest.isAvailable(
                    inquiry: q.inquiry, askCallID: q.askCallID)
                {
                    QuestionnaireRequestButton {
                        requestQuestionnaire(stepID: q.stepID)
                    }
                }

                Button(action: toggleQuestion) {
                    HStack(spacing: Spacing.xs) {
                        if isQuestionCollapsed {
                            Text(q.question)
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: Spacing.xs)
                        DisclosureChevron(isExpanded: !isQuestionCollapsed)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xsPlus)

            // Body (hidden when collapsed): optional Thinking disclosure + question text.
            if !isQuestionCollapsed {
                ScrollView {
                    // Two rhythms, nested, because there are two: `Spacing.xs` binds the
                    // Thinking row to the headline it belongs to, and `headlineGap` separates
                    // that block from the form. Flat at 4pt, the headline sat closer to the
                    // first question than the first question sat to the second — which reads
                    // as the headline belonging to question one.
                    VStack(alignment: .leading, spacing: SupervisorInquiryCard.headlineGap) {
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
                        // The questionnaire, when the role asked one. Inside the same scroll
                        // area as the headline above it, because the two are one question —
                        // and the headline is the sentence the form is the detail of.
                        if let inquiry = q.inquiry {
                            SupervisorInquiryCard(inquiry: inquiry, draft: $inquiryDraft)
                        }
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
                // A 20pt band, not the 12 % the hand-written `0.88` stop meant: against a
                // 480pt cap that fraction dimmed the last three and a half lines of the
                // question, and against the 80pt floor it shrank to half a line. It also fits
                // inside the `Spacing.xl` bottom padding above, so a reader scrolled to the
                // end of the question loses no text at all.
                //
                // `length:` is `maxPreviewHeight`, NOT the `min(...)` frame on the line above.
                // Inside the branch that draws a gradient the two are the same number — the
                // gate IS `questionContentHeight > maxPreviewHeight` — and only
                // `maxPreviewHeight` is finite by construction, while `questionContentHeight`
                // is seeded `.infinity` (see its declaration). Passing the `min` would make
                // the stop's correctness depend on the gate beside it, and the `inf / inf`
                // waiting one edit away is a NaN location, i.e. a mask that empties the card.
                .edgeFade(
                    .bottom,
                    length: maxPreviewHeight,
                    isActive: questionContentHeight > maxPreviewHeight
                )
            }
        }
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
        )
        // No `.clipShape` here, and that is #50 rather than taste: since 2026-09-11 the
        // questionnaire's free-text answer is an `NSScrollView`-backed representable INSIDE this
        // card, and #50's correct pattern names `.clipShape` as the offscreen mask pass per CA
        // frame such an editor emits. It was clipping nothing anyway — both the header row and
        // the scroll content carry `Spacing.s` of horizontal padding, so no ink reaches a 2pt
        // corner. The static `.background` above stays: a constant shape layer is the ancestor
        // form the lineage explicitly blesses (docs/architecture/swiftui-appkit-lineage.md#rule-50).
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
                    DisclosureChevron(
                        isExpanded: isThinkingExpanded,
                        color: tint.opacity(DynamicTintOpacity.stroke))
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

    // MARK: - Parked drafts (unsent replies whose chip left the row)

    /// One row per parked branch, in the shape of `queuedRow` — both say "something you wrote
    /// is not in the field and not sent yet", and a second visual language for that would be a
    /// second thing to learn.
    private func parkedDraftList(
        keys: [AnswerDraftKey], chipRecipients: [Recipient]
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(keys, id: \.self) { key in
                parkedDraftRow(key: key, chipRecipients: chipRecipients)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(Animations.spring, value: keys)
    }

    private func parkedDraftRow(key: AnswerDraftKey, chipRecipients: [Recipient]) -> some View {
        let recipientName = key.roleID.map(roleName) ?? "Team"
        let draft = formState.answerDraftStore.peek(for: key)
        let firstLine = (draft?.text ?? "")
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            ?? ""
        let attachmentCount = (draft?.attachments.count ?? 0) + (draft?.clippedTexts.count ?? 0)
        // A draft with no prose is one of two things, and "0 attachment(s)" describes neither:
        // files/clips dropped without a word, or a questionnaire half filled in.
        let preview: String
        if !firstLine.isEmpty {
            preview = firstLine
        } else if attachmentCount > 0 {
            preview = "\(attachmentCount) attachment(s)"
        } else {
            preview = "questionnaire answers"
        }
        // The composer already holds something else; returning would have to displace it, and
        // silently parking THAT is the move this row exists to stop doing.
        let canReturn = !composerHasContent

        return HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.uturn.backward")
                .font(Typography.caption2)
                .foregroundStyle(Colors.textTertiary)
            Text("Unsent to \(recipientName):")
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
                    returnParkedDraft(key: key, chipRecipients: chipRecipients)
                }
            } label: {
                Text("Return")
                    .font(Typography.captionSemibold)
                    .foregroundStyle(canReturn ? Colors.accent : Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canReturn)
            .help(canReturn
                ? "Put this text back in the composer"
                : "Send or clear what you are writing first")
            .accessibilityLabel("Return unsent draft to \(recipientName)")
            Button {
                withAnimation(Animations.spring) { discardParkedDraft(key: key) }
            } label: {
                Image(systemName: "xmark")
                    .font(Typography.caption2.weight(.semibold))
                    .foregroundStyle(Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Discard this unsent draft")
            .accessibilityLabel("Discard unsent draft to \(recipientName)")
        }
        .padding(.horizontal, Spacing.s - 2)
        .padding(.vertical, Spacing.xxs)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
        )
    }

    /// Takes the draft back into the composer, aimed at its own chip when that chip is back in
    /// the row and at whatever the resolver picks when it is not.
    ///
    /// Aiming is a best effort on purpose. The role may be genuinely gone, and the text is
    /// still the user's — handing it back so they can send it somewhere else is what the old
    /// discard banner asked them to do from memory.
    ///
    /// `chipRecipients` is the row's own body-pass value rather than a fresh `computeRouting`:
    /// the composer derives its routing exactly ONCE per pass (`BodyPassHoistPinTests`), and a
    /// second derivation inside an action closure would be both a pin violation and a second
    /// answer to a question the pass already answered.
    private func returnParkedDraft(key: AnswerDraftKey, chipRecipients: [Recipient]) {
        guard let draft = formState.answerDraftStore.take(for: key) else { return }
        text = draft.text
        attachments = draft.attachments
        clippedTexts = [Clip].minting(draft.clippedTexts)
        inquiryDraft = draft.inquiry
        selectedRecipient = chipRecipients.first { draftKey(for: $0) == key } ?? selectedRecipient
    }

    /// Drops the draft AND the files it was carrying. The staged copies live under
    /// `.nanoteams/staged/<draftID>/` and nothing else references them once the draft is gone,
    /// so leaving them behind grows the folder silently. `removeStagedAttachment` and not a
    /// direct delete: an in-project attachment is a reference to the user's own file.
    private func discardParkedDraft(key: AnswerDraftKey) {
        if let draft = formState.answerDraftStore.take(for: key) {
            for attachment in draft.attachments {
                store.removeStagedAttachment(attachment)
            }
        }
    }

    // MARK: - Submit

    /// Takes the recipient the body pass resolved rather than re-deriving it.
    ///
    /// Not only cheaper: `canSubmit` is computed from the pass-time recipient, so
    /// re-resolving here could gate on one value and act on another. Every input to
    /// `computeRouting` forces a body pass when it changes, so the captured value cannot
    /// be stale by the time the button is tapped.
    /// Folds and unfolds the question card. One method because the header row is two tap
    /// regions with `[ Ask as form ]` between them (see `questionPreviewCard`), and a
    /// duplicated `withAnimation { toggle() }` is a duplicated decision about the animation.
    private func toggleQuestion() {
        withAnimation(Animations.spring) {
            isQuestionCollapsed.toggle()
        }
    }

    /// Sends the "re-ask this as a form" directive instead of an answer.
    ///
    /// Borrows `performAnswerSubmit` for its one job: clear before the await, restore if the
    /// step turned out to be gone. Only the TEXT is snapshotted and cleared — it rides along as
    /// the note that narrows the form — because attachments and clips are not part of a request
    /// to re-ask, and clearing them here would discard files the Supervisor staged for the
    /// answer they are still going to write.
    private func requestQuestionnaire(stepID: String) {
        let snapshotText = text
        Task {
            await Self.performAnswerSubmit(
                snapshotText: snapshotText,
                snapshotAttachments: [],
                snapshotClips: [],
                clear: { text = "" },
                submit: {
                    await store.requestQuestionnaire(
                        stepID: stepID, taskID: taskID, note: snapshotText)
                },
                restore: { restored, _, _ in text = restored }
            )
        }
    }

    private func handleSubmit(
        recipient: Recipient?, inquiry: SupervisorInquiry?, heldAnswer: SupervisorInquiryAnswer?
    ) {
        let built = AnswerTextBuilder.build(
            text: text,
            clips: clippedTexts.texts,
            attachments: attachments,
            embedFiles: config.embedFilesInPrompt
        )
        if let banner = Self.bannerForFailedFiles(built.failedFiles) {
            store.lastErrorMessage = banner
        }

        switch recipient {
        case .answer(let stepID):
            // Compile-guaranteed: `.answer` always carries a step id (no runtime guard).
            let finalized = attachments
            let snapshotText = text
            let snapshotClips = clippedTexts.texts
            // Captured rather than threaded through `performAnswerSubmit`: the restore
            // closure is the caller's, so a fourth field costs a capture instead of a fourth
            // parameter on a contract three tests already pin.
            let snapshotInquiry = inquiryDraft
            // Where the composer aims once this one is answered — computed from the row as it
            // stands NOW, because that is the row the answered question still has a position
            // in. Nil when nothing else is waiting, which leaves the resolver free exactly as
            // an unset selection always has.
            let nextAim = Self.nextAimAfterAnswer(
                answeredStepID: stepID, among: activeQuestions)
            // Minted whenever the step is parked on a questionnaire, EVEN when the card was
            // never touched: its presence is what says a person answered, and without it their
            // prose is read back with the grammar written for a model's `Q2: 1, 3` reply. The
            // note is what they TYPED — `built.answer` additionally carries clip and
            // attached-file sections, and whole file bodies under `embedFilesInPrompt`.
            let submission = inquiry.map { _ in
                SupervisorInquirySubmission(
                    answer: heldAnswer ?? SupervisorInquiryAnswer(),
                    note: snapshotText)
            }
            Task {
                await Self.performAnswerSubmit(
                    snapshotText: snapshotText,
                    snapshotAttachments: finalized,
                    snapshotClips: snapshotClips,
                    clear: {
                        clearComposer()
                        // AFTER the clear, which empties the aim along with everything else:
                        // this is the one piece of composer state a submit SETS.
                        answerAim = nextAim
                    },
                    submit: {
                        await store.answerSupervisorQuestion(
                            stepID: stepID, taskID: taskID,
                            answer: built.answer, attachments: finalized,
                            submission: submission
                        )
                    },
                    restore: { t, a, c in
                        text = t
                        attachments = a
                        clippedTexts = [Clip].minting(c)
                        inquiryDraft = snapshotInquiry
                        // The aim comes back too, as a PREFERENCE. Without it the restored
                        // reply sits under the NEXT question's chip — the submit moved the
                        // composer on before it knew the submit had failed — and the next press
                        // would answer the wrong role with it. As a preference rather than a
                        // lock, the branch where the question is genuinely gone (the step was
                        // restarted, which is one of the two ways this submit fails) falls back
                        // to the resolver instead of pinning Send to a chip that is not there.
                        answerAim = stepID
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
                text: text, attachments: attachments, clippedTexts: clippedTexts.texts,
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
        clippedTexts = [Clip].minting(cleared.clips)
        inquiryDraft = cleared.inquiry
        selectedRecipient = cleared.selectedRecipient
        answerAim = cleared.answerAim
    }

    // MARK: - Chip Option (internal for test access)

    nonisolated struct ChipOption: Identifiable, Equatable {
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
