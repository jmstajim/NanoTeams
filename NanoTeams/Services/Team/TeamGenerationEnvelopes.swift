import Foundation

/// Shared JSON envelope formatters for the `create_team` tool-call placeholder
/// pattern. Used by:
///
/// - `NTMSOrchestrator+TeamGeneration.runTeamGeneration` (Generated Team
///   template task-startup flow), where the placeholder lives on a synthetic
///   Supervisor step.
/// - `LLMExecutionService+DelegateToTeam.handleDelegateToTeam` (when
///   `team_id == "generated"`), where the placeholder is appended to the
///   delegating role's step so the activity feed shows a `create_team` row
///   with `NTMSLoader(.inline)` while `TeamGenerationService.generate(...)`
///   is in flight.
///
/// The `"status":"generating"` substring is a single source of truth that
/// `StepToolCall.isGeneratingTeam` matches against — pinned by
/// `TeamGenerationOrchestratorTests.testGeneratingEnvelope_matchesIsGeneratingTeamMarker`.
enum TeamGenerationEnvelopes {

    static func makeGenerationArgsJSON(taskDescription: String) -> String {
        let payload: [String: Any] = ["task": taskDescription]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    static func makeGeneratingEnvelope() -> String {
        #"{"ok":true,"status":"generating"}"#
    }

    static func makeSuccessEnvelope(team: Team, warnings: [String] = []) -> String {
        let roleCount = max(0, team.roles.count - 1) // exclude Supervisor
        var data: [String: Any] = [
            "team": team.name,
            "roles": "\(roleCount)",
            "status": "created",
        ]
        if !warnings.isEmpty {
            data["warnings"] = warnings
        }
        let payload: [String: Any] = ["ok": true, "data": data]
        if let blob = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: blob, encoding: .utf8) {
            return str
        }
        return #"{"ok":true}"#
    }

    static func makeErrorEnvelope(message: String) -> String {
        let payload: [String: Any] = [
            "ok": false,
            "error": ["code": "GENERATION_FAILED", "message": message],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return #"{"ok":false}"#
    }
}
