import Foundation

/// Pure presentation logic for `BashSettingsView`: which sections are relevant in
/// each execution mode. Split out (mnemonic: `PlanningPhasePolicy` /
/// `TeamSwitchPlanner`) so the relevance-gating is unit-tested without rendering a
/// view.
///
/// The model behind the gating: **the judge is an advisor, the mode decides who
/// acts on it.** So the Judge & Sandbox card (strictness + the shared access-rules
/// table) and the custom rules matter whenever a command can run at all — both Auto
/// (verdict applied automatically) and Manual (the on-demand "Ask AI" advice). They
/// are dead weight only when bash is `Off`.
nonisolated enum BashSettingsVisibility {
    /// The Judge & Sandbox card + custom allow/ask/deny rules. Shown for `.manual`
    /// and `.auto`; hidden only for `.off` (no command can run, so nothing applies).
    static func showsPolicySections(mode: BashExecutionMode) -> Bool {
        mode != .off
    }
}
