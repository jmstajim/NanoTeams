import SwiftUI

// MARK: - Supervisor Inquiry Card

/// The questionnaire an `ask_supervisor_form` call asks, as something to fill in.
///
/// One card for both answering surfaces — the docked `TeamActivityComposer` and the Quick
/// Capture panel. They are the same questions with the same rules, and a second rendering of
/// them would be a second place for "marked is not chosen" to be got wrong.
///
/// **It owns no answer.** The binding points at the draft (`AnswerDraft.inquiry`), never at view
/// state, for a reason that is specific rather than stylistic: the Quick Capture panel re-hosts
/// its `NSHostingView` whenever the resolved mode changes identity, and a half-filled form
/// living in `@State` would reset to blank mid-fill. What DOES live here is `collapsed`, which
/// is presentation — losing it costs a chevron, not an answer.
///
/// **And it reads only its OWN answers.** The binding is a `SupervisorInquiryDraft`, so what
/// the card shows is `draft.answer(for: inquiry)`: ticks given to a different questionnaire —
/// another role's, or a round this role has since replaced — render as nothing, and the first
/// edit replaces them wholesale under this form's identity. Question ids are unique only within
/// one questionnaire, so id-matching alone is not enough: a local model asked the same stock
/// question twice emits the same slug both times.
///
/// **Marked is not chosen** (`TerminalChoiceList` carries the same rule and the same reason):
/// the option `recommendedOptionID` names — none, on most questions — wears a RECOMMENDED
/// badge and starts unticked. Agreement with a recommendation
/// has to be given, and a card that pre-ticked it would collect agreement nobody gave. Nothing
/// downstream repairs that: since 2026-09-12 an untouched question is reported to the asking
/// role as unanswered and nothing is filled in, so a tick on this card is the only thing that
/// can ever say the Supervisor decided.
struct SupervisorInquiryCard: View {
    let inquiry: SupervisorInquiry
    @Binding var draft: SupervisorInquiryDraft?

    /// The gap a HOST leaves between the question's headline and this card.
    ///
    /// Published because the two hosts disagreed — 4pt in the composer, 12 in Quick Capture —
    /// while the rhythm BETWEEN questions inside the card is 12 on both. The composer's 4
    /// therefore bound the headline tighter to the first question than that question was bound
    /// to the second, which reads as the headline belonging to question one.
    static let headlineGap: CGFloat = Spacing.m

    /// How tall a free-text answer grows before it scrolls. Four lines is the `1...4` the field
    /// carried as a `lineLimit` before it became a real bounded editor.
    private static let freeTextLineCap = 4

    /// Questions the human folded away. Not in the draft: a fold is a reading aid, and
    /// carrying it between surfaces would mean one surface deciding what the other shows.
    @State private var collapsed: Set<String> = []

