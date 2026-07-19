import Foundation

/// Owns the in-memory state machine for the LM Studio embed model used by
/// Exploratory Search: which model+URL we currently consider loaded, plus the
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

    /// Callback for soft warnings — adoption-path prior-unload failures and
    /// `listLoadedInstances` failures that previously went silent. The
    /// orchestrator wires this to `lastInfoMessage` so a VRAM-leak signal
    /// reaches the user even when the operation as a whole "succeeds".
    var onWarning: ((String) -> Void)?

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
        // to the normal load path. Non-nil errors are surfaced via `onWarning`
        // so a transient 503 doesn't silently mask a duplicate-instance bug.
        let serverLoaded: [LoadedModelInstance]
        do {
            serverLoaded = try await client.listLoadedInstances(baseURLString: config.baseURLString)
        } catch {
            onWarning?(
                "Couldn't query loaded models on \(config.baseURLString): \(error.localizedDescription). " +
                "Adoption skipped — a duplicate embedding instance may be created."
            )
            serverLoaded = []
        }
        // Canonical-name matching via the shared normalizer — the listing's
        // `modelName` is already canonical (":N" stripped), and `sameModel`
        // folds case/whitespace exactly like the chat side does.
        let matches = serverLoaded.filter {
            ChatModelEnsurer.sameModel($0.modelName, config.modelName)
        }
        if !matches.isEmpty {
            // Prefer re-adopting the instance we already hold when it lives on
            // the server we just listed: a client-side-only config change
            // (batchSize/requestTimeout) must not unload a live instance and
            // then point local state at its dead id.
            let sameServerPriorID: String? = loaded.flatMap { prior in
                prior.config.baseURLString.normalizedBaseURL
                    == config.baseURLString.normalizedBaseURL
                    ? prior.instanceID : nil
            }
            let adopted = matches.first { $0.instanceID == sameServerPriorID } ?? matches[0]
            let priorIsAdopted = sameServerPriorID != nil
                && adopted.instanceID == sameServerPriorID

            // If we previously held a DIFFERENT instance (model/URL change),
            // unload it first — the server already has the one we want.
            if let prior = loaded, !priorIsAdopted {
                do {
                    try await client.unloadModel(
                        instanceID: prior.instanceID,
                        baseURLString: prior.config.baseURLString
                    )
                } catch {
                    // Adoption is more valuable than a perfect prior-unload —
                    // the prior may live on the same server we're about to
                    // adopt from, and the next reconcile will clean up. Still
                    // surface so the user knows VRAM may not have been
                    // reclaimed on the prior endpoint.
                    onWarning?(
                        "Couldn't unload previous embedding model '\(prior.config.modelName)' on \(prior.config.baseURLString): " +
                        "\(error.localizedDescription). It may still consume VRAM until the server is restarted."
                    )
                }
            }
            loaded = LoadedState(config: config, instanceID: adopted.instanceID)

            // Reap sibling duplicates (the `:2`/`:3` pile-up a past
            // listing-failure session left behind). Soft-warn on failure —
            // the goal state ("model available") already holds, and failing
            // Exploratory Search over VRAM hygiene would be backwards. Reuse
            // the listing we already have (`matches`).
            await reapSiblings(
                matches,
                ofModel: config.modelName,
                base: config.baseURLString,
                excluding: adopted.instanceID,
                client: client
            )
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
            // Reap any sibling duplicates of the PRIOR model too. A past
            // listing-failure session could have left prior-model :2/:3, and
            // once `loaded` points at the new model nothing ever lists the
            // prior again — so the swap is the last chance to clean them.
            // Soft-warn on failure: the swap already succeeded (goal state
            // holds), a lingering sibling is a VRAM note, not a load failure.
            await reapSiblingInstances(
                ofModel: prior.config.modelName,
                base: prior.config.baseURLString,
                excluding: prior.instanceID,
                client: client
            )
        }

        let newID = try await client.loadModel(
            modelName: config.modelName,
            baseURLString: config.baseURLString
        )
        loaded = LoadedState(config: config, instanceID: newID)
    }

    /// Lists `base` and reaps every same-model sibling except `keepID`. Used on
    /// the swap branch, where the prior model may live on a different base than
    /// the one `ensureLoaded` already listed. Listing failure soft-warns and
    /// no-ops (the primary unload already succeeded).
    private func reapSiblingInstances(
        ofModel model: String,
        base: String,
        excluding keepID: String,
        client: any LLMClient
    ) async {
        guard let listed = try? await client.listLoadedInstances(baseURLString: base) else {
            onWarning?(
                "Couldn't enumerate embedding instances on \(base) to reap duplicates of '\(model)'. " +
                "Duplicates may linger until the server is restarted."
            )
            return
        }
        await reapSiblings(listed, ofModel: model, base: base, excluding: keepID, client: client)
    }

    /// Unloads every same-model instance in `instances` except `keepID`, soft-
    /// warning on each failure. Shared by the adoption path (which passes the
    /// listing it already fetched) and the swap path (via `reapSiblingInstances`).
    private func reapSiblings(
        _ instances: [LoadedModelInstance],
        ofModel model: String,
        base: String,
        excluding keepID: String,
        client: any LLMClient
    ) async {
        for sibling in instances
        where ChatModelEnsurer.sameModel(sibling.modelName, model)
            && sibling.instanceID != keepID {
            do {
                try await client.unloadModel(
                    instanceID: sibling.instanceID, baseURLString: base)
            } catch {
                onWarning?(
                    "Couldn't unload duplicate embedding instance '\(sibling.instanceID)' on \(base): " +
                    "\(error.localizedDescription). It may still consume VRAM until the server is restarted."
                )
            }
        }
    }

    /// Idempotent. Unloads whatever is currently loaded; no-op if nothing is.
    ///
    /// Reaps EVERY resident instance of the model, not just the remembered
    /// one: a past listing-failure session can leave `:2`/`:3` duplicates the
    /// one-slot `loaded` state can't represent (observed live 2026-07-19 —
    /// three resident nomic instances). The target set is the UNION of the
    /// remembered id and every listed instance matching the model — union,
    /// not replace, so a server-restarted remembered id is still attempted
    /// ("instance not found" / 404 are treated as success by
    /// `NativeLMStudioClient`, so a stale id costs nothing). Listing failure
    /// soft-warns and falls back to the remembered id alone — a real listing
    /// error must not turn the unload into a failure.
    ///
    /// Unload errors: every instance is attempted, then the FIRST error
    /// propagates (existing contract: orchestrator surfaces it via
    /// `lastInfoMessage`). State is cleared in all branches via `defer`: the
    /// in-memory belief is untrustworthy after any unload outcome.
    func ensureUnloaded() async throws {
        guard let current = loaded else { return }
        defer { loaded = nil }

        var instanceIDs: [String] = [current.instanceID]
        do {
            let serverLoaded = try await client.listLoadedInstances(
                baseURLString: current.config.baseURLString
            )
            for instance in serverLoaded
            where ChatModelEnsurer.sameModel(instance.modelName, current.config.modelName)
                && !instanceIDs.contains(instance.instanceID) {
                instanceIDs.append(instance.instanceID)
            }
        } catch {
            onWarning?(
                "Couldn't query loaded models on \(current.config.baseURLString): \(error.localizedDescription). " +
                "Unloading only the remembered instance — duplicates may linger."
            )
        }

        var firstError: Error?
        for instanceID in instanceIDs {
            do {
                try await client.unloadModel(
                    instanceID: instanceID,
                    baseURLString: current.config.baseURLString
                )
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
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
