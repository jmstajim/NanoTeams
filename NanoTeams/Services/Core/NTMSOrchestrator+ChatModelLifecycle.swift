import Foundation

/// Residency management for chat models: NanoTeams keeps a ledger of the LM
/// Studio instances it manages and reconciles them against what the settings
/// actually reference.
///
/// Why the app has to do this at all: `ChatModelEnsurer` loads models
/// EXPLICITLY (never JIT), and explicit instances are exempt from LM Studio's
/// Auto-Evict — the exemption is the whole point, since it is what lets chat,
/// Vision and embedding stay resident together. But Auto-Evict was also what
/// used to free the previous model when the user switched. Taking the exemption
/// means taking the eviction responsibility, and this file is where it lives.
/// The embedding half has always worked this way
/// (`EmbeddingModelLifecycleService`); this is the same discipline for chat.
extension NTMSOrchestrator {

    // MARK: - Dependency resolution (the ONLY place residency builds a real client)

    /// The chat-lifecycle client for THIS orchestrator, and the single site in
    /// the residency subsystem that constructs a real `LLMClientRouter`.
    ///
    /// `chatLifecycleClient == nil` is the production shape, so production
    /// behaviour is unchanged — a fresh router per call, exactly as before. What
    /// changes is the meaning of a caller that passes no client: it now inherits
    /// THIS orchestrator's client instead of silently minting a live one. In
    /// tests that is the injected stub, which makes every entry point below
    /// network-free by construction rather than by each caller remembering an
    /// argument — including the no-argument production callers
    /// (`ModelResidencyHooks`, `LLMSettingsSheetView`) and any entry point added
    /// later. Pinned by `ChatModelLifecycleClientResolutionPinTests`.
    private var resolvedChatLifecycleClient: any LLMClient {
        chatLifecycleClient ?? LLMClientRouter()
    }

    /// The ownership ledger for THIS orchestrator. Same rationale: a test holding
    /// a fresh `ChatModelEnsurer()` can no longer fall through to the
    /// process-global one and adopt — then unload — the developer's hand-loaded
    /// model, which is the hazard `openWorkFolder` documents at its call site.
    private func resolvedEnsurer(_ explicit: ChatModelEnsurer?) -> ChatModelEnsurer {
        explicit ?? chatModelEnsurer
    }

    /// Brings LM Studio's resident set in line with what the settings
    /// reference. Unloads every instance this app manages that no longer has a
    /// referencing slot — the model you switched away from, a Vision override
    /// after Vision was turned off, a judge override after its judge was
    /// disabled.
    ///
    /// Also reaps DUPLICATE instances of managed models (`name` + `name:2`
    /// co-resident). The ledger deliberately holds one instance per
    /// (model, base) — two instances of one model is never a desired state, so
    /// the excess is repaired here rather than represented there. Duplicates
    /// enter through adoption collapse (both instances listed at open, last
    /// one wins the ledger slot), a JIT load racing an explicit one, or a
    /// hand-load next to a managed instance. Reaping keys on the owned
    /// instance being itself listed: if it is gone (server restarted
    /// mid-session), an identically-named resident is the user's fresh
    /// hand-load, not a duplicate.
    ///
    /// Only app-managed instances — and duplicates of app-managed models —
    /// are touched (see `ChatModelEnsurer.ownedModels`). A model that was
    /// loaded by hand in the LM Studio UI and never used by NanoTeams is never
    /// unloaded here.
    ///
    /// Skips anything mid-stream: pulling an instance out from under an open
    /// request kills it, and the census is (base, model)-keyed — it cannot say
    /// WHICH instance serves the stream, so a busy model defers its sibling
    /// reap too. That is a deferral, not a leak — the next reconcile sweeps
    /// it, and reconciles run on every settings change and run boundary.
    /// `client: nil` / `ensurer: nil` mean "this orchestrator's own", never the
    /// process global — see `resolvedChatLifecycleClient`.
    @discardableResult
    func reconcileChatModelResidency(
        client: (any LLMClient)? = nil,
        ensurer: ChatModelEnsurer? = nil
    ) async -> [String] {
        let ensurer = resolvedEnsurer(ensurer)
        // COALESCING latch, not a drop. A pass that arrives while another is in
        // flight records a rerun request instead of returning empty and losing
        // its work: the running pass loops once more when it finishes, so a
        // dedicated de-reference sweep (removeTask / switchTeam) can never be
        // swallowed by the run-boundary sweep the same flow spawns — whose
        // snapshot predates the de-reference. Dropping (the old behavior) turned
        // "bounded deferral" back into "unbounded leak".
        guard !isReconcilingResidency else {
            pendingResidencyReconcile = true
            return []
        }
        isReconcilingResidency = true
        defer { isReconcilingResidency = false }

        let resolvedClient = client ?? resolvedChatLifecycleClient
        var notices: [String] = []
        repeat {
            pendingResidencyReconcile = false
            notices = await runResidencyReconcilePass(client: resolvedClient, ensurer: ensurer)
        } while pendingResidencyReconcile
        return notices
    }

