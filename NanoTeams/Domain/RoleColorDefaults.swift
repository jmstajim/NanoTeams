import Foundation

/// Default background hex colors for system roles.
/// Lives in Domain so that `SystemTemplates` and `TeamRoleDefinition` (both Domain types)
/// can resolve role colors without depending on the Views layer.
enum RoleColorDefaults {

    /// Default blue used for custom (non-system) roles.
    static let defaultHex = "#5F87D9"

    /// Maps system role IDs to their default background palette hex values.
    static let backgroundHex: [String: String] = [
        "supervisor": "#6D76E2",
        "productManager": "#3FB6AA",
        "uxResearcher": "#A86DE8",
        "uxDesigner": "#D887B2",
        "techLead": "#5F87D9",
        "softwareEngineer": "#4FB985",
        "codeReviewer": "#6D76E2",
        "sre": "#46B8D0",
        "tpm": "#D4974E",
        "loreMaster": "#9A795F",
        "npcCreator": "#CF6EAA",
        "encounterArchitect": "#D96A7F",
        "rulesArbiter": "#D5B455",
        "questMaster": "#8F82E6",
        "theAgreeable":     "#3FB6AA",
        "theOpen":          "#D887B2",
        "theConscientious": "#5F87D9",
        "theExtrovert":     "#D4974E",
        "theNeurotic":      "#A86DE8",
        "assistant":        "#56C999",
        "codingAssistant":  "#8F82E6",
    ]

    /// Returns the default background hex for a system role ID, or blue for custom roles.
    static func defaultBackgroundHex(for systemRoleID: String?) -> String {
        guard let id = systemRoleID else { return defaultHex }
        return backgroundHex[id] ?? defaultHex
    }
}
