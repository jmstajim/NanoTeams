import Foundation

// MARK: - Team Board Run Control

/// Pure selection of the Team Board navbar's run button for a given engine state.
///
/// Extracted from `TeamBoardTopBar.playPauseControl` so the pause / resume /
/// start state gating is unit-testable — restoring the branch coverage the
/// deleted `WatchtowerQuickActionFactoryTests` provided for the old
/// `QuickAction.makeActions` run-control factory.
///
/// `nonisolated` (the only input it touches is the `Sendable` `TeamEngineState`
/// enum), so it's exercisable from a plain `XCTestCase` — same as
/// `TeamEngineState.display`.
nonisolated enum TeamBoardRunControl: Equatable {
    case pause
    case resume
    case start

    /// Which run button to show — `nil` means show none.
    ///
    /// A historical (read-only) run shows no control. Otherwise:
    /// - `.running` / `.needsSupervisorInput` / `.needsAcceptance` → **pause**
    ///   (an active run, including one parked for input or waiting on acceptance,
    ///   can be paused).
    /// - `.paused` → **resume**.
    /// - `.pending` / `nil` → **start** (no engine yet).
    /// - `.done` / `.failed` → none (terminal; the run is over).
    static func select(engineState: TeamEngineState?, isHistoricalRun: Bool) -> TeamBoardRunControl? {
        guard !isHistoricalRun else { return nil }
        switch engineState {
        case .running, .needsSupervisorInput, .needsAcceptance:
            return .pause
        case .paused:
            return .resume
        case .pending, nil:
            return .start
        case .done, .failed:
            return nil
        }
    }
}
