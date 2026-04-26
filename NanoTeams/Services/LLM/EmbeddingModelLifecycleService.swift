import Foundation

/// Owns the in-memory state machine for the LM Studio embed model used by
/// Expanded Search: which model+URL we currently consider loaded, plus the
/// `instance_id` LM Studio handed back so we can target it for unload later.
///
/// Reconciles to a desired state via two idempotent hooks:
/// - `ensureLoaded(_:)` — load if not already, or unload-then-load if the
///   config (model name OR base URL) changed since the last successful load.
/// - `ensureUnloaded()` — unload if anything is currently loaded.
///
/// Both fields live as a single optional struct (`LoadedState`) so the
/// "config and instanceID are always set together or both nil" invariant is
/// type-enforced — illegal partial states (`(config, nil)` / `(nil, id)`)
/// are unrepresentable.
///
/// Errors:
/// - `ensureLoaded` propagates load errors so the orchestrator can surface
///   them via `lastErrorMessage`.
/// - `ensureLoaded` swap-failure (prior-unload throws) propagates as
///   `EmbeddingLifecycleError.priorUnloadFailedDuringSwap` WITHOUT clearing
///   local state — the server may still hold the prior instance, and
///   forgetting its id would orphan it.
/// - `ensureUnloaded` propagates real unload errors. Caller decides whether
///   to surface them (today: orchestrator catches and writes
///   `lastInfoMessage`).
@MainActor
final class EmbeddingModelLifecycleService {

    /// Bundled state — both fields exist together or neither does. Replaces
    /// the prior pair of `private(set) var Optional` fields, which permitted
    /// `(loadedConfig, nil)` and `(nil, loadedInstanceID)` half-states.
    struct LoadedState: Equatable {
        let config: EmbeddingConfig
        let instanceID: String
    }

    private let client: any LLMClient

    /// What we currently believe LM Studio has loaded for our use. `nil`
    /// means "we have nothing loaded".
    private(set) var loaded: LoadedState?

    init(client: any LLMClient = LLMClientRouter()) {
        self.client = client
    }

    /// Idempotent. If `config` matches what's already loaded, no-op.
    ///
    /// Adoption path (the C1 fix for "every restart creates a `:N` duplicate"):
    /// when our in-memory belief says "nothing loaded" we ask the server
    /// whether the desired model is *already* loaded (LM Studio survives
    /// our process). If it is, adopt that `instance_id` instead of calling
    /// `loadModel`, which would otherwise spawn a second instance.
    ///
    /// Swap path: a different config is loaded — unload it first. If the
    /// unload throws, we throw `priorUnloadFailedDuringSwap` WITHOUT clearing
    /// local state; the server may still hold the prior instance and we
    /// must remember its id for a future retry.
    ///
    /// Throws on load failure with `loaded` reflecting reality (cleared if
    /// the prior was successfully unloaded but the new load failed).
    func ensureLoaded(_ config: EmbeddingConfig) async throws {
        if loaded?.config == config {
            return
        }

        // C1: server-side adoption. Best-effort — if listing fails (older
        // LM Studio without /api/v0/models, network blip, etc.), fall through
        // to the normal load path.
        let serverLoaded = (try? await client.listLoadedInstances(baseURLString: config.baseURLString)) ?? []
        if let existing = serverLoaded.first(where: { $0.modelName == config.modelName }) {
            // If we previously thought we owned a different config, unload
            // it first — the user changed model/URL, server already has the
            // new one we want.
            if let prior = loaded, prior.config != config {
                do {
                    try await client.unloadModel(
                        instanceID: prior.instanceID,
                        baseURLString: prior.config.baseURLString
                    )
                } catch {
                    // Adoption is more valuable than a perfect prior-unload —
                    // the prior may live on the same server we're about to
                    // adopt from, and the next reconcile will clean up.
                }
            }
            loaded = LoadedState(config: config, instanceID: existing.instanceID)
            return
        }

        // No existing instance to adopt — handle prior unload + fresh load.
        if let prior = loaded {
            do {
                try await client.unloadModel(
                    instanceID: prior.instanceID,
                    baseURLString: prior.config.baseURLString
                )
                // Only clear after a successful unload — clearing on failure
                // would orphan the instance (no id to retry the unload with).
                loaded = nil
            } catch {
                throw EmbeddingLifecycleError.priorUnloadFailedDuringSwap(
                    prior: prior.config,
                    underlying: error
                )
            }
        }

        let newID = try await client.loadModel(
            modelName: config.modelName,
            baseURLString: config.baseURLString
        )
        loaded = LoadedState(config: config, instanceID: newID)
    }

    /// Idempotent. Unloads whatever is currently loaded; no-op if nothing is.
    /// "Instance not found" / 404 are treated as success by `NativeLMStudioClient`
    /// — the desired state (nothing loaded) holds either way. Anything reaching
    /// this method's catch block is therefore a real error worth surfacing.
    /// State is cleared in both branches via `defer`: the in-memory belief is
    /// untrustworthy after any unload outcome.
    func ensureUnloaded() async throws {
        guard let current = loaded else { return }
        defer { loaded = nil }
        try await client.unloadModel(
            instanceID: current.instanceID,
            baseURLString: current.config.baseURLString
        )
    }
}

/// Errors specific to embed-model lifecycle reconciliation. Distinguished
/// from generic `LLMClientError` so the orchestrator can format a more
/// useful message for the user.
enum EmbeddingLifecycleError: Error, LocalizedError {
    /// Swap-time prior-unload failure. We refuse to clear local state for
    /// the prior config — caller can retry, and the next `ensureLoaded`
    /// will see the still-stale `loaded` and try to unload again.
    case priorUnloadFailedDuringSwap(prior: EmbeddingConfig, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .priorUnloadFailedDuringSwap(let prior, let underlying):
            return "Couldn't unload previous embedding model '\(prior.modelName)': \(underlying.localizedDescription). Local state preserved so a retry can complete the swap."
        }
    }
}