    /// Which free-text field holds the caret, or `nil`. One slot rather than a `Bool` per
    /// question: focus IS mutually exclusive, and two sources for one fact is two states that
    /// can disagree.
    @State private var focusedQuestionID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(Array(inquiry.questions.enumerated()), id: \.element.id) { index, question in
                questionSection(number: index + 1, question: question)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - One question

    @ViewBuilder
    private func questionSection(number: Int, question: SupervisorInquiryQuestion) -> some View {
        let isCollapsed = collapsed.contains(question.id)

        VStack(alignment: .leading, spacing: Spacing.xs) {
            header(number: number, question: question, isCollapsed: isCollapsed)

            if !isCollapsed {
                if let detail = question.detail, !detail.isEmpty {
                    // 12/secondary — the ladder's "Secondary" rung, the same one
                    // `TerminalChoiceList` gives an option's reasoning. This is a sentence the
                    // role wrote to explain the question, not a tag.
                    Text(detail)
                        .font(Typography.termSm)
                        .foregroundStyle(Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if question.kind.isChoice {
                    TerminalChoiceList(
                        options: Self.choiceOptions(for: question),
                        mode: question.kind == .multiChoice ? .multiple : .single,
                        selection: selectionBinding(for: question)
                    )
                }

                freeTextRow(question)
            }
        }
    }

    /// Number, prompt, and what kind of answer is wanted. The whole row folds the question.
    ///
    /// Collapsed, it shows the answer as the MODEL will read it
    /// (`SupervisorInquiryRenderer.renderAnswer`) rather than a second summary written here:
    /// a fold that described the answer differently from the wire would be a fold that lies
    /// about what is about to be sent.
    private func header(
        number: Int, question: SupervisorInquiryQuestion, isCollapsed: Bool
    ) -> some View {
        let summary = SupervisorInquiryRenderer.renderAnswer(
            to: question, answer: held?.byQuestionID[question.id])

        return Button {
            withAnimation(reduceMotion ? nil : Animations.quick) {
                if isCollapsed { collapsed.remove(question.id) } else { collapsed.insert(question.id) }
            }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    DisclosureChevron(isExpanded: !isCollapsed)
                    Text("\(number). \(question.prompt)")
                        .font(Typography.termBase.weight(.medium))
                        .foregroundStyle(Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MonoLabel(text: Self.kindLabel(question.kind), size: .xs)
                }
                if isCollapsed {
                    // The pair the composer's own collapsed preview wears one row above this
                    // card (`TeamActivityComposer.questionPreviewCard`): 11/secondary, one line,
                    // tail-truncated. A fold is a PREVIEW, and the two previews in the same
                    // header should not be two sizes.
                    Text(summary)
                        .font(Typography.termXs)
                        .foregroundStyle(Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, Spacing.m)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Question \(number): \(question.prompt)")
        .accessibilityValue(summary)
    }

    // MARK: - Free text

    /// The free-text half of a question.
    ///
    /// Always open for a `freeText` question — there is nothing else to answer with. For a
    /// choice question it is the escape hatch, closed until asked for: the model's options can
    /// all be wrong, and a questionnaire with no way to say so is a dead end. Openness is
    /// stored as `freeText == ""` rather than in view state, so the field the human opened is
    /// still open after the panel re-hosts itself.
    @ViewBuilder
    private func freeTextRow(_ question: SupervisorInquiryQuestion) -> some View {
        let current = held?.freeText(for: question.id)

        if !question.kind.isChoice {
            editor(question, placeholder: "Your answer…", isEscape: false)
        } else if current == nil {
            // The design system's own word for a secondary action: `[ Other… ]`. It was a
            // hand-rolled `.plain` button with its own 10pt type, padding and hit area — three
            // decisions the style already owns, in a row where the only other action (the
            // choice marks) is drawn in `Colors.accent`.
            Button("Other…") {
                withAnimation(reduceMotion ? nil : Animations.quick) {
                    setFreeText("", for: question.id)
                }
            }
            .buttonStyle(.terminalGhost)
            .help("Answer this question in your own words instead")
        } else {
            editor(question, placeholder: "In your own words…", isEscape: true)
        }
    }

    /// The bounded multi-line editor, per CLAUDE.md #32.
    ///
    /// `TextField(axis: .vertical).lineLimit(1...4)` until 2026-09-11, which on macOS is an
    /// `NSTextField`: Return means "end editing" there, and with no `onSubmit` attached it meant
    /// nothing at all — so a Supervisor writing a two-paragraph answer could not start the second
    /// one. `onReturnKey` returning `false` hands the key back to `NSTextView`, which inserts the
    /// newline natively and keeps the caret in view; submitting stays the composer's job.
    private func editor(
        _ question: SupervisorInquiryQuestion, placeholder: String, isEscape: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            EditableMessageTextView(
                text: freeTextBinding(for: question.id),
                isFocused: focusBinding(for: question.id),
                placeholder: placeholder,
                maxHeight: EditableMessageTextView.height(lines: Self.freeTextLineCap),
                minLineCount: 1,
                // An escape hatch is opened by a click that asked for it, so the caret belongs
                // in it. A `freeText` question's field is just there when the card appears, and
                // autofocusing it would steal the caret from the composer's own message field.
                autofocusOnAppear: isEscape,
                onReturnKey: { _, _ in false })
                // Border only: the fill is AppKit-drawn by `InputSurface.stamp` inside the
                // representable, and #50 forbids wrapping it in SwiftUI layers.
                .inputSurfaceBorder()
                .accessibilityLabel("Answer to question: \(question.prompt)")

            if isEscape {
                Button {
                    withAnimation(reduceMotion ? nil : Animations.quick) {
                        setFreeText(nil, for: question.id)
                    }
                } label: {
                    // No `.font` here: the innermost application wins, and this glyph's 10pt
                    // made it the one composer icon smaller than the cell it sits in.
                    Image(systemName: "xmark")
                        .foregroundStyle(Colors.textTertiary)
                }
                // The composer's own icon cell, applied by the ONE seam that owns it
                // (`IconButtonHitAreaPinTests`): a hand-rolled frame here would be a second
                // place the cell's size is decided, and a `.plain` glyph would leave every
                // pixel around the × dead (CLAUDE.md #12).
                .buttonStyle(.composerIcon)
                .help("Close this field and answer with the options above")
                .accessibilityLabel("Close free-text answer")
            }
        }
    }

    // MARK: - Bindings

    private func selectionBinding(for question: SupervisorInquiryQuestion) -> Binding<Set<String>> {
        Binding(
            get: { held?.selection(for: question.id) ?? [] },
            set: { picked in
                write((held ?? SupervisorInquiryAnswer()).settingSelection(picked, for: question))
            }
        )
    }

    /// One question's half of the single focus slot: reading it asks "is the caret here", and
    /// writing `false` only clears the slot when it is still THIS question's — so a field losing
    /// focus to its neighbour cannot blank the neighbour's claim on the way out.
    private func focusBinding(for questionID: String) -> Binding<Bool> {
        Binding(
            get: { focusedQuestionID == questionID },
            set: { isFocused in
                if isFocused {
                    focusedQuestionID = questionID
                } else if focusedQuestionID == questionID {
                    focusedQuestionID = nil
                }
            }
        )
    }

    private func freeTextBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { held?.freeText(for: questionID) ?? "" },
            set: { setFreeText($0, for: questionID) }
        )
    }

    private func setFreeText(_ text: String?, for questionID: String) {
        write((held ?? SupervisorInquiryAnswer()).settingFreeText(text, for: questionID))
    }

    /// What the draft holds FOR THIS questionnaire — nil when it holds someone else's.
    private var held: SupervisorInquiryAnswer? { draft?.answer(for: inquiry) }

    /// Writes back under THIS questionnaire's identity, replacing whatever the draft held.
    ///
    /// Replacing rather than merging is the point: the moment a person edits the form on
    /// screen, whatever was in the bucket was for a different set of questions and is not
    /// theirs to keep. An answer holding no entries at all is spelled `nil`, so "the human has
    /// touched nothing" has ONE representation — two would reach `AnswerDraft.isEmpty` as the
    /// same verdict and the draft store as different values.
    private func write(_ updated: SupervisorInquiryAnswer) {
        draft = updated.byQuestionID.isEmpty
            ? nil
            : SupervisorInquiryDraft(inquiry: inquiry, answer: updated)
    }

    // MARK: - Pure bits

    /// The choice rows, with the badge on the option `recommendedOption` names — and on no
    /// option at all when the model recommended nothing, which is most questions.
    ///
    /// Asked of `recommendedOption` rather than open-coded as `index == 0`: that property IS
    /// the rule, and it is in `Domain/` where a test reaches it. It stopped being a position
    /// on 2026-09-12 precisely because a position cannot say "I have no preference".
    ///
    /// `nonisolated static` for the reason `TerminalChoiceList.toggling` is: `NanoTeams/Views/`
    /// is outside the coverage denominator, so the part of a card that can be WRONG about the
    /// model's data belongs where a test can reach it.
    nonisolated static func choiceOptions(
        for question: SupervisorInquiryQuestion
    ) -> [TerminalChoiceList<String>.Option] {
        question.options.map { option in
            TerminalChoiceList<String>.Option(
                id: option.id,
                label: option.label,
                detail: option.detail,
                badge: option.id == question.recommendedOption?.id ? "recommended" : nil)
        }
    }

    /// What kind of answer the question wants, for a human. Deliberately NOT the wire's
    /// `(pick one)` hint: that one is model-facing text in `RuntimePromptRegistry`, and
    /// sharing the string would tie a label the user reads to a prompt fingerprint.
    nonisolated static func kindLabel(_ kind: SupervisorInquiryKind) -> String {
        switch kind {
        case .freeText: "free text"
        case .singleChoice: "pick one"
        case .multiChoice: "pick any"
        }
    }
}

#if DEBUG
/// The questionnaire both previews below render, so the blank and the half-filled states are
/// demonstrably the same form and differ only in what has been answered.
private enum InquiryCardPreview {
    static let inquiry = SupervisorInquiry(
        headline: "A few decisions before I start on the exporter.",
        questions: [
            SupervisorInquiryQuestion(
                id: "scheme", prompt: "Which scheme should I build against?",
                detail: "The tests only run under one of them.",
                kind: .singleChoice,
                options: [
                    SupervisorInquiryOption(id: "debug", label: "NanoTeams (Debug)",
                                            detail: "Recommended. What CI uses"),
                    SupervisorInquiryOption(id: "release", label: "NanoTeams (Release)"),
                ],
                // One of the three carries a recommendation and two do not — the field ratio,
                // and the only way the previews below still show a RECOMMENDED badge at all
                // now that it follows what the model said instead of `options[0]`.
                recommendedOptionID: "debug"),
            SupervisorInquiryQuestion(
                id: "suites", prompt: "Which suites should I run before I report back?",
                kind: .multiChoice,
                options: [
                    SupervisorInquiryOption(id: "unit", label: "Unit tests"),
                    SupervisorInquiryOption(id: "ui", label: "UI tests",
                                            detail: "slow, and flaky on CI"),
                ]),
            SupervisorInquiryQuestion(
                id: "notes", prompt: "Anything else I should know?",
                kind: .freeText),
        ])

    /// One choice taken, one question answered in the escape hatch. The states the card can
    /// be in that a blank draft never shows: a ticked mark beside a RECOMMENDED tag, an open
    /// free-text field with content, and a fold with something to summarise.
    static let partlyAnswered = SupervisorInquiryDraft(
        inquiry: inquiry,
        answer: SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"]),
            "suites": .init(freeText: "Only the ones that touch the exporter."),
        ]))
}

/// Hosted on `surfaceElevated` — the composer's real host, and the darkest of the three the
/// card renders on. The 10px tertiary captions this card used to draw measured 3.08:1 here.
#Preview("Inquiry Card — blank") {
    @Previewable @State var draft: SupervisorInquiryDraft? = nil

    return ScrollView {
        SupervisorInquiryCard(inquiry: InquiryCardPreview.inquiry, draft: $draft)
            .padding(Spacing.l)
    }
    .frame(width: 460, height: 520)
    .background(Colors.surfaceElevated)
}

#Preview("Inquiry Card — partly answered") {
    @Previewable @State var draft: SupervisorInquiryDraft? = InquiryCardPreview.partlyAnswered

    return ScrollView {
        SupervisorInquiryCard(inquiry: InquiryCardPreview.inquiry, draft: $draft)
            .padding(Spacing.l)
    }
    .frame(width: 460, height: 520)
    .background(Colors.surfaceElevated)
}
#endif
