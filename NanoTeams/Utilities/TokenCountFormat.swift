import Foundation

/// The one place a token count becomes a string.
///
/// Three surfaces render one: the prefix-cache miss report, the role editor's skills
/// tab, and the composer's context-fill indicator. Each grew its own `formatTokens`,
/// and they disagreed in the rounding (`%.1f` versus a `(x*10).rounded()/10` trick) —
/// which is invisible until two of them name the same number on the same screen.
///
/// The `~` belongs to `approximate` rather than to the callers, because every count the
/// app has EVER had is approximate in one of two ways: it is either
/// `ContextBudgetPolicy.estimateTokens` (0.45×–2.58× against real tokenizers) or the
/// server's own number for a prompt we then round to one decimal.
///
/// `nonisolated` because the app target defaults types to `@MainActor`; pure value-in /
/// value-out.
nonisolated enum TokenCountFormat {

    /// `12927` → `~12.9k`, `840` → `~840`, `1000` → `~1.0k`.
    static func approximate(_ tokens: Int) -> String {
        "~" + exact(tokens)
    }

    /// The same rounding without the tilde, for a place that has already said how it
    /// measured (the indicator's tooltip names its source in words).
    static func exact(_ tokens: Int) -> String {
        tokens >= 1000
            ? "\(String(format: "%.1f", Double(tokens) / 1000))k"
            : "\(tokens)"
    }
}
