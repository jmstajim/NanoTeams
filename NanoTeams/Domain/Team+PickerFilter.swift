import Foundation

extension Array where Element == Team {
    /// Teams suitable for surfacing in any user-facing team picker. Filters out
    /// infrastructure teams (the generated-team placeholder and the Autovisor
    /// team) — each reached via its own dedicated entry point; selecting them
    /// directly would commit the user to a non-user template (`Team.isHiddenFromPickers`
    /// is the single source of truth).
    var selectableInPicker: [Team] {
        filter { !$0.isHiddenFromPickers }
    }
}