    /// One reconcile pass. Extracted so the coalescing latch above can re-run it
    /// whenever a colliding pass was recorded during its awaits.
    private func runResidencyReconcilePass(
        client resolvedClient: any LLMClient,
        ensurer: ChatModelEnsurer
    ) async -> [String] {
        var notices: [String] = []

        // Models a live step is actively using (MODEL-SPECIFIC, unlike the
        // removed model-agnostic busy check): reclaiming one out from under a
        // step that resumes it every tool-loop iteration would thrash a reload
        // per foreign engine transition. The census misses the gaps between a
        // step's requests (a long tool run opens none); this covers them.
        let activeModelKeys = llmExecutionService.activeModelKeys()
        // The embedding model's instances belong to EmbeddingModelLifecycleService,
        // which reaps its own siblings — the chat reconciler must not fight it
        // over the same pile (different keep-rules would each unload the other's
        // keeper). `effectiveEmbeddingConfig` is the single source of truth.
        let embedConfig = configuration.effectiveEmbeddingConfig

        // One listing per server per pass, fetched lazily — an empty ledger
        // produces zero client calls. `nil` = listing failed for that base:
        // skip reaping there (a missed reap creates nothing; the next pass
        // retries) without stopping the ledger-keyed orphan reclaim below.
        var listings: [String: [LoadedModelInstance]?] = [:]

        for instance in await ensurer.ownedModels() {
            // Busy guard FIRST (before the referenced check): a busy model's
            // sibling reap must defer too, since the open stream might be
            // served by either instance. Three ways a model is in use right
            // now: a stream is open on it, a load for it is still in flight
            // (not even in the ledger yet), or a live step captured it.
            let streaming = await ensurer.hasOpenRequest(
                modelName: instance.modelName, baseURLString: instance.baseURLString)
            let loading = await ensurer.hasInFlightEnsure(
                modelName: instance.modelName, baseURLString: instance.baseURLString)
            let activeKey = ChatModelEnsurer.residencyKey(
                model: instance.modelName, base: instance.baseURLString)
            if streaming || loading || activeModelKeys.contains(activeKey) { continue }

            // Duplicate reap — runs even for still-referenced models (the
            // live-observed pile-up was duplicates of the ACTIVE model) EXCEPT
            // the embedding model, whose duplicates are its own service's job.
            let isEmbeddingModel = ChatModelEnsurer.sameModel(
                instance.modelName, embedConfig.modelName)
                && instance.baseURLString.normalizedBaseURL
                    == embedConfig.baseURLString.normalizedBaseURL
            if !isEmbeddingModel {
                let normalizedBase = instance.baseURLString.normalizedBaseURL
                let listing: [LoadedModelInstance]?
                if let cached = listings[normalizedBase] {
                    listing = cached
                } else {
                    listing = try? await resolvedClient.listLoadedInstances(
                        baseURLString: instance.baseURLString)
                    listings[normalizedBase] = listing
                }
                // Reap only when our OWNED instance is itself listed: if it is
                // gone (server restarted mid-session), an identically-named
                // resident is the user's fresh hand-load, not a duplicate.
                if let listing,
                   listing.contains(where: { $0.instanceID == instance.instanceID }) {
                    for duplicate in listing
                    where ChatModelEnsurer.sameModel(duplicate.modelName, instance.modelName)
                        && duplicate.instanceID != instance.instanceID {
                        // Atomic, authority-aware, ledger-free reap on the
                        // ensurer: it re-checks the census and skips any
                        // instance owned under another key (alias base /
                        // embedding), so it can neither kill a fresh stream nor
                        // erase a concurrent adoption's ownership record.
                        let outcome = await ensurer.reclaimUnownedDuplicate(
                            instanceID: duplicate.instanceID,
                            modelName: instance.modelName,
                            baseURLString: instance.baseURLString,
                            client: resolvedClient
                        )
                        if case .failed(let error) = outcome {
                            notices.append(
                                "Couldn't unload duplicate instance '\(duplicate.instanceID)' of "
                                    + "'\(instance.modelName)': \(error.localizedDescription)")
                        }
                    }
                }
            }

            if modelIsStillReferenced(instance.modelName, base: instance.baseURLString) {
                continue
            }

            do {
                try await ensurer.reclaim(instance, client: resolvedClient)
            } catch {
                // A stale instance costs memory, not correctness. `reclaim`
                // keeps ownership on failure so the next pass retries —
                // dropping it would orphan the instance with no id to unload
                // it by.
                notices.append(
                    "Couldn't unload '\(instance.modelName)': \(error.localizedDescription)")
            }
        }

        return notices
    }

