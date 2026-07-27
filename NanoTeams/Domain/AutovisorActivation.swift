import Foundation

/// Configures WHEN the Autovisor wakes up to run a review pass.
///
/// The periodic *schedule* itself does NOT live here — it lives on the manager
/// task's `recurrence` (so the existing automation scheduler picks it up via
/// `recurringTaskIDsDue`). This struct carries the **event-driven** triggers,
/// persisted inside `ProjectSettings` (`settings.json`). There is no throttle:
/// an event wakes the manager immediately when it's idle, or is injected into its
/// live conversation when it's already running (mid-review delivery).
///
/// `onTaskNeedsSupervisor` is special: besides waking the manager, it gates the
/// auto-answer suppression. When it is `false`, the universal-supervisor behavior
/// is OFF and tasks fall back to the normal auto-answer / human-wait path (so they
/// never hang waiting for a manager that won't be woken).
nonisolated struct AutovisorActivation: Codable, Hashable {
    /// Wake when any top-level folder task enters `.needsSupervisorInput` so the
    /// manager can answer it as the folder's Supervisor. Also the master gate for
    /// auto-answer suppression (see type doc).
    var onTaskNeedsSupervisor: Bool
    /// Wake when a folder task fails (triage / restart).
    var onTaskFailed: Bool
    /// Wake when a folder task completes (review results / close / decide next).
    var onTaskCompleted: Bool
    /// Wake when a new (e.g. human-created) top-level task appears. Consumed by
    /// `wakeAutovisorForEvents` against the orchestrator's seen-task set.
    var onTaskCreated: Bool
    /// Wake when a top-level task's role looks stuck — caught in a tool/output
    /// loop or hung (token silence) on a `.running` role. Evaluated only by the
    /// per-minute poll backstop (`computeStuckTaskIDs`), never on the hot
    /// engine-state observer path.
    var onTaskStuck: Bool

    /// Sleep timer master switch (ON by default): when on, the Autovisor turns
    /// itself off `autoDisableAfterSeconds` after being enabled. Persisted as an
    /// explicit Bool (not an optional duration) so a user's "off" choice survives
    /// re-encode — `encodeIfPresent` would drop a nil and decode would resurrect
    /// the on-by-default.
    var autoDisableEnabled: Bool

    /// Sleep-timer duration: seconds after enabling at which the Autovisor turns
    /// itself off (when `autoDisableEnabled`). Only this DURATION persists — the
    /// armed deadline is in-memory on the orchestrator (`autovisorAutoDisableAt`)
    /// and re-arms fresh on every app launch / folder open with the feature on.
    /// Floored at `minAutoDisableSeconds`.
    var autoDisableAfterSeconds: TimeInterval

    init(
        onTaskNeedsSupervisor: Bool = true,
        onTaskFailed: Bool = true,
        onTaskCompleted: Bool = true,
        onTaskCreated: Bool = false,
        onTaskStuck: Bool = true,
        autoDisableEnabled: Bool = true,
        autoDisableAfterSeconds: TimeInterval = AutovisorConstants.defaultAutoDisableAfterSeconds
    ) {
        self.onTaskNeedsSupervisor = onTaskNeedsSupervisor
        self.onTaskFailed = onTaskFailed
        self.onTaskCompleted = onTaskCompleted
        self.onTaskCreated = onTaskCreated
        self.onTaskStuck = onTaskStuck
        self.autoDisableEnabled = autoDisableEnabled
        self.autoDisableAfterSeconds = Self.clampAutoDisable(autoDisableAfterSeconds)
    }

    /// The sleep-timer duration when the timer is on, nil when off — the single
    /// shape the orchestrator's re-arm guard and the persist-path change
    /// detection both key on.
    var effectiveAutoDisableAfterSeconds: TimeInterval? {
        autoDisableEnabled ? autoDisableAfterSeconds : nil
    }

    // Forward-compatible decode: missing sub-fields fall back to defaults so adding
    // a trigger in a future version doesn't reject existing settings.json. Delegates
    // to `init(...)` so the clamps execute in exactly one place (the
    // `AutovisorTuning` funnel pattern).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            onTaskNeedsSupervisor: try c.decodeIfPresent(Bool.self, forKey: .onTaskNeedsSupervisor) ?? true,
            onTaskFailed: try c.decodeIfPresent(Bool.self, forKey: .onTaskFailed) ?? true,
            onTaskCompleted: try c.decodeIfPresent(Bool.self, forKey: .onTaskCompleted) ?? true,
            onTaskCreated: try c.decodeIfPresent(Bool.self, forKey: .onTaskCreated) ?? false,
            onTaskStuck: try c.decodeIfPresent(Bool.self, forKey: .onTaskStuck) ?? true,
            autoDisableEnabled: try c.decodeIfPresent(Bool.self, forKey: .autoDisableEnabled) ?? true,
            autoDisableAfterSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .autoDisableAfterSeconds)
                ?? AutovisorConstants.defaultAutoDisableAfterSeconds
        )
    }

    /// Bounds the sleep-timer duration: floored at the scheduler's once-a-minute
    /// resolution (a sub-minute value could never be honored on time) and capped
    /// at the Settings steppers' ceiling (a hand-edited huge Double would trap the
    /// editor's `Int(_:)` seconds→h/m conversion).
    static func clampAutoDisable(_ seconds: TimeInterval) -> TimeInterval {
        min(max(AutovisorConstants.minAutoDisableSeconds, seconds),
            AutovisorConstants.maxAutoDisableSeconds)
    }

    /// Returns a copy with `autoDisableAfterSeconds` re-floored. Mirrors
    /// `AutovisorTuning.clamped()`: the Settings editor's bindings mutate the fields
    /// directly (bypassing the `init` clamp), so the persist path
    /// (`updateAutovisorActivation`) re-applies the floor through this. Delegates to
    /// `init(...)` so the floor executes in exactly one place.
    func clamped() -> AutovisorActivation {
        AutovisorActivation(
            onTaskNeedsSupervisor: onTaskNeedsSupervisor,
            onTaskFailed: onTaskFailed,
            onTaskCompleted: onTaskCompleted,
            onTaskCreated: onTaskCreated,
            onTaskStuck: onTaskStuck,
            autoDisableEnabled: autoDisableEnabled,
            autoDisableAfterSeconds: autoDisableAfterSeconds
        )
    }

    static let `default` = AutovisorActivation()
}

