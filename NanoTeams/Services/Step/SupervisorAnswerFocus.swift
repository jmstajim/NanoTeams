import Foundation

/// Which waiting question an answering surface is aimed at — and where it goes next.
///
/// Two surfaces answer Supervisor questions and both have to make the same three decisions:
/// which of the waiting questions is on screen, which one to move to after one is answered, and
/// whether the count is worth saying out loud. The composer made the first decision inside a
/// view body (`resolveEffectiveRecipient`'s "first question wins"), made the second by not
/// making it (clearing the selection and letting the first-wins rule fire again), and never
/// made the third at all; Quick Capture made the first by taking `pending(in:).first` and had
/// no way to reach the rest.
///
/// So this is not a helper the two surfaces happen to share. It is the difference between one
/// answer to "which question am I looking at" and two — and with parallel roles (CLAUDE.md #45)
/// the two are routinely different questions of the same task, which is exactly the state the
/// user reaches for a switcher in.
///
/// Step ids rather than a richer type on purpose: both surfaces key their questions on
/// `StepExecution.id` (`TaskStepKey.stepID`), and a rule written over ids cannot be tempted to
/// read anything else about a question it is only ordering.
nonisolated enum SupervisorAnswerFocus {

    /// The question a surface should show, given what it would PREFER to show.
    ///
    /// The preference is honoured only while it is still waiting. A question answered from
    /// another surface — or from this one — leaves the list, and a surface that kept pointing
    /// at it would render a question nobody is being asked; falling back to the leading
    /// question is the same rule `resolveEffectiveRecipient` has always applied when no chip
    /// was explicitly picked.
    ///
    /// Returns nil only for an empty list: with nothing waiting there is nothing to aim at,
    /// and every caller reads that as "leave answer mode", never as "aim at question zero".
    static func resolve(preferred: String?, among stepIDs: [String]) -> String? {
        if let preferred, stepIDs.contains(preferred) { return preferred }
        return stepIDs.first
    }

    /// Where to aim after `answeredStepID` is answered.
    ///
    /// The next question to its RIGHT in the row, wrapping to the leftmost when it was the
    /// last — never simply "the first one". The difference shows up the moment a third
    /// question exists: a Supervisor working left to right who is bounced back to the
    /// question they already skipped will skip it again, and the row never empties.
    ///
    /// `stepIDs` is the list as it stood WHEN the answer was submitted, which still contains
    /// the answered question — the mutation that removes it has not landed yet. That is the
    /// point: its position is what "next" is measured from. A list that has already dropped it
    /// (a second surface got there first) still works, and yields the leading question.
    ///
    /// Returns nil when nothing else is waiting, which every caller reads as "aim at nothing"
    /// — the composer's auto-resolution, and the panel's dismissal.
    static func next(after answeredStepID: String, among stepIDs: [String]) -> String? {
        let remaining = stepIDs.filter { $0 != answeredStepID }
        guard !remaining.isEmpty else { return nil }
        guard let position = stepIDs.firstIndex(of: answeredStepID) else { return remaining.first }
        let toTheRight = stepIDs[stepIDs.index(after: position)...].first { $0 != answeredStepID }
        return toTheRight ?? remaining.first
    }

    /// The row's count badge, or nil when there is nothing to count.
    ///
    /// Silent at one. A badge that can only ever say "1 waiting" beside a row holding exactly
    /// one chip is decoration that costs a glance, and the state it describes — a single
    /// question, the ordinary one — is the state the surfaces already made unmistakable. It
    /// starts speaking at two, which is precisely when the row stops being self-evident.
    ///
    /// Silent at zero as well, and not by omission: a surface with no waiting question still
    /// renders a chip row (roles the composer can message), and "0 waiting" there would be an
    /// answer to a question nobody asked.
    static func waitingBadge(count: Int) -> String? {
        waitingBadgeCount(count).map { "\($0) waiting" }
    }

    /// The same threshold, as a NUMBER, for the surface that has no room for a word.
    ///
    /// The sidebar row is 260pt wide and already spends its width on a title, a status glyph
    /// and a stamp; "2 waiting" does not fit there, and the row's own waiting glyph makes the
    /// word redundant anyway. What it cannot say without this is HOW MANY — which is the whole
    /// reason a Supervisor would open one task rather than another.
    ///
    /// Optional in AND optional out, because that surface reads the count from an index row
    /// and a row written before the field knows nothing. "Don't know" renders exactly as
    /// "one or none" does — today's dot with no number — which is the honest rendering: an
    /// unknown row must never be made to assert a number, and `0` is an assertion.
    static func waitingBadgeCount(_ count: Int?) -> Int? {
        guard let count, count >= 2 else { return nil }
        return count
    }
}
