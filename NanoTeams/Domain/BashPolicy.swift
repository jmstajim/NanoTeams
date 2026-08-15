import Foundation

/// How the `bash` tool resolves a command that isn't matched by an explicit
/// allow/deny rule and isn't a read-only no-op.
nonisolated enum BashExecutionMode: String, Codable, CaseIterable, Hashable {
    /// The `bash` tool is disabled — every command is denied regardless of rules.
    case off
    /// Pause for human approval on EVERY command that isn't blocked by a deny rule
    /// — read-only no-ops, allow-rule matches, and prior "always" approvals all
    /// require fresh confirmation each time. The strictest interactive posture.
    /// In a no-human context (autonomous / Autovisor / headless) the call is denied.
    case manual = "alwaysConfirm"
    /// "Ask" commands pause for a human decision, but read-only no-ops and
    /// allow-/"always"-approved commands run without asking — the historical
    /// "Manual" behavior. Inherits the legacy `"manual"` raw value so existing
    /// configs decode to it unchanged (no migration). In a no-human context the
    /// "ask" call is denied — use `.auto` to let the judge decide unattended.
    case semiAutomatic = "manual"
    /// "Ask" commands are resolved by the one-shot LLM judge
    /// (`BashJudgeService`) — no human in the loop.
    case auto

    private static let metadata: [BashExecutionMode: (displayName: String, description: String)] = [
        .off: ("Off", "The bash tool is disabled. Roles cannot run shell commands."),
        .manual: ("Manual", "You approve every command before it runs — read-only commands and ones you allowed before included. Only deny rules block silently."),
        .semiAutomatic: ("Semi-automatic", "You approve each command that isn't read-only or already allowed. When one is waiting, “Ask AI” gives you the judge's verdict — but you still decide."),
        .auto: ("Auto", "An LLM judge approves or denies each command for you, at the strictness set below."),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? rawValue }
    var settingDescription: String { Self.metadata[self]?.description ?? "" }

    /// Whether a command can reach `.allow` in this mode WITHOUT a human being asked.
    ///
    /// The discriminator is the reachability of `BashPermissionService.evaluate`'s read-only
    /// bypass (its step 4), not the declaration order of these cases. `.manual` returns `.ask`
    /// at step 1b — ABOVE the bypass, deliberately, because the user opted into confirming each
    /// command — so no command whatsoever runs unattended there; `.off` denies at step 0.
    /// `.semiAutomatic` and `.auto` both fall through to the bypass, so ordinary reads
    /// (`ls`, `cat`, `grep`, `head`, `wc`, `jq`, `tree`, `diff`) resolve with neither a human
    /// nor the judge.
    ///
    /// Consumed by `PlanningPhasePolicy`'s admission test: a planning phase is a fast
    /// fact-gathering stretch, and under `.manual` it would degenerate into a per-command
    /// approval queue (or, with no human present, into a wall of denials).
    ///
    /// Exhaustive `switch`, no `default`: a mode added later must be classified by whoever adds
    /// it. Inferring the answer from case order would hand a new case whatever its neighbour
    /// happened to have.
    var allowsUnattendedCommands: Bool {
        switch self {
        case .off, .manual: false
        case .semiAutomatic, .auto: true
        }
    }
}