    /// Records ownership of already-resident instances that a settings slot
    /// references, WITHOUT loading anything.
    ///
    /// Closes the restart gap: the ledger is in-memory, so after a relaunch the
    /// models this app loaded last session look foreign and would never be
    /// reclaimed. Adopting only the ones a slot references keeps genuinely
    /// hand-loaded models out of the ledger.
    ///
    /// `client: nil` / `ensurer: nil` mean "this orchestrator's own", never the
    /// process global — see `resolvedChatLifecycleClient`.
    func adoptResidentReferencedModels(
        client: (any LLMClient)? = nil,
        ensurer: ChatModelEnsurer? = nil
    ) async {
        let ensurer = resolvedEnsurer(ensurer)
        let resolvedClient = client ?? resolvedChatLifecycleClient

        // Persist every ledger change from here on. Set before restoring so the
        // restore's own pruning is written back.
        let config = configuration
        await ensurer.setLedgerObserver { models in
            Task { @MainActor in config.chatModelLedger = models }
        }

        // EVERY server a slot resolves to, not just the global one: a Vision or
        // judge override, or a per-role override, can live on a different
        // endpoint, and an instance there would otherwise never be listed and
        // so never be reclaimable.
        var residentIDs = Set<String>()
        for base in referencedBaseURLs {
            // Best-effort: a listing failure just means the ledger stays empty
            // for that server and ownership is picked up on first use instead.
            guard let resident = try? await resolvedClient.listLoadedInstances(baseURLString: base)
            else { continue }
            residentIDs.formUnion(resident.map(\.instanceID))

            for instance in resident where modelIsStillReferenced(instance.modelName, base: base) {
                await ensurer.adoptExistingInstance(
                    modelName: instance.modelName,
                    baseURLString: base,
                    instanceID: instance.instanceID
                )
            }
        }

        // Re-claim what a previous session recorded. Adoption above only covers
        // instances a slot STILL references; a model the user already switched
        // away from is exactly the orphan that has to come back from the
        // persisted ledger, or nothing can ever reclaim it.
        await ensurer.restore(configuration.chatModelLedger, resident: residentIDs)
    }

