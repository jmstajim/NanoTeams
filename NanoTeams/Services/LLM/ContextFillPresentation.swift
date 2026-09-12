import Foundation

/// Everything the context-fill indicator says, as pure functions.
///
/// Lives beside the policy rather than in the view for the same reason
/// `ActivityFeedBuilder` and `SystemNoticePresentation` do: a number that can be
/// misleading — the estimator's spread runs 0.45×–2.58× against real tokenizers — has to be
/// LABELLED accurately, and a label that only exists inside a `body` is a label no test can
/// read.
///
/// The indicator itself prints no number: it is a four-cell bar inside the role chip, and
/// every figure it stands for is in `tooltip` (on hover) and `accessibilityValue` (VoiceOver).
/// That is the whole surface — a short on-chip label existed until 2026-09-08 and was removed
/// with the percentage it printed.
///
/// **Total over `State`, and that is the whole point.** Until 2026-09-09 these functions took a
/// NON-optional `ContextFill`, so the state a user meets FIRST — a role with no measurement —
/// could not even be handed to them. The view invented its own rendering for it (`emptyBar`),
/// and that branch carried no button, no tooltip and no accessibility: a bar that looked like a
/// control and answered nothing on hover. The missing case was not a forgotten branch but a
/// state OUTSIDE the type, where no test could reach it.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; value-in / value-out.
nonisolated enum ContextFillPresentation {

    // MARK: - State

    /// Every state the indicator can be drawn in — the whole domain, not the part of it that
    /// carries a number.
    enum State: Equatable {

        /// No measurement for this step. Three histories arrive here and are indistinguishable
        /// from outside, so the text names none of them: the role has not answered in this run;
        /// the run or the step was reset since (`ContextFillProjection.removeTask` /
        /// `removeStep`); or the conversation was last written before `StepExecution.contextFill`
        /// existed (2026-09-08) and `seed(from:)` had nothing to restore. The third is the
        /// ordinary case on any installation with history. And it is NOT "an empty
        /// conversation" — which is why this state still offers the action (see `clickLine`).
        case unmeasured

        case measured(ContextFill)

        /// An epoch in flight. Carries the last measurement when there is one: the bar holds the
        /// same length while the wire is rewritten, because a bar that emptied mid-epoch would
        /// claim the conversation was already gone. Before this enum the view synthesised
        /// `ContextFill(promptTokens: 0)` here — a number nobody measured, invented only to
        /// satisfy a parameter.
        case compacting(ContextFill?)
    }

    /// The one place `(fill, isCompacting)` becomes a state — which is what leaves the view with
    /// no branch of its own.
    static func state(fill: ContextFill?, isCompacting: Bool) -> State {
        if isCompacting { return .compacting(fill) }
        if let fill { return .measured(fill) }
        return .unmeasured
    }

    /// The measurement a state carries, if it carries one.
    static func measurement(of state: State) -> ContextFill? {
        switch state {
        case .unmeasured: nil
        case .measured(let fill): fill
        case .compacting(let fill): fill
        }
    }

    // MARK: - Proportion

    /// How full, as a fraction of the BUDGET (not of the window).
    ///
    /// The budget is what the indicator is about: crossing it is what compacts, and a bar
    /// that filled toward the window would never reach its own trigger — it would read as
    /// "room to spare" at the exact moment the epoch fires. `nil` when there is no budget —
    /// the window was never probed — and the indicator then shows the raw count instead of
    /// a proportion it cannot compute.
    static func fraction(_ fill: ContextFill) -> Double? {
        guard let budget = positiveBudget(fill) else { return nil }
        return min(1.0, max(0, Double(fill.promptTokens) / Double(budget)))
    }

    /// How full the context is, as a whole percent of the BUDGET — the same measurement the bar
    /// draws, in words.
    ///
    /// NOT `fraction`, and the difference is the clamp: a bar cannot draw past its own end, so
    /// `fraction` stops at 1.0, but the text must not. A prompt at 488% of the budget under a
    /// full bar explains why the bar has stopped moving; a text that also said "100%" would
    /// make the control look stuck rather than overrun.
    static func promptShareOfBudget(_ fill: ContextFill) -> Int? {
        guard let budget = positiveBudget(fill) else { return nil }
        return Int((Double(fill.promptTokens) / Double(budget) * 100).rounded())
    }

    /// How full, as a whole percent of the model's WINDOW.
    ///
    /// The second base exists because the two answers differ and the bar can only draw one of
    /// them. The bar fills toward the budget — crossing that is what compacts — while "how much
    /// of the model's context is spoken for" is of the window, and a reader asking how full
    /// their context is may mean either. Both are printed, each named, rather than one number
    /// the reader silently assigns to whichever base they had in mind.
    static func promptShareOfWindow(_ fill: ContextFill) -> Int? {
        guard let window = positiveWindow(fill) else { return nil }
        return Int((Double(fill.promptTokens) / Double(window) * 100).rounded())
    }

    /// The shares as one line, or `nil` when neither base is known — in which case the tooltip
    /// says the window is unknown a line later, which is the same fact stated once.
    private static func filledLine(_ fill: ContextFill) -> String? {
        // The window share is dropped when the budget IS the window — at a 100% threshold the
        // two bases coincide, and the same number printed twice reads as a rendering fault
        // rather than as information. "Compacts at: … (100% of the window)" one line below is
        // what states the coincidence.
        let windowIsTheBudget = positiveBudget(fill) == positiveWindow(fill)
        let windowShare = windowIsTheBudget ? nil : promptShareOfWindow(fill)
        let shares = [
            promptShareOfBudget(fill).map { "\($0)% of the budget" },
            windowShare.map { "\($0)% of the model window" },
        ].compactMap { $0 }
        guard !shares.isEmpty else { return nil }
        return "Filled: " + shares.joined(separator: ", ")
    }

    /// What the bar DRAWS, in any state. Zero wherever there is no proportion: the track is
    /// drawn and nothing is lit — which is unambiguous, because `TerminalProgressBar.blocks`
    /// lights at least one eighth for any value above zero.
    static func barValue(_ state: State) -> Double {
        measurement(of: state).flatMap(fraction) ?? 0
    }

    /// Severity, for the colour. Three bands rather than a gradient: the question the user
    /// asks the indicator is "do I need to do something", which has three answers.
    enum Tier: Equatable {
        /// No budget to measure against — shows a count, never a verdict.
        case unknown
        case comfortable
        case approaching
        case atBudget
    }

    static func tier(_ fill: ContextFill) -> Tier {
        guard let fraction = fraction(fill) else { return .unknown }
        if fraction >= 0.9 { return .atBudget }
        if fraction >= 0.6 { return .approaching }
        return .comfortable
    }

    /// The hover tooltip. Names the source in words, because the difference between a
    /// server-reported count and an estimate is the difference between a number to act on and
    /// a number to glance at.
    static func tooltip(_ state: State) -> String {
        switch state {
        case .compacting:
            // One line in BOTH forms of the epoch, with a last measurement and without: the
            // counts on either side of a fold describe different conversations, and printing
            // the one being replaced would show it as the one being built.
            return "Compacting this role's conversation…"

        case .unmeasured:
            return [
                "Prompt: not measured yet",
                "The count comes from the server with each reply, and none has arrived for "
                    + "this role yet.",
                clickLine,
            ].joined(separator: "\n")

        case .measured(let fill):
            var parts: [String] = []
            let measured = fill.isEstimate ? "estimated" : "reported by the server"
            parts.append(
                "Prompt: \(TokenCountFormat.exact(fill.promptTokens)) tokens (\(measured))")
            // Directly under the count it is a share of, and above the thresholds: "how full is
            // it" is the question the control is hovered to answer, and the budget and window
            // below are what that share is measured against.
            if let filled = filledLine(fill) { parts.append(filled) }
            if let budget = positiveBudget(fill) {
                // The SHARE, not just the number. A user reading "compacts at 222.8k" under
                // "model window 262.1k" has no way to tell whether that threshold is a bug, a
                // model limit or a setting — and it is the third:
                // `AppDefaults.autoCompactBudgetPercent`, whose default is derived from what
                // still has to fit AFTER the budget is crossed (one iteration's append plus the
                // summary request, which carries the whole wire). Naming the share turns an
                // unexplained number into one the user can go and change.
                parts.append(
                    "Compacts at: \(TokenCountFormat.exact(budget)) tokens"
                        + (budgetShare(fill).map { " (\($0)% of the window, Settings → LLM)" }
                            ?? ""))
            }
            if let window = positiveWindow(fill) {
                parts.append("Model window: \(TokenCountFormat.exact(window)) tokens")
            } else {
                parts.append("Model window: unknown — the server did not report one")
            }
            if fill.compactions > 0 {
                parts.append(
                    "Compacted \(fill.compactions) time\(fill.compactions == 1 ? "" : "s") so far")
            }
            parts.append(clickLine)
            return parts.joined(separator: "\n")
        }
    }

    /// The closing line of every state the click reaches — that is, of all of them.
    ///
    /// What decides whether THIS conversation can be folded is
    /// `NTMSOrchestrator.compactRoleContext`, and it names the reason in a banner when it
    /// cannot; the tooltip has no business pre-empting that with a guess. A step with no
    /// measurement is not an empty step: a conversation written before the app began measuring
    /// is both long and unmeasured, and is exactly the one worth folding. "Nothing to compact"
    /// here would be the same refusal the empty bar was — a control asserting it has no work
    /// without looking.
    private static let clickLine = "Click to compact now."

    /// The budget, when it is one — and the SINGLE notion of that read by the bar, the tooltip
    /// and the share alike.
    ///
    /// There were three: `fraction` required `> 0`, the tooltip accepted any non-nil, and
    /// `budgetShare` had a third rule. A persisted `budget: 0` therefore drew an UNLIT bar
    /// ("there is no proportion") under a tooltip reading "Compacts at: 0 tokens (0% of the
    /// window, Settings → LLM)": the control contradicted itself in exactly the state where the
    /// bar cannot speak for itself.
    private static func positiveBudget(_ fill: ContextFill) -> Int? {
        guard let budget = fill.budget, budget > 0 else { return nil }
        return budget
    }

    /// The same for the window: `window: 0` printed "Model window: 0 tokens", which reads as a
    /// measurement rather than as the absence of one.
    private static func positiveWindow(_ fill: ContextFill) -> Int? {
        guard let window = fill.window, window > 0 else { return nil }
        return window
    }

    /// The budget as a whole-percent share of the window, when both are known. `nil` rather
    /// than a fabricated 100% when the window was never probed — the budget can exist without
    /// it only if a caller invents one, and this must not be the surface that hides that.
    static func budgetShare(_ fill: ContextFill) -> Int? {
        guard let budget = positiveBudget(fill), let window = positiveWindow(fill) else {
            return nil
        }
        return Int((Double(budget) / Double(window) * 100).rounded())
    }

    /// The VoiceOver value. The same two shares the tooltip prints, in one sentence — a spoken
    /// surface that knows less than the written one is the asymmetry this file exists to
    /// prevent.
    ///
    /// Total for the same reason the tooltip is: the state with no measurement used to be
    /// `.accessibilityHidden(true)` — a control VoiceOver could neither reach nor describe. A
    /// spoken "0 percent" would be worse than either: it is the one reading this indicator may
    /// never fake.
    static func accessibilityValue(_ state: State) -> String {
        switch state {
        case .compacting: return "Compacting"
        case .unmeasured: return "Not measured yet"
        case .measured(let fill):
            var parts: [String] = []
            if let budgetShare = promptShareOfBudget(fill) {
                parts.append("\(budgetShare) percent of the compaction budget")
            } else {
                parts.append("\(fill.promptTokens) prompt tokens, budget unknown")
            }
            if let windowShare = promptShareOfWindow(fill) {
                parts.append("\(windowShare) percent of the model window")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// What activating the control does. Does NOT vary by state, for the same reason
    /// `clickLine` does not: the action is live in every state, and its refusals are named by
    /// the orchestrator.
    static let accessibilityHint = "Compacts this role's conversation into a summary"
}
