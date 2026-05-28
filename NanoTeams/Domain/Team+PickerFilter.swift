import Foundation

extension Array where Element == Team {
    /// Teams suitable for surfacing in any user-facing team picker. Filters out
    /// the generated-team placeholder — reached via a dedicated "Generate Team..."
    /// entry; selecting it directly would commit the user to a roleless template
    /// that would silently stall on run.
    var selectableInPicker: [Team] {
        filter { $0.templateID != DelegationConstants.generatedTeamSentinel }
    }
}