    /// Distinct, non-empty servers any referenced slot points at.
    private var referencedBaseURLs: [String] {
        var seen = Set<String>()
        var out: [String] = []

        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.normalizedBaseURL).inserted else { return }
            out.append(trimmed)
        }

        add(configuration.llmBaseURLString)
        for slot in configuration.referencedModelSlots { add(slot.normalizedBase) }
        for team in snapshot?.projection.teams ?? [] {
            for role in team.roles {
                if let url = role.llmOverride?.baseURLString { add(url) }
            }
        }
        return out
    }

    /// Reacts to a committed model-setting change: reconcile residency (which
    /// releases whatever the change orphaned), then load the new model.
    ///
    /// The unload half is deliberately NOT expressed as "unload `oldModel`" —
    /// a delta handler only ever names the single model of the current
    /// transition, so anything a previous transition failed to free stayed
    /// resident forever. Reconciling against the whole referenced set fixes
    /// that class, not just this instance of it.
    func switchChatModel(
        oldModel: String,
        newModel: String,
        baseURLString: String,
        provider: LLMProvider = .lmStudio,
        client: (any LLMClient)? = nil,
        ensurer: ChatModelEnsurer? = nil
    ) async {
        let ensurer = resolvedEnsurer(ensurer)
        let old = oldModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same model (any casing) ⇒ nothing to swap: never unload-and-reload
        // what is already the desired state.
        guard !ChatModelEnsurer.sameModel(old, new), !base.isEmpty else { return }

        let resolvedClient = client ?? resolvedChatLifecycleClient

        // Every user-facing note is emitted ONCE at the end: `lastInfoMessage`
        // is a single coalescing slot, so writing an unload note and then a
        // "model ready" note would silently drop the first.
        var notices = await reconcileChatModelResidency(
            client: resolvedClient, ensurer: ensurer)

        guard !new.isEmpty else {
            emit(notices)
            return
        }
        // The explicit load half only applies to providers whose residency the
        // app manages (LM Studio). Ollama loads on first use and owns its own
        // eviction (`keep_alive`) — attempting `/api/v1/models/load` there
        // 404s and would surface a spurious "couldn't load model" banner on
        // every switch. Reconcile still ran above: it can only ever touch
        // LM-Studio-ledgered instances, e.g. the model orphaned by switching
        // the provider itself.
        guard provider.managesModelResidency else {
            emit(notices)
            return
        }
        do {
            try await ensurer.ensureLoaded(
                modelName: new,
                baseURLString: base,
                client: resolvedClient
            )
            notices.insert("Model ready: \(new)", at: 0)
            emit(notices)
        } catch {
            // `errorDescription` already names the model for the out-of-memory
            // case ("Couldn't load 'X' — …"), so prefixing it again produced
            // "Couldn't load model 'X': Couldn't load 'X' — …".
            lastErrorMessage = error.localizedDescription
            emit(notices)
        }
    }

    private func emit(_ notices: [String]) {
        guard !notices.isEmpty else { return }
        lastInfoMessage = notices.joined(separator: " ")
    }

    /// Reconcile driven by a settings change that is not a model swap, and
    /// report anything that could not be reclaimed.
    ///
    /// Pure forwarder: `nil`s stay `nil` and `reconcileChatModelResidency`
    /// resolves them against this orchestrator.
    func reconcileAndReportResidency(
        client: (any LLMClient)? = nil,
        ensurer: ChatModelEnsurer? = nil
    ) async {
        emit(await reconcileChatModelResidency(client: client, ensurer: ensurer))
    }

    // MARK: - Residency queries for the Downloaded Models card

    /// Canonical names of every model instance resident on `baseURLString`.
    ///
    /// Lives here rather than in `NTMSOrchestrator+DownloadedModels` so the
    /// client keeps resolving through `resolvedChatLifecycleClient` — the one
    /// seam allowed to build a real router (`ChatModelLifecycleClientResolutionPinTests`).
    ///
    /// Empty on ANY failure. Callers use this to decorate a row with a "loaded"
    /// badge, never to gate an action, so an unreachable server degrades to
    /// "no badge" rather than to a false claim either way.
    func residentModelNames(
        baseURLString: String,
        client: (any LLMClient)? = nil
    ) async -> Set<String> {
        let resolvedClient = client ?? resolvedChatLifecycleClient
        guard let instances = try? await resolvedClient.listLoadedInstances(baseURLString: baseURLString)
        else { return [] }
        return Set(instances.map(\.modelName))
    }

    /// Best-effort unload of every resident instance whose canonical name
    /// matches one of `modelNames` — used immediately before a model's files are
    /// deleted from disk.
    ///
    /// Unlike the reconciler, this does NOT restrict itself to app-owned
    /// instances: the user asked for this specific model to be removed, so
    /// leaving a hand-loaded copy of it serving from RAM after its files are
    /// gone would be the surprising outcome. Routing through
    /// `ChatModelEnsurer.reclaim` still drops ledger ownership when we happen to
    /// own it, and gives the `awaitInstanceGone` settle for free — LM Studio
    /// acknowledges an unload before it actually releases the instance.
    ///
    /// Failures are swallowed on purpose. Trashing a directory is a rename, so
    /// an instance that refuses to unload does not make the delete unsafe; it
    /// only means LM Studio keeps serving that copy until it is unloaded or the
    /// app restarts.
    func unloadResidentInstances(
        matching modelNames: [String],
        baseURLString: String,
        client: (any LLMClient)? = nil,
        ensurer: ChatModelEnsurer? = nil
    ) async {
        guard !modelNames.isEmpty else { return }
        let resolvedClient = client ?? resolvedChatLifecycleClient
        let ensurer = resolvedEnsurer(ensurer)

        guard let instances = try? await resolvedClient.listLoadedInstances(baseURLString: baseURLString)
        else { return }

        for instance in instances
        where modelNames.contains(where: { ChatModelEnsurer.sameModel($0, instance.modelName) }) {
            try? await ensurer.reclaim(
                OwnedChatModel(
                    modelName: instance.modelName,
                    baseURLString: baseURLString,
                    instanceID: instance.instanceID
                ),
                client: resolvedClient
            )
        }
    }

    /// Residency sweep for a run-boundary event, wired into every engine's
    /// `onStateChanged` (`engineForTask`). Any non-`.running` transition
    /// qualifies — done, failed, the acceptance/supervisor parks, pause, and
    /// stop's `.pending` — because each means streams for that task are
    /// ending, which is exactly when the in-use census releases a model whose
    /// reference disappeared mid-run. Without this, that deferral waited for
    /// an unrelated settings change to sweep it. Enumerating "terminal enough"
    /// states instead would recreate the delta-handler failure mode this
    /// subsystem exists to avoid.
    ///
    /// Returns the spawned task so tests can await completion; `nil` when the
    /// transition doesn't qualify. Cheap when nothing is orphaned (an empty
    /// ledger makes zero client calls) and coalescing-latched, so firing on
    /// every transition of every engine is safe.
    ///
    /// SILENT: reconciles via `reconcileChatModelResidency` and discards the
    /// notices instead of routing through `reconcileAndReportResidency`. This
    /// fires on every chat-turn park, pause, acceptance and completion — a
    /// persistently-failing unload (reclaim keeps ownership to retry) would
    /// otherwise re-post its failure banner on every one of those, clobbering
    /// the single `lastInfoMessage` slot for hours. Residency failures still
    /// surface on the USER-initiated settings paths.
    @discardableResult
    func sweepResidencyAfterEngineTransition(_ state: TeamEngineState) -> Task<Void, Never>? {
        guard state != .running else { return nil }
        return Task { [weak self] in
            guard let self else { return }
            await self.reconcileChatModelResidency()
        }
    }

    /// Settings that can orphan a managed model, and whose writes are
    /// COMMITTED rather than continuous.
    ///
    /// Two deliberate exclusions:
    /// - **Server URL fields.** `LLMEndpointEditor` binds them to a live
    ///   `TextField`, so every keystroke writes the property. Reconciling on
    ///   that would compare a half-typed URL against the owned instance's
    ///   stored base, decide the model is unreferenced, and unload a resident
    ///   35B because the user was editing a port number. URLs reconcile from
    ///   the editor's `onURLCommit` boundary instead.
    /// - **`llmModelName` / `visionModelName`.** Each has its own hook, which
    ///   reconciles *and* loads the replacement; including them here would run
    ///   two concurrent reconciles for one user action.
    ///
    /// Equatable so SwiftUI's `onChange` fires once per real change rather
    /// than on every unrelated configuration write.
    var residencyRelevantSettings: ResidencySettingsFingerprint {
        ResidencySettingsFingerprint(
            visionEnabled: configuration.visionEnabled,
            bashMode: configuration.bashMode,
            bashRestriction: configuration.bashRestrictionLevel,
            bashJudgeOverride: configuration.bashJudgeLLMOverride,
            computerUseMode: configuration.computerUseMode,
            computerUseRestriction: configuration.computerUseRestrictionLevel,
            computerUseJudgeOverride: configuration.computerUseJudgeLLMOverride,
            teamGenOverride: configuration.teamGenLLMOverride
        )
    }

    // MARK: - Reference check

    /// True when any settings slot OR any per-role override in the open work
    /// folder still resolves to this (base, model) pair.
    ///
    /// The settings half lives on `StoreConfiguration` (it owns the slots and
    /// their enablement gates); the per-role half lives here because the roles
    /// come from the work-folder snapshot.
    ///
    /// Note there is deliberately NO "is the app busy" term. A running step
    /// captured its config once at start (`+StepLifecycle`), so it keeps using
    /// the model it began with — but `streamChat` calls `ensureLoaded` before
    /// EVERY request, so an unload that races a live step costs one reload, not
    /// a failure. A busy-check would trade that bounded reload for an unbounded
    /// leak: a step running on model B would pin model A forever.
    func modelIsStillReferenced(_ model: String, base: String) -> Bool {
        if configuration.referencesModel(model, base: base) { return true }

        let normalizedBase = base.normalizedBaseURL
        let globalModel = configuration.llmModelName
        let globalBase = configuration.llmBaseURLString

        func matches(_ override: LLMOverride?) -> Bool {
            guard let override, !override.isEmpty else { return false }
            let roleModel = Self.inherited(override.modelName, fallback: globalModel)
            let roleBase = Self.inherited(override.baseURLString, fallback: globalBase)
            return roleBase.normalizedBaseURL == normalizedBase
                && ChatModelEnsurer.sameModel(roleModel, model)
        }

        for team in snapshot?.projection.teams ?? [] {
            for role in team.roles where matches(role.llmOverride) { return true }
        }
        // Generated teams live on the task, not in `teams` — a delegation child
        // running on a generated roster would otherwise have its model swept
        // mid-run. The ACTIVE task is deliberately absent from `loadedTasks`
        // (`loadedTask()` special-cases it), so check it explicitly: its
        // generated roster deserves the same protection.
        if let active = activeTask {
            for role in active.generatedTeam?.roles ?? [] where matches(role.llmOverride) {
                return true
            }
        }
        for task in snapshot?.loadedTasks.values ?? [:].values {
            for role in task.generatedTeam?.roles ?? [] where matches(role.llmOverride) {
                return true
            }
        }
        return false
    }

    /// An unset (or blank) override field means "inherit the global value" —
    /// same widening as `StoreConfiguration.resolvedOverrideSlot`, and safe for
    /// the same reason: it can only ever add a reference, i.e. skip an unload.
    private static func inherited(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
    }
}

/// Value fingerprint of every setting that changes which models are
/// referenced. See `NTMSOrchestrator.residencyRelevantSettings`.
nonisolated struct ResidencySettingsFingerprint: Equatable {
    let visionEnabled: Bool
    let bashMode: BashExecutionMode
    let bashRestriction: BashRestrictionLevel
    let bashJudgeOverride: LLMOverride?
    let computerUseMode: ComputerUseMode
    let computerUseRestriction: ComputerUseRestrictionLevel
    let computerUseJudgeOverride: LLMOverride?
    let teamGenOverride: LLMOverride?
}