/// Pure decision rules for the Autovisor's universal-supervisor behavior.
nonisolated enum AutovisorPolicy {
    /// Whether the Autovisor manager acts as this task's Supervisor — the
    /// auto-answer suppression gate in `handleSupervisorAutoAnswer`. When true,
    /// the task's `ask_supervisor` questions are NOT auto-answered; the step
    /// parks at `.needsSupervisorInput`, the engine pauses, and the manager is
    /// woken to answer.
    ///
    /// The manager is the task's Supervisor iff the feature + needs-supervisor
    /// trigger are on, the task is top-level (delegation children route
    /// `ask_supervisor` back to their delegating role), and the task isn't the
    /// manager itself — the manager carries no `ask_supervisor` at all
    /// (`resolveToolSchemas` excludes it for the autovisor template), and
    /// excluding it here keeps the generic auto-answer fallback live for its
    /// task instead of creating a self-supervision deadlock.
    static func supervisesTask(
        taskID: Int,
        parentTaskID: Int?,
        autovisorEnabled: Bool,
        activation: AutovisorActivation,
        autovisorTaskID: Int?
    ) -> Bool {
        autovisorEnabled
            && activation.onTaskNeedsSupervisor
            && parentTaskID == nil
            && autovisorTaskID != taskID
    }

    /// Whether the Autovisor can be ENABLED in the current work folder.
    ///
    /// The manager only does anything when there is a real, user-chosen work
    /// folder — `ensureAutovisorTeam` / `ensureAutovisorTask` both no-op in
    /// default (internal) storage, which has nothing to manage. So persisting
    /// `autovisorEnabled = true` without one would leave the toggle reading "ON"
    /// with no manager task or engine behind it: a dead, misleading control.
    /// The single source of truth shared by the `setAutovisorEnabled` guard and
    /// the Watchtower pill's visibility — keep them in lockstep.
    static func canEnable(hasRealWorkFolder: Bool) -> Bool {
        hasRealWorkFolder
    }

    /// Whether the persisted Autovisor goal is still "unset" — empty/whitespace, or
    /// the seeded `AutovisorConstants.defaultGoal` placeholder the user hasn't
    /// replaced. A manager with an unset goal would run on the "explore & wait"
    /// placeholder, so every surface treats it as "not configured yet".
    ///
    /// We deliberately do NOT track legacy default strings: a real goal that happens
    /// to equal the *current* default re-prompts setup, which is acceptable (the
    /// customization is invisible to us either way). The match is EXACT (after
    /// trimming) — a real goal that merely contains the default as a substring is
    /// not "unset".
    static func goalIsUnset(_ goal: String) -> Bool {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == AutovisorConstants.defaultGoal
    }

    // MARK: - Setup routing
    //
    // Two rules, because "setup" answers two different questions and one predicate
    // cannot serve both:
    //
    // • DESTINATION — which pane does `.autovisor` render? (`showsSetupPane`)
    // • INTERCEPT — may an OFF→ON click enable in place, or must it route through
    //   setup first? (`requiresSetupBeforeEnabling`)
    //
    // They used to be one predicate keyed on the goal, which made a disabled manager
    // with a real goal render a CHAT it could never drive — a dead surface with no
    // visible way back. Widening that single predicate to "disabled ⇒ setup" would
    // have fixed the pane and broken the pill: it could never turn the Autovisor on
    // again, only navigate.
    //
    // The earlier divergence hazard (an intercept routing to "setup" while the pane
    // showed the chat) is now structurally impossible rather than merely coordinated:
    // every disabled state shows setup, and the intercept only ever fires while
    // disabled — so `requiresSetupBeforeEnabling ⟹ showsSetupPane(enabled: false)`
    // holds by construction. Pinned by `AutovisorPolicyTests`.

    /// Whether the `.autovisor` destination renders the SETUP pane (goal + Enable)
    /// rather than the manager chat — the routing rule for
    /// `MainLayoutView.autovisorDetail` and the sidebar menu label that names it.
    ///
    /// Setup unless the manager exists AND is enabled. A disabled manager keeps its
    /// task (`setAutovisorEnabled(false)` leaves `autovisorTaskID` set — only Delete
    /// clears it), so without this it would keep rendering a chat for a manager that
    /// won't run. The goal is deliberately NOT an input: while disabled, the way back
    /// is always the same one screen, whatever the goal says.
    static func showsSetupPane(taskExists: Bool, enabled: Bool) -> Bool {
        !taskExists || !enabled
    }

    /// Whether an OFF→ON click (the Watchtower pill) must route to the setup pane
    /// instead of enabling in place.
    ///
    /// A real goal enables directly — one click, no detour. The seeded
    /// `AutovisorConstants.defaultGoal` placeholder must be replaced first, or the
    /// manager would start on the inert "explore & wait" directive; likewise a
    /// manager that was never created has nothing to turn on yet.
    static func requiresSetupBeforeEnabling(taskExists: Bool, goalIsUnset: Bool) -> Bool {
        !taskExists || goalIsUnset
    }
}
