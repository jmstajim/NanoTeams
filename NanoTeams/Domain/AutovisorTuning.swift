import Foundation

/// Numeric behaviour tunables for the Autovisor — per-folder knobs a developer of
/// the automated Supervisor reasonably wants to crank for their machine/model.
/// Persisted inside `ProjectSettings` (`settings.json`), sibling of
/// `AutovisorActivation` (which carries the WHEN — triggers + debounce; the
/// review *schedule* lives on the manager task's `recurrence`).
///
/// The corresponding `AutovisorConstants.*` values are the DEFAULTS (and remain
/// the fallback wherever a snapshot isn't available). Every field is clamped on
/// construct/decode so a hand-edited `settings.json` can't drive a cap to a value
/// that breaks an invariant (e.g. a `0` concurrency cap the manager could never
/// create against, or a sub-second hang threshold that false-flags constantly).
///
/// Fields are `var` so the settings editor's SwiftUI `$tuning.field` bindings can
/// write them directly — which bypasses the init clamps. Therefore every write into
/// the *persisted* slot MUST re-clamp via `clamped()` (the only writer today is
/// `updateAutovisorTuning`). The runtime reads only the persisted value, never the
/// editor's transient draft, so a clamped persistence boundary is sufficient.
nonisolated struct AutovisorTuning: Codable, Hashable {

    // MARK: Throughput

    /// Hard cap on concurrently-`.running` manager-created tasks (resource ceiling —
    /// each is its own LLM-call stream). `create_managed_task` refuses past it.
    var maxConcurrentManagedTasks: Int
    /// Burst cap on NEW tasks one review pass may spawn (reset each manager run).
    /// Stops a single pass flooding the board with immediately-idle creations.
    var maxManagedTasksPerReview: Int

    // MARK: Stuck detection

    /// Seconds of complete stream silence on a `.running` role before the stuck
    /// detector returns `.hang` (an in-flight tool suppresses the verdict). Raise
    /// for slow local models that legitimately think for minutes.
    var stuckHangSeconds: TimeInterval
    /// A repeating tool-call / output signal only counts as a live loop when its
    /// latest occurrence is within this window — guards against `resetStepForRevision`
    /// audit history re-flagging a just-restarted role.
    var stuckLoopRecencySeconds: TimeInterval

    /// Stuck timings can't go below this — a sub-minute threshold false-flags
    /// constantly (a slow model's normal silence would read as a hang).
    private static let minStuckSeconds: TimeInterval = 30

    init(
        maxConcurrentManagedTasks: Int = AutovisorConstants.maxConcurrentManagedTasks,
        maxManagedTasksPerReview: Int = AutovisorConstants.maxManagedTasksPerReview,
        stuckHangSeconds: TimeInterval = AutovisorConstants.stuckHangSeconds,
        stuckLoopRecencySeconds: TimeInterval = AutovisorConstants.stuckLoopRecencySeconds
    ) {
        // Caps floored at 1 — a 0 cap means the manager could never create a task.
        self.maxConcurrentManagedTasks = max(1, maxConcurrentManagedTasks)
        self.maxManagedTasksPerReview = max(1, maxManagedTasksPerReview)
        self.stuckHangSeconds = max(Self.minStuckSeconds, stuckHangSeconds)
        self.stuckLoopRecencySeconds = max(Self.minStuckSeconds, stuckLoopRecencySeconds)
    }

    // Forward-compatible decode: every field falls back to its default + clamp so a
    // new knob in a future build doesn't reject an existing settings.json, and a
    // settings.json missing the whole block decodes to `.default`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxConcurrentManagedTasks: try c.decodeIfPresent(Int.self, forKey: .maxConcurrentManagedTasks)
                ?? AutovisorConstants.maxConcurrentManagedTasks,
            maxManagedTasksPerReview: try c.decodeIfPresent(Int.self, forKey: .maxManagedTasksPerReview)
                ?? AutovisorConstants.maxManagedTasksPerReview,
            stuckHangSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .stuckHangSeconds)
                ?? AutovisorConstants.stuckHangSeconds,
            stuckLoopRecencySeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .stuckLoopRecencySeconds)
                ?? AutovisorConstants.stuckLoopRecencySeconds
        )
    }

    /// Re-applies the construction floors. Direct field mutation (e.g. the settings
    /// editor's `$tuning.field` SwiftUI bindings) bypasses `init`'s clamps, so the
    /// persistence boundary (`updateAutovisorTuning`) routes through this to keep a
    /// never-out-of-range value reaching `settings.json` and the runtime.
    func clamped() -> AutovisorTuning {
        AutovisorTuning(
            maxConcurrentManagedTasks: maxConcurrentManagedTasks,
            maxManagedTasksPerReview: maxManagedTasksPerReview,
            stuckHangSeconds: stuckHangSeconds,
            stuckLoopRecencySeconds: stuckLoopRecencySeconds
        )
    }

    static let `default` = AutovisorTuning()
}
