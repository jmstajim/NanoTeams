import Foundation

// MARK: - Role Concurrency Mode

/// How many of a task's roles the engine may run at the same time.
///
/// The engine dispatches every ready role at once (CLAUDE.md #45), which is the right
/// default against a server that can actually serve them. Against ONE local server it
/// often is not: roles carry different system prompts, so interleaving them evicts each
/// other's prompt-prefix (KV) cache, and a miss costs a full re-prefill — measured at
/// ~350 ms warm against 4300–6100 ms cold on a 13k-token wire
/// (`docs/architecture/prefix-cache.md`).
///
/// There are exactly two honest answers, and the second one is honest precisely because
/// it names no number: **nothing in either provider reports how many requests it will
/// serve in parallel.** `listLoadedInstances` answers RESIDENCY (LM Studio's
/// `GET /api/v0/models` `state == "loaded"`, Ollama's `GET /api/ps`), `num_parallel` /
/// `OLLAMA_NUM_PARALLEL` are never read, and `ServerProvenanceProbe` knows only version,
/// build and engines. So "as many as the provider allows" can only mean "NanoTeams
/// imposes no limit of its own" — which is what `maxConcurrentRoles == nil` says.
///
/// `nonisolated` per the house rule for pure value types: a `Codable` enum persisted into
/// UserDefaults with no UI dependency has no business inheriting the app target's
/// `@MainActor` default isolation.
nonisolated enum RoleConcurrencyMode: String, CaseIterable, Identifiable, Codable, Hashable {
    /// One role of a task runs at a time; the rest wait their turn in team order.
    case single
    /// No app-imposed limit — every role whose inputs are ready starts at once.
    case providerLimited

    var id: String { rawValue }

    /// The cap the engine enforces, or `nil` for "the app does not limit this".
    ///
    /// `Int?` rather than a sentinel number: the point of enforcement does no arithmetic
    /// on an invented value, and a future numeric choice ("at most 3") drops in here
    /// without touching anything below it.
    var maxConcurrentRoles: Int? {
        switch self {
        case .single: return 1
        case .providerLimited: return nil
        }
    }

    /// An exhaustive `switch`, not a metadata dictionary. The dictionary idiom
    /// (`Role.metadata`) exists for an enum with an open case — `Role.custom(id:)` — where a
    /// total mapping is impossible and a fallback is honest. This enum is closed, so a
    /// fallback would be a line no input can reach, and the compiler would stop naming the
    /// place to edit when a third mode is added.
    var displayName: String {
        switch self {
        case .single: return "One at a time"
        case .providerLimited: return "As many as the provider allows"
        }
    }

    /// The one-line explanation shown under the picker.
    var explanation: String {
        switch self {
        case .single:
            return "Only one role of a task runs at a time; the rest wait their turn in team order."
        case .providerLimited:
            return "Every role whose inputs are ready starts at once; the server decides what it runs in parallel and what it queues."
        }
    }
}
