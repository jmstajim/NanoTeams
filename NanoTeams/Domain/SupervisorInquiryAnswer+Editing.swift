import Foundation

// MARK: - Editing a questionnaire answer

/// What a card does to an answer as the human fills it in.
///
/// Pure and in `Domain/` rather than inside the card's `body`, because `NanoTeams/Views/` is
/// outside the measured coverage denominator and a rule spelled there is a rule nobody checks.
/// Two surfaces render the same questionnaire — the docked composer and the Quick Capture
/// panel — so a rule each of them spelled itself would be two rules with two fates.
///
/// Every returned value is a WHOLE answer, never an in-place mutation: the answer lives in a
/// draft that is parked, taken and handed between composers (`AnswerDraft.inquiryAnswer`), and
/// a value type that is copied at each of those seams cannot be half-written by one of them.
nonisolated extension SupervisorInquiryAnswer {

    /// What is ticked for this question right now.
    ///
    /// A `Set` because that is what a choice list binds to, and because the ORDER of a
    /// multiple selection carries no meaning the caller does not already have — the only
    /// order that means anything is the order the model wrote the options in.
    func selection(for questionID: String) -> Set<String> {
        Set(byQuestionID[questionID]?.selectedOptionIDs ?? [])
    }

    /// The answer after `ids` becomes this question's selection.
    ///
    /// Stored back in the QUESTION's option order rather than the set's iteration order,
    /// which is unstable across launches: the persisted answer, the prose the model reads and
    /// the transcript the feed re-renders would otherwise list the same two choices in a
    /// different order every time they were written.
    ///
    func settingSelection(
        _ ids: Set<String>, for question: SupervisorInquiryQuestion
    ) -> SupervisorInquiryAnswer {
        let ordered = question.options.map(\.id).filter { ids.contains($0) }
        var entry = byQuestionID[question.id] ?? QuestionAnswer()
        entry.selectedOptionIDs = ordered
        return replacing(entry, for: question.id)
    }

    /// This question's free text, or nil when the field is not open.
    ///
    /// Nil and `""` are DIFFERENT states and the difference is the whole reveal mechanism: a
    /// choice question hides its "other" field until the human asks for one, and `""` is that
    /// request. Keeping it in the answer rather than in the card's `@State` is what lets the
    /// open field survive the Quick Capture panel re-hosting its view mid-fill.
    func freeText(for questionID: String) -> String? {
        byQuestionID[questionID]?.freeText
    }

    /// The answer after this question's free text becomes `text` — `nil` closes the field.
    func settingFreeText(_ text: String?, for questionID: String) -> SupervisorInquiryAnswer {
        var entry = byQuestionID[questionID] ?? QuestionAnswer()
        entry.freeText = text
        return replacing(entry, for: questionID)
    }

    /// The answer with every entry that names no question of `inquiry` dropped.
    ///
    /// One composer's fields are aimed at whichever recipient is selected, and the Supervisor
    /// retargets them freely — so an answer filled in for one role's questionnaire can still
    /// be in hand when a different role's is submitted. Its ids match nothing there, so it
    /// renders as nothing and reads as nothing; without this it would still be PERSISTED onto
    /// the second step, as answers to questions that step never asked.
    func scoped(to inquiry: SupervisorInquiry) -> SupervisorInquiryAnswer {
        let asked = Set(inquiry.questions.map(\.id))
        guard !byQuestionID.keys.allSatisfy(asked.contains) else { return self }
        return SupervisorInquiryAnswer(byQuestionID: byQuestionID.filter { asked.contains($0.key) })
    }

    /// What was actually DECIDED about this questionnaire: the entries that belong to it and
    /// say something. The one normalisation every delivered answer passes through, human and
    /// automated alike (`SupervisorInquiryReply.compose`, `.parse`).
    ///
    /// It replaced `defaultingUnanswered(in:)` on 2026-09-12, which filled every untouched
    /// CHOICE from `options[0]` and marked it assumed while leaving an untouched free text
    /// absent. Two shapes of the same silence, and the choice half told the asking role the
    /// Supervisor had decided the question they said nothing about. Nothing is filled in now;
    /// an unanswered question has no entry, of any kind, and the renderer reports the absence.
    ///
    /// Both of the old function's other jobs are kept, because both are why it existed at this
    /// seam rather than at its callers. `scoped(to:)` runs FIRST: the composer's fields are
    /// aimed at whichever recipient is selected and the Supervisor retargets them freely, so
    /// an answer filled in against another role's questions can be in hand at submit —
    /// invisible on screen either way, and persisted onto the wrong step without this. And an
    /// entry that holds nothing (a field opened and left blank, whitespace tabbed through) is
    /// dropped rather than shipped as a blank decision.
    func decided(in inquiry: SupervisorInquiry) -> SupervisorInquiryAnswer {
        SupervisorInquiryAnswer(
            byQuestionID: scoped(to: inquiry).byQuestionID.filter { !$0.value.isEmpty })
    }

    /// Writes one question's entry back, dropping it when it holds nothing at all.
    ///
    /// "Nothing at all" is narrower than `QuestionAnswer.isEmpty`: an open-but-blank free-text
    /// field is empty AND must be kept, because removing it would close the field the human
    /// just opened. `isEmpty` still reports the answer as empty, so a card touched only this
    /// far leaves no parked draft and no draft dot.
    private func replacing(
        _ entry: QuestionAnswer, for questionID: String
    ) -> SupervisorInquiryAnswer {
        var updated = byQuestionID
        if entry.selectedOptionIDs.isEmpty, entry.freeText == nil {
            updated.removeValue(forKey: questionID)
        } else {
            updated[questionID] = entry
        }
        return SupervisorInquiryAnswer(byQuestionID: updated)
    }
}
