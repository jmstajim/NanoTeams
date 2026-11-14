import Foundation

/// The last time a folder's Autovisor was switched on or off, and what switched it
/// (`ProjectSettings.autovisorLastSwitch`).
///
/// An agent whose calls start being refused with "the Autovisor is off" can tell the person WHY
/// from `folder_status.readiness` — the person's own click, the auto-off timer, or the Autovisor
/// deleted. Until 2026-11-09 nothing recorded it: on the evening of 2026-11-08 the Autovisor
/// went off mid-run, and neither the agent nor the logs could say whether a timer or a click
/// had done it.
nonisolated struct AutovisorSwitch: Codable, Hashable, Sendable {
    enum Cause: String, Codable, Hashable, Sendable, CaseIterable {
        /// The person switched it — the setup pane, the sidebar, the Watchtower pill.
        case person
        /// The auto-off timer ended (`evaluateAutovisorAutoDisable`).
        case autoOff = "auto_off"
        /// The person deleted the Autovisor (`deleteAutovisor`), which turns it off.
        case deleted
    }

    var at: Date
    var by: Cause
}
