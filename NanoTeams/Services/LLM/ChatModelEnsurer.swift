import Foundation

/// A chat model instance this app is managing: what it is, where it lives, and
/// the `instance_id` LM Studio requires in order to unload it.
///
/// Shaped after `EmbeddingModelLifecycleService.LoadedState` — the prior art in
/// this codebase for "we loaded it, so we own its lifecycle" — so the two
/// halves of model residency read the same way.
nonisolated struct OwnedChatModel: Hashable, Sendable, Codable {
    let modelName: String
    let baseURLString: String
    let instanceID: String
}

/// What an ensure actually did, so the caller can record ownership. The
/// distinction matters: only `.loaded` and `.adopted` carry an `instance_id`,
/// and `.skipped` (fail-open on a listing failure) must NOT be recorded — we
/// would have no id to unload with.
nonisolated enum EnsureOutcome: Hashable, Sendable {
    case loaded(instanceID: String)
    case adopted(instanceID: String)
    case skipped
}

/// Ensures the chat model named by an `LLMConfig` is loaded in LM Studio
/// BEFORE a chat request is issued, instead of letting the server JIT-load it.
///
/// Why it matters (verified live 2026-07-19 against LM Studio with
/// `qwen/qwen3.6-35b-a3b`): a JIT-loaded model is subject to **Auto-Evict**,
/// which keeps at most ONE JIT instance in memory — so a Vision call would
/// evict the chat model (and vice versa), and JIT instances also carry a
/// 60-minute idle TTL. Explicitly loaded models are exempt from both, which is
/// what lets the chat, Vision and embedding models stay resident together.
/// Loading through `POST /api/v1/models/load` applies the user's per-model
/// config ("My Models" → gear) exactly like the LM Studio UI does.
///
/// Semantics:
/// - **Adopt-or-load**: if the model is already loaded (user loaded it in the
///   LM Studio UI, or a previous ensure did), nothing happens — the same model
///   is never loaded twice, so no duplicate `name:2` instance appears.
/// - **`ensureLoaded` never unloads.** The load path is additive — it adopts
///   or loads, never removes. All unloading lives in `reclaim` /
///   `reclaimUnownedDuplicate` on this same actor, invoked by
///   `NTMSOrchestrator.reconcileChatModelResidency` (from settings hooks, run
///   boundaries, and de-reference paths). Keeping the load path additive is
///   what lets parallel roles with different per-role-override models coexist
///   without swap-thrash; residency reconciliation is the single unload
///   authority.
/// - **Coalescing**: concurrent ensures for the same (base, model) await one
///   in-flight load instead of racing duplicates. The load runs detached so
///   one caller's cancellation (Pause) can't kill a load other roles are
///   waiting on; the model is then warm for Resume.
/// - **Fail-open on listing**: if the loaded-instances listing fails (server
///   down, non-LM-Studio test double), ensure skips — the chat call itself
///   surfaces the canonical connection error.
/// - **Request census**: `beginRequest`/`endRequest` bracket every chat request
///   so residency reconciliation can refuse to unload a model that is
///   mid-stream. This
///   is the ONLY in-use signal that sees the taskless one-shot callers
///   (work-folder context generation, prompt improvement, Team Editor team
///   generation) — they have no task, step or engine for the orchestrator to
///   observe.
actor ChatModelEnsurer {

    static let shared = ChatModelEnsurer()

    private var inFlight: [String: Task<EnsureOutcome, Error>] = [:]

    /// Open chat requests per (base, model). A count, not a flag: parallel
    /// roles (CLAUDE.md #45) legitimately stream against the same model, and a
    /// flag would let the first one to finish clear the others' protection.
    private var openRequests: [String: Int] = [:]

    /// The ownership ledger: every chat instance this app is managing, keyed
    /// the same way as the coalescing map. See `OwnedChatModel`.
    ///
    /// INVARIANT: one owned instance per (model, base) — deliberately. Two
    /// instances of one model (`name` + `name:2`) is never a desired state,
    /// so the ledger represents the one we keep and the residency reconciler
    /// reaps the excess (`reconcileChatModelResidency`'s duplicate pass).
    /// Keying by instanceID instead would desynchronize the ledger from the
    /// coalescing map and the request census, which share this key.
    private var owned: [String: OwnedChatModel] = [:]

    /// Reclaims in flight, so an ensure cannot adopt an instance that is being
    /// unloaded right now. See `reclaim`.
    private var unloading: [String: Task<Void, Error>] = [:]

    init() {}

    // MARK: - Ensure

    @discardableResult
    func ensureLoaded(
        modelName: String,
        baseURLString: String,
        client: any LLMClient
    ) async throws -> EnsureOutcome {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return .skipped }

        let key = Self.key(model: model, base: baseURLString)
        // A reclaim of this exact model is mid-flight: the instance is still
        // listed but is about to die. Adopting it would return "already
        // loaded" and issue the request against a corpse. Wait it out, then
        // list again and load properly.
        if let pendingUnload = unloading[key] {
            _ = try? await pendingUnload.value
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task.detached {
            try await Self.performEnsure(
                model: model,
                baseURLString: baseURLString,
                client: client
            )
        }
        inFlight[key] = task
        // The entry is cleared by the LOAD's own completion, never by the
        // awaiting caller: a caller cancelled mid-load (Pause) must not drop
        // the registration while the detached load is still running, or the
        // next ensure would start a SECOND concurrent load of the same model
        // — exactly the duplicate-instance case the coalescing prevents.
        Task { [weak self] in
            _ = try? await task.value
            await self?.clearInFlight(key)
        }

        // Ownership is recorded on the CALLER's path, not on that hop: we are
        // back on the actor here, so the ledger is updated before `ensureLoaded`
        // returns. Recording it from the detached hop instead left a window in
        // which a just-loaded model was in neither the ledger nor the census,
        // so a second switch could skip it entirely and nothing would ever
        // reclaim it. Coalesced waiters re-record the same value — idempotent.
        let outcome = try await task.value
        record(outcome, key: key, model: model, base: baseURLString)
        return outcome
    }

    private func clearInFlight(_ key: String) {
        inFlight[key] = nil
    }

    private func record(
        _ outcome: EnsureOutcome, key: String, model: String, base: String
    ) {
        switch outcome {
        case .loaded(let instanceID), .adopted(let instanceID):
            owned[key] = OwnedChatModel(
                modelName: model, baseURLString: base, instanceID: instanceID)
            notifyLedgerChanged()
        case .skipped:
            // Listing failed (fail-open) or the model name was blank — we have
            // no instance id, so there is nothing we could later unload.
            break
        }
    }

    /// True while a load for this (base, model) is in flight. Residency
    /// reconciliation must treat it as protected: the model is not yet in the
    /// ledger, so without this it is invisible to BOTH residency signals and a
    /// concurrent switch would skip it.
    func hasInFlightEnsure(modelName: String, baseURLString: String) -> Bool {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return false }
        return inFlight[Self.key(model: model, base: baseURLString)] != nil
    }

    // MARK: - Reclaim

    /// Unloads an instance this app manages and drops it from the ledger.
    ///
    /// Lives on the actor, alongside the ledger and the census, so the three
    /// cannot disagree. Two invariants it exists to hold:
    /// - **No adopting a dying instance.** An unload takes a network round
    ///   trip, during which the instance is still listed. `ensureLoaded` waits
    ///   for a pending reclaim of the same key rather than adopting a corpse
    ///   and returning without loading.
    /// - **No erasing a newer record.** Ownership is dropped only when the
    ///   ledger still holds the exact instance that was unloaded, so a
    ///   re-adoption that landed during the round trip survives.
    func reclaim(_ instance: OwnedChatModel, client: any LLMClient) async throws {
        let key = Self.key(model: instance.modelName, base: instance.baseURLString)
        let task = Task.detached {
            try await client.unloadModel(
                instanceID: instance.instanceID,
                baseURLString: instance.baseURLString
            )
        }
        unloading[key] = task
        defer { unloading[key] = nil }

        try await task.value
        if owned[key]?.instanceID == instance.instanceID {
            owned[key] = nil
            notifyLedgerChanged()
        }

        // The 200 comes back BEFORE the instance is gone: measured 2026-07-19,
        // ack at 213ms, instance out of the listing and ~4GB of RAM returned at
        // 400ms. Loading the replacement inside that window sees the memory as
        // still taken and fails with `model_load_failed`. Settle on the
        // observable state instead of trusting the ack.
        await Self.awaitInstanceGone(instance, client: client)
    }

    /// Outcome of reaping an UNOWNED duplicate instance — a same-model sibling
    /// of a managed instance that the one-slot ledger can't represent.
    nonisolated enum DuplicateReapOutcome: Sendable {
        case unloaded
        /// The instance is owned under SOME ledger key — it is another
        /// authority's keeper (an alias-base ledger entry, or a model the
        /// embedding service also manages). Reaping it would strand that
        /// authority. Left alone.
        case skippedOwned
        /// An open request or in-flight ensure exists for this (base, model):
        /// the stream might be served by this very instance. Deferred.
        case skippedBusy
        case failed(Error)
    }

    /// Unloads a resident duplicate this app does NOT own, atomically checking
    /// the in-use signals FIRST so the check-to-unload gap is zero — the
    /// orchestrator's reconcile loop checks the census on the main actor, but a
    /// stream can open between that check and this call, so the authoritative
    /// re-check lives here where the census does.
    ///
    /// Crucially it NEVER touches the ledger: the instance was never owned, so
    /// there is nothing to drop — and a concurrent ensure that adopted this
    /// exact id in the window keeps its fresh ownership record intact (the
    /// `reclaim` exact-id drop was designed for OWNED unloads and would erase
    /// that adoption). `unloading[key]` is registered so a later ensure waits
    /// this unload out rather than adopting a dying instance.
    func reclaimUnownedDuplicate(
        instanceID: String,
        modelName: String,
        baseURLString: String,
        client: any LLMClient
    ) async -> DuplicateReapOutcome {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.key(model: model, base: baseURLString)
        // Owned under ANY key ⇒ someone's keeper (alias base / embedding
        // authority). Never reap it.
        if owned.values.contains(where: { $0.instanceID == instanceID }) {
            return .skippedOwned
        }
        // Busy right now for this (base, model): defer — the open stream or the
        // in-flight load might resolve to this instance.
        if openRequests[key] != nil || inFlight[key] != nil {
            return .skippedBusy
        }

        let task = Task.detached {
            try await client.unloadModel(instanceID: instanceID, baseURLString: baseURLString)
        }
        unloading[key] = task
        defer { unloading[key] = nil }
        do {
            try await task.value
        } catch {
            return .failed(error)
        }
        await Self.awaitInstanceGone(
            OwnedChatModel(modelName: model, baseURLString: baseURLString, instanceID: instanceID),
            client: client
        )
        return .unloaded
    }

    private static func awaitInstanceGone(
        _ instance: OwnedChatModel, client: any LLMClient
    ) async {
        let deadline = Date().addingTimeInterval(ModelResidencyConstants.unloadSettleTimeout)
        while Date() < deadline {
            guard let resident = try? await client.listLoadedInstances(
                baseURLString: instance.baseURLString)
            else { return }  // can't observe ⇒ don't stall the switch
            if !resident.contains(where: { $0.instanceID == instance.instanceID }) { return }
            try? await Task.sleep(for: ModelResidencyConstants.unloadSettlePollInterval)
        }
    }

    private static func performEnsure(
        model: String,
        baseURLString: String,
        client: any LLMClient
    ) async throws -> EnsureOutcome {
        // The server is the source of truth for "already loaded" — adopt when
        // present, so the same model is never loaded twice (a redundant load
        // costs a duplicate instance and its memory). Listing failure →
        // fail-open: the chat call will produce the canonical connection error
        // itself.
        let loaded: [LoadedModelInstance]
        do {
            loaded = try await client.listLoadedInstances(baseURLString: baseURLString)
        } catch {
            return .skipped
        }
        if let existing = loaded.first(where: { sameModel($0.modelName, model) }) {
            return .adopted(instanceID: existing.instanceID)
        }

        let instanceID = try await client.loadModel(
            modelName: model, baseURLString: baseURLString)
        return .loaded(instanceID: instanceID)
    }

    // MARK: - Ownership ledger

    /// Every chat instance this app currently manages.
    ///
    /// "Manages" covers BOTH the model we loaded and one we adopted because it
    /// was already resident — the same rule `EmbeddingModelLifecycleService`
    /// has always used (it stores an adopted `instance_id` and later unloads
    /// it). Adopting into ownership is what lets residency survive an app
    /// restart: after relaunch the ledger is empty, and without adoption a
    /// model left over from the previous run could never be reclaimed.
    ///
    /// The consequence is deliberate and worth knowing: a model you loaded by
    /// hand in the LM Studio UI becomes app-managed the first time a request
    /// uses it, and is then unloaded when nothing references it any more.
    func ownedModels() -> [OwnedChatModel] {
        Array(owned.values)
    }

    /// Called after every ledger change so the orchestrator can persist it.
    /// Unset ⇒ in-memory only (tests, headless).
    private var onLedgerChanged: (@Sendable ([OwnedChatModel]) -> Void)?

    func setLedgerObserver(_ observer: @escaping @Sendable ([OwnedChatModel]) -> Void) {
        onLedgerChanged = observer
    }

    /// Re-claims persisted ledger entries, keeping ONLY those whose instance is
    /// still resident.
    ///
    /// The residency check is the safety valve: instance ids are deterministic
    /// (`modelName` for the first instance), so a stale record would otherwise
    /// claim an identically-named instance the user hand-loaded after
    /// restarting LM Studio. If LM Studio restarted, nothing matches and the
    /// ledger correctly empties.
    func restore(_ persisted: [OwnedChatModel], resident: Set<String>) {
        for entry in persisted where resident.contains(entry.instanceID) {
            owned[Self.key(model: entry.modelName, base: entry.baseURLString)] = entry
        }
        notifyLedgerChanged()
    }

    private func notifyLedgerChanged() {
        onLedgerChanged?(Array(owned.values))
    }

    /// Records ownership of an instance that is already resident, without
    /// loading anything. Used at work-folder open to adopt models a previous
    /// run left behind, so a later switch can still reclaim them.
    func adoptExistingInstance(modelName: String, baseURLString: String, instanceID: String) {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !instanceID.isEmpty else { return }
        owned[Self.key(model: model, base: baseURLString)] = OwnedChatModel(
            modelName: model, baseURLString: baseURLString, instanceID: instanceID)
        notifyLedgerChanged()
    }

    /// Forgets an instance — call after a successful unload so a later
    /// reconcile does not try to unload it again.
    func releaseOwnership(modelName: String, baseURLString: String) {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        owned[Self.key(model: model, base: baseURLString)] = nil
        notifyLedgerChanged()
    }

    // MARK: - Request census

    /// Registers an open chat request against (base, model). MUST be balanced
    /// by `endRequest` on every exit path (the client brackets it in a
    /// `defer`). Blank model names are not tracked — such a request fails at
    /// the server anyway and would key an entry nothing can query.
    func beginRequest(modelName: String, baseURLString: String) {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        openRequests[Self.key(model: model, base: baseURLString), default: 0] += 1
    }

    func endRequest(modelName: String, baseURLString: String) {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        let key = Self.key(model: model, base: baseURLString)
        guard let count = openRequests[key] else { return }
        // Drop the entry at zero rather than storing 0 — `hasOpenRequest`
        // tests for presence, and a lingering 0 would read as "in use".
        if count <= 1 { openRequests[key] = nil } else { openRequests[key] = count - 1 }
    }

    /// Whether a chat request is streaming against this exact (base, model)
    /// right now. Consulted by `NTMSOrchestrator.switchChatModel` before an
    /// unload: pulling the instance mid-stream kills the request.
    func hasOpenRequest(modelName: String, baseURLString: String) -> Bool {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return false }
        return openRequests[Self.key(model: model, base: baseURLString)] != nil
    }

    // MARK: - Model identity

    /// Whether two model names denote the same model. Case- and
    /// whitespace-insensitive: LM Studio keys are lowercase by convention, but
    /// a hand-typed per-role override can differ in case, and treating that as
    /// a different model would load a redundant duplicate instance.
    nonisolated static func sameModel(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// Identity of a loadable model instance. Folds exactly what `sameModel`
    /// and `String.normalizedBaseURL` fold, so the coalescing key, the request
    /// census, the ledger, and any external in-use registry (e.g. the
    /// per-step active-model set consulted by residency reconciliation) all
    /// agree on what "the same model" means.
    nonisolated static func residencyKey(model: String, base: String) -> String {
        "\(base.normalizedBaseURL)|\(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private nonisolated static func key(model: String, base: String) -> String {
        residencyKey(model: model, base: base)
    }
}