/// How strict the Auto judge should be when ruling on an "ask" command.
/// Threaded verbatim into the judge's system prompt.
///
/// `.off` disables the judge entirely — in Auto mode every command that passes
/// the deny rules runs without review (`BashPermissionService.evaluate` step 1c
/// short-circuits to allow before anything can ask). Scoped to Auto: Manual and
/// Semi-automatic always route their asks to the human, regardless of the
/// stored level. Mirrors `ComputerUseRestrictionLevel.off`.
nonisolated enum BashRestrictionLevel: String, Codable, CaseIterable, Hashable {
    // Declaration order = allCases order = the Settings picker order:
    // Off first, then ascending strictness (loosest → strictest). Matches
    // `ComputerUseRestrictionLevel`'s Off-first ordering.
    case off
    case permissive
    case standard
    case strict

    private static let metadata: [BashRestrictionLevel: (displayName: String, description: String, guidance: String)] = [
        .strict: (
            "Strict",
            "Approves only clearly safe read-only, build, test, or lint commands scoped to the project; "
                + "denies anything destructive, privileged, networked, or uncertain.",
            "Approve ONLY clearly safe, read-only or build/test/lint commands scoped to the project. "
                + "Deny anything that deletes files, modifies system state, installs software, makes network "
                + "requests, runs with elevated privileges, or whose effect you are not certain about."
        ),
        .standard: (
            "Standard",
            "Approves what a careful engineer runs in a project sandbox — build, test, lint, format, "
                + "project-scoped installs, routine git; denies destructive, privileged (sudo), or unclear actions.",
            "Approve commands that a careful engineer would run in a project sandbox: building, testing, "
                + "linting, formatting, reading and editing files within the project, package installs scoped "
                + "to the project, and routine git operations. Deny destructive operations outside the project, "
                + "privilege escalation (sudo), disabling security, or commands whose effect is unclear."
        ),
        .permissive: (
            "Permissive",
            "Approves most development commands, including network installs and broad file ops within the "
                + "project; denies only clearly destructive or malicious actions.",
            "Approve most development commands, including network installs and broad file operations within "
                + "the project. Deny only clearly destructive or malicious actions: wiping the disk, exfiltrating "
                + "secrets, disabling security protections, fork bombs, or privilege escalation."
        ),
        .off: (
            "Off",
            "No review — in Auto mode, every command that isn't blocked by a deny rule runs without "
                + "the judge. Manual and Semi-automatic still ask you.",
            // Never reaches the Auto judge (`BashPermissionService.evaluate` short-circuits
            // to allow before the gate consults it) and the on-demand "Ask AI" advice
            // short-circuits in `BashAdviceService`. Non-empty only to satisfy the
            // metadata-completeness contract (mirrors `ComputerUseRestrictionLevel.off`).
            "Approve every command."
        ),
    ]

    var displayName: String { Self.metadata[self]?.displayName ?? rawValue }
    /// Short per-level description shown under the Settings → Bash → Judge picker.
    var settingDescription: String { Self.metadata[self]?.description ?? "" }
    /// Injected verbatim into the judge system prompt.
    var judgeGuidance: String { Self.metadata[self]?.guidance ?? "" }
}

/// Result of evaluating a command against the static rule layer
/// (`BashPermissionService`). `deny` > `ask` > `allow` precedence is applied
/// inside the service before returning.
nonisolated enum BashPermissionDecision: Hashable {
    case allow
    case deny(reason: String)
    case ask(reason: String)
}

