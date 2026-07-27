import Foundation

/// Capability lint for Autovisor goal text.
///
/// The manager's toolset is `AutovisorConstants.managerDefaultToolIDs` — read
/// files, read git, inspect images, and delegate. No shell, no writes, no
/// build. A goal that tells it to do any of those instructs an impossible call,
/// and the failure is silent-then-terminal: the runtime answers
/// `tool_not_authorized`, the manager has NO `ask_supervisor` (gated off for
/// the manager team), so a small model retries the invented tool until the pass
/// wedges. That is the observed incident this exists to prevent — a
/// hand-written goal said "run the project's build command **yourself**", the
/// model reached for a non-existent `run_shell_command`, and the task reached
/// Review with no build ever run.
///
/// **Derived, never hand-listed.** The set is `ToolHandlerRegistry.allTypes`
/// minus what the manager actually has, so a tool added to the registry
/// tomorrow is covered the same day. The previous incarnation was a six-name
/// literal inside a test; it missed 19 of the 25 real gaps.
///
/// Two rule families, deliberately separate because they have opposite
/// precision profiles:
/// - `unavailableTool` / `inventedShellSpelling` — identifier matching.
///   Deterministic and language-independent.
/// - `selfDirectedBuildClaim` — phrase matching. The ONLY rule that would have
///   caught the real incident (which names no tool at all), and therefore the
///   only one that can produce a false positive. It is English-only, gated on a
///   conjunction, and never applied to the checked-in presets.
nonisolated enum AutovisorGoalLint {

    enum Kind: Equatable {
        /// A registry tool the manager does not have.
        case unavailableTool
        /// An identifier-shaped name for a shell the manager has never had.
        case inventedShellSpelling
        /// Prose telling the manager to build/compile/run something itself.
        case selfDirectedBuildClaim
    }

    struct Finding: Equatable {
        let token: String
        /// 1-indexed line within the goal text.
        let line: Int
        let kind: Kind
    }

    // MARK: - Needles

    /// `request_changes` is ALSO the `action` value of `manage_role`, a
    /// MANDATORY manager tool — every preset legitimately writes
    /// "`manage_role` request_changes". Without this exemption the derived
    /// denylist fails all five presets on day one.
    ///
    /// Kept honest by `AutovisorGoalLintTests.testManageRoleStillDocumentsTheRequestChangesVerb`:
    /// if the verb is ever removed, the exemption fails loudly rather than
    /// silently blinding the lint to a real tool name.
    static let verbExemptions: Set<String> = [ToolNames.requestChanges]

    /// Every registry tool the manager lacks.
    static let unavailableToolNames: Set<String> =
        Set(ToolHandlerRegistry.allTypes.map { $0.name })
            .subtracting(AutovisorConstants.managerDefaultToolIDs)
            .subtracting(verbExemptions)

    /// Identifier-shaped spellings a model invents for a shell it does not
    /// have. Deliberately NOT bare `shell` / `terminal` / `sh` — those are
    /// ordinary English words and would fire on prose about shell scripts the
    /// WORKERS should write.
    static let inventedShellSpellings: Set<String> = [
        "run_shell_command", "run_command", "execute_command", "shell_command",
        "run_terminal_command", "run_terminal_cmd", "run_bash", "bash_command",
        "runShellCommand", "executeCommand",
    ]

    /// Build/run verbs for the phrase rule.
    private static let buildVerbs: Set<String> = [
        "build", "builds", "building", "rebuild", "rebuilds", "compile", "compiles",
        "compiling", "xcodebuild", "npm", "yarn", "make", "gradle", "cargo", "pytest",
    ]

    /// Second-person directives that turn a build verb into an instruction to
    /// the manager itself.
    private static let selfDirectives: [String] = [
        "yourself", "you run", "you must run", "you should run", "you need to run",
        "on your own", "personally",
    ]

    /// Cues that a line is addressed to a WORKER rather than to the manager.
    /// A goal that legitimately tells a delegated team to use `write_file` is
    /// correct — workers have different toolsets.
    private static let delegationCues: [String] = [
        "create_managed_task", "brief", "worker", "workers", "delegate", "delegates",
        "delegated", "delegation", "task", "tasks", "team", "teams", "contract",
    ]

    // MARK: - Scanning

    /// For the CHECKED-IN presets: recall over precision. No suppression, no
    /// phrase rule — those are authored here and held to the higher bar.
    static func scanStrict(_ goal: String) -> [Finding] {
        identifierFindings(in: goal, suppressingDelegationLines: false)
    }

    /// For USER-authored goals: precision over recall.
    ///
    /// The always-visible tip this feeds must have near-zero false positives —
    /// one that fires on legitimate text gets trained away, and then the real
    /// one is invisible too. That bar rose when the warning stopped being a
    /// dismissible banner: an icon that cries wolf cannot even be dismissed.
    /// Hence delegation-line suppression, and a phrase rule that needs both
    /// halves of a conjunction in one sentence.
    static func scanUserAuthored(_ goal: String) -> [Finding] {
        identifierFindings(in: goal, suppressingDelegationLines: true)
            + selfDirectedBuildFindings(in: goal)
    }

    // MARK: - Implementation

    /// Tokenizes into maximal identifier runs and set-intersects.
    ///
    /// Not a regex and not `contains`: `git_branch_list` tokenizes to ONE token
    /// and so can never match the denied `git_branch`, which substring matching
    /// gets wrong and regex only gets right with careful escaping.
    private static func identifierFindings(
        in goal: String,
        suppressingDelegationLines: Bool
    ) -> [Finding] {
        var findings: [Finding] = []
        for (index, line) in goal.components(separatedBy: "\n").enumerated() {
            if suppressingDelegationLines, mentionsDelegation(line) { continue }
            for token in identifierTokens(in: line) {
                if unavailableToolNames.contains(token) {
                    findings.append(Finding(token: token, line: index + 1, kind: .unavailableTool))
                } else if inventedShellSpellings.contains(token) {
                    findings.append(
                        Finding(token: token, line: index + 1, kind: .inventedShellSpelling))
                }
            }
        }
        return findings
    }

    /// Fires only when ONE sentence carries both a build verb and a
    /// self-directive. "Audit the build settings" has no directive and stays
    /// silent; "never fix anything yourself" (in every preset) has no build
    /// verb and stays silent; "run the project's build command yourself" has
    /// both.
    private static func selfDirectedBuildFindings(in goal: String) -> [Finding] {
        var findings: [Finding] = []
        for (index, line) in goal.components(separatedBy: "\n").enumerated() {
            for sentence in line.components(separatedBy: CharacterSet(charactersIn: ".!?;")) {
                let lowered = sentence.lowercased()
                guard selfDirectives.contains(where: lowered.contains) else { continue }
                guard let verb = identifierTokens(in: lowered).first(where: buildVerbs.contains)
                else { continue }
                findings.append(
                    Finding(token: verb, line: index + 1, kind: .selfDirectedBuildClaim))
            }
        }
        return findings
    }

    private static func identifierTokens(in line: String) -> [String] {
        line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            .map(String.init)
    }

    private static func mentionsDelegation(_ line: String) -> Bool {
        let tokens = Set(identifierTokens(in: line.lowercased()))
        return delegationCues.contains { tokens.contains($0) }
    }
}
