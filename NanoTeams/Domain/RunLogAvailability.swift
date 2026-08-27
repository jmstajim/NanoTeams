import Foundation

/// Whether a run's two audit logs are on disk — the displayed side
/// (`conversation_log.md`) and the wire side (`network_log.jsonl`, or the pre-2026-08-21
/// `network_log.json` array).
///
/// A value type rather than two `Bool`s at the call site because the two answers share
/// an ancestor walk: resolving where a (possibly nested) task's run directory lives costs
/// a whole-index hop map, and asking twice pays it twice. `NTMSOrchestrator`'s
/// `runLogAvailability(taskID:runID:)` is the one producer.
///
/// Default is "neither" so a view can hold it as `@State` before the first probe without
/// an optional: a menu item that is briefly disabled is the safe direction — the action
/// behind it re-checks the URL and no-ops on a missing file either way.
nonisolated struct RunLogAvailability: Equatable {
    var conversation: Bool = false
    var network: Bool = false
}