/// App-level configuration for the `bash` command-execution feature. Assembled
/// from `StoreConfiguration` and surfaced to `LLMExecutionService` through
/// `LLMStateDelegate.commandPolicy`.
///
/// IMPORTANT: never carries any credential — this type is `Codable` and could be
/// logged or round-tripped in tests. The LM Studio bearer token lives only in
/// the Keychain (see `SecureTokenStorage`); the judge resolves it at request
/// time. No new leak vector here.
nonisolated struct BashPolicy: Codable, Hashable, Sendable {
    var mode: BashExecutionMode
    var restrictionLevel: BashRestrictionLevel
    /// Patterns that force `.allow` (highest-priority short-circuit AFTER deny).
    var allowRules: [String]
    /// Patterns that force `.ask` (human/judge review even if otherwise allowable).
    var askRules: [String]
    /// Patterns that force `.deny` (highest priority — wins over allow/ask).
    var denyRules: [String]
    /// Wrap every command in a macOS Seatbelt profile that confines writes to the
    /// work folder + TMPDIR. On by default.
    var sandboxEnabled: Bool
    /// Per-folder read/write grants honored by `SeatbeltSandbox.profile` when
    /// `sandboxEnabled`. The default value reproduces the prior hardcoded profile.
    var sandboxPermissions: BashSandboxPermissions
    /// If the Seatbelt wrapper itself fails to launch (`sandbox-exec` missing /
    /// profile rejected), fall back to running UNSANDBOXED. Off by default — a
    /// sandbox failure denies the command rather than silently dropping the
    /// confinement.
    var allowUnsandboxedFallback: Bool
    /// Optional dedicated LLM override (URL + model + generation params) for the
    /// Auto judge. `nil` = use the role's / global config. The bearer token is
    /// resolved from the Keychain by URL at request time — `LLMOverride` is
    /// Codable and carries no credential, matching this type's no-credential
    /// invariant.
    var judgeOverride: LLMOverride?

    init(
        mode: BashExecutionMode = BashConstants.defaultMode,
        restrictionLevel: BashRestrictionLevel = BashConstants.defaultRestrictionLevel,
        allowRules: [String] = [],
        askRules: [String] = [],
        denyRules: [String] = [],
        sandboxEnabled: Bool = true,
        sandboxPermissions: BashSandboxPermissions = BashSandboxPermissions(),
        allowUnsandboxedFallback: Bool = false,
        judgeOverride: LLMOverride? = nil
    ) {
        self.mode = mode
        self.restrictionLevel = restrictionLevel
        self.allowRules = allowRules
        self.askRules = askRules
        self.denyRules = denyRules
        self.sandboxEnabled = sandboxEnabled
        self.sandboxPermissions = sandboxPermissions
        self.allowUnsandboxedFallback = allowUnsandboxedFallback
        self.judgeOverride = judgeOverride
    }

    /// Tolerant decoder so a legacy `BashPolicy` JSON (written before
    /// `sandboxPermissions` / `judgeOverride` existed) round-trips with safe
    /// defaults instead of throwing on the new required field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(BashExecutionMode.self, forKey: .mode) ?? BashConstants.defaultMode
        self.restrictionLevel = try c.decodeIfPresent(BashRestrictionLevel.self, forKey: .restrictionLevel)
            ?? BashConstants.defaultRestrictionLevel
        self.allowRules = try c.decodeIfPresent([String].self, forKey: .allowRules) ?? []
        self.askRules = try c.decodeIfPresent([String].self, forKey: .askRules) ?? []
        self.denyRules = try c.decodeIfPresent([String].self, forKey: .denyRules) ?? []
        self.sandboxEnabled = try c.decodeIfPresent(Bool.self, forKey: .sandboxEnabled) ?? true
        self.sandboxPermissions = try c.decodeIfPresent(BashSandboxPermissions.self, forKey: .sandboxPermissions)
            ?? BashSandboxPermissions()
        self.allowUnsandboxedFallback = try c.decodeIfPresent(Bool.self, forKey: .allowUnsandboxedFallback) ?? false
        self.judgeOverride = try c.decodeIfPresent(LLMOverride.self, forKey: .judgeOverride)
    }

    /// The policy a step is REALLY running under while it is in its planning phase: the same
    /// rules and the same mode, with the sandbox narrowed exactly as `BashTool` narrows it per
    /// call and the unsandboxed fallback forced off.
    ///
    /// Two consumers, and both would otherwise describe a confinement that is not in force:
    /// `BashJudgeService.sandboxConfinementDescription` renders `sandboxPermissions` verbatim
    /// into the judge's system prompt (its own doc requires the REAL sandbox, "not a fixed
    /// assumption"), and the "Ask AI" advisor behind a human approval card runs that same
    /// description. Without this a judge would be told "writes are confined to the project work
    /// folder" about a command that cannot write anywhere at all — wrong in the permissive
    /// direction for writes and in the strict direction for harmless reads.
    ///
    /// `mode`, `restrictionLevel` and all three rule lists are untouched, which is what makes
    /// the claim "the `.ask`/`.deny`/`.allow` tiering is unchanged during planning" PROVABLE:
    /// `BashPermissionService.evaluate` never reads a sandbox field.
    ///
    /// `sandboxEnabled` is deliberately NOT forced true. Admission already requires it, so
    /// forcing it here would mask a wiring bug instead of surfacing it.
    func withWritesDisabled() -> BashPolicy {
        var narrowed = self
        narrowed.sandboxPermissions = sandboxPermissions.withWritesDisabled()
        narrowed.allowUnsandboxedFallback = false
        return narrowed
    }
}
