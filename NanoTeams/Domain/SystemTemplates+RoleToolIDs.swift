import Foundation

// MARK: - Fallback Tool IDs (single source of truth)

nonisolated extension SystemTemplates {

    private typealias TN = ToolNames

    /// Tool IDs for a role the team lookup could not resolve (`findRole` miss, or no team
    /// at all — `LLMExecutionService+ToolResolution` logs a WARNING on that path), keyed by
    /// the built-in role's system id.
    ///
    /// DERIVED from `SystemTemplates.roles[id].toolIDs` — the same table the bundled teams
    /// are built from — so the fallback can never disagree with the template about what a
    /// role holds. Until 2026-09-06 this was a third hand-written table (after the role
    /// templates and the `TeamTemplateFactory` closures), and it had drifted: its Software
    /// Engineer had no `edit_file`, its Code Reviewer no `git_diff` to "inspect the diff
    /// first" with, its UX Researcher the read tools the template denies.
    ///
    /// Plus BOTH supervisor-ask tools for every team role: on this path the resolver runs
    /// with no role definition, so its step-4 auto-injection (which hands the pair to every
    /// non-producing role) never fires — the fallback has to carry the escalation channel
    /// itself or a lookup-miss run of an advisory role is stranded with no way to reply
    /// (pinned by `ChatModeTests`). `ToolNames.supervisorAskTools` rather than the plain
    /// name alone: a lookup miss is not a reason to lose the questionnaire, and a role
    /// handed the form without `ask_supervisor` is the one shape the resolver has to heal.
    ///
    /// Two keys are not templates: the Supervisor (a human — no tools) and the Autovisor
    /// manager, whose real default toolset holds NO
    /// `ask_supervisor` (the manager IS the top Supervisor; without this key a lookup miss
    /// fell through to `fallbackCustomRoleToolIDs`, which grants it, with the resolver's
    /// autovisor gate skipped because the role definition was not found).
    static let fallbackToolIDs: [String: Set<String>] = {
        var map = roles.mapValues { Set($0.toolIDs).union(TN.supervisorAskTools) }
        map["supervisor"] = []
        map[AutovisorConstants.managerRoleSystemID] = Set(AutovisorConstants.managerDefaultToolIDs)
        return map
    }()

    /// Default fallback tool IDs for roles not in the map (custom roles): read-only file
    /// tools, memory, teammate collaboration and escalation.
    static let fallbackCustomRoleToolIDs: Set<String> = [
        TN.listFiles, TN.readFile, TN.readLines, TN.search,
        TN.updateScratchpad,
        TN.askTeammate, TN.requestTeamMeeting,
        TN.askSupervisor, TN.askSupervisorForm,
    ]
}
