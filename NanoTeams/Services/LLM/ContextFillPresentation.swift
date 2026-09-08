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
/// `nonisolated` because the app target defaults types to `@MainActor`; value-in / value-out.
nonisolated enum ContextFillPresentation {

    /// How full, as a fraction of the BUDGET (not of the window).
    ///
    /// The budget is what the indicator is about: crossing it is what compacts, and a bar
    /// that filled toward the window would never reach its own trigger — it would read as
    /// "room to spare" at the exact moment the epoch fires. `nil` when there is no budget —
    /// the window was never probed — and the indicator then shows the raw count instead of
    /// a proportion it cannot compute.
    static func fraction(_ fill: ContextFill) -> Double? {
        guard let budget = fill.budget, budget > 0 else { return nil }
        return min(1.0, max(0, Double(fill.promptTokens) / Double(budget)))
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
    static func tooltip(_ fill: ContextFill, isCompacting: Bool) -> String {
        if isCompacting { return "Compacting this role's conversation…" }
        var parts: [String] = []
        let measured = fill.isEstimate ? "estimated" : "reported by the server"
        parts.append("Prompt: \(TokenCountFormat.exact(fill.promptTokens)) tokens (\(measured))")
        if let budget = fill.budget {
            // The SHARE, not just the number. A user reading "compacts at 222.8k" under "model
            // window 262.1k" has no way to tell whether that threshold is a bug, a model limit
            // or a setting — and it is the third: `AppDefaults.autoCompactBudgetPercent`, whose
            // default is derived from what still has to fit AFTER the budget is crossed (one
            // iteration's append plus the summary request, which carries the whole wire).
            // Naming the share turns an unexplained number into one the user can go and change.
            parts.append(
                "Compacts at: \(TokenCountFormat.exact(budget)) tokens"
                    + (budgetShare(fill).map { " (\($0)% of the window, Settings → LLM)" } ?? ""))
        }
        if let window = fill.window {
            parts.append("Model window: \(TokenCountFormat.exact(window)) tokens")
        } else {
            parts.append("Model window: unknown — the server did not report one")
        }
        if fill.compactions > 0 {
            parts.append(
                "Compacted \(fill.compactions) time\(fill.compactions == 1 ? "" : "s") so far")
        }
        parts.append("Click to compact now.")
        return parts.joined(separator: "\n")
    }

    /// The budget as a whole-percent share of the window, when both are known. `nil` rather
    /// than a fabricated 100% when the window was never probed — the budget can exist without
    /// it only if a caller invents one, and this must not be the surface that hides that.
    static func budgetShare(_ fill: ContextFill) -> Int? {
        guard let budget = fill.budget, let window = fill.window, window > 0 else { return nil }
        return Int((Double(budget) / Double(window) * 100).rounded())
    }

    /// The VoiceOver value. Same facts as the tooltip's first line, in one sentence.
    static func accessibilityValue(_ fill: ContextFill, isCompacting: Bool) -> String {
        if isCompacting { return "Compacting" }
        if let fraction = fraction(fill) {
            return "\(Int((fraction * 100).rounded())) percent of the compaction budget"
        }
        return "\(fill.promptTokens) prompt tokens, budget unknown"
    }
}
