import Foundation

/// Orchestration for Settings → LLM → Downloaded Models: the view stays a dumb
/// renderer, and everything that needs to know about model residency or about
/// which slots reference a model lives here.
extension NTMSOrchestrator {

    // MARK: - Reads

    /// Models occupying disk on the host serving `config`, enriched with
    /// residency where the app can see it.
    ///
    /// The LM Studio store deliberately never talks to the server (so the card
    /// works with LM Studio closed) and therefore returns `isLoaded: false` for
    /// everything. Residency is a fact the residency subsystem owns, so it is
    /// overlaid here rather than pushed down into a disk-walking store.
    func downloadedModels(config: LLMConfig) async throws -> [DownloadedModel] {
        let models = try await downloadedModelStore.listDownloaded(config: config)
        guard config.provider == .lmStudio, !models.isEmpty else { return models }

        let resident = await residentModelNames(baseURLString: config.baseURLString)
        guard !resident.isEmpty else { return models }

        // A resident key nothing on disk explains means the two namespaces disagree, and then
        // "not loaded" is a guess rather than an answer for EVERY row — the same residue
        // argument `ModelReferenceResolver` makes, applied to residency instead of references.
        let unexplainedResident = resident.filter { key in
            !models.contains { m in m.referenceHints.contains { ChatModelEnsurer.sameModel($0, key) } }
        }
        let determinate = unexplainedResident.isEmpty

        return models.map { model in
            let isLoaded = model.referenceHints.contains { hint in
                resident.contains { ChatModelEnsurer.sameModel($0, hint) }
            }
            guard isLoaded || !determinate else { return model }
            return DownloadedModel(
                id: model.id,
                displayName: model.displayName,
                sizeBytes: model.sizeBytes,
                detail: model.detail,
                isLoaded: isLoaded,
                residencyIsDeterminate: determinate,
                referenceHints: model.referenceHints
            )
        }
    }

    func downloadedModelDeletion(config: LLMConfig) async -> DownloadedModelDeletion {
        await downloadedModelStore.deletionCapability(config: config)
    }

    func downloadedModelStorageLocation(config: LLMConfig) async -> String? {
        await downloadedModelStore.storageLocationDescription(config: config)
    }

    // MARK: - Reference warning

    /// One sentence naming what would break, a caution when it could not be determined, or
    /// `nil` when nothing points at this model.
    ///
    /// Three states rather than two (2026-08-25). The old shape subtracted "settings slots" from
    /// "everywhere" to label the source, and could only ever answer yes or no — so the measured
    /// namespace mismatch (`lmstudio-community/gpt-oss-20b-GGUF` on disk vs the shipped default
    /// `openai/gpt-oss-20b` in settings) produced NO warning, which the user reads as "nothing
    /// uses this" while Remove sends ~11 GB to the Trash.
    ///
    /// The site enumeration is still a single source of truth — `referencedModelSites` is the
    /// enumerating counterpart of `modelIsStillReferenced`, walking the same slots, role
    /// overrides and generated rosters once.
    /// `serverKeys` is supplied by the CALLER (the card holds `ModelCatalog`; the orchestrator
    /// does not) and has no default: a missing value is the "server said nothing" state, and it
    /// must be passed deliberately rather than defaulted into.
    func downloadedModelReferenceWarning(
        _ model: DownloadedModel, base: String, allFolders: [DownloadedModel],
        serverKeys: Set<String>?
    ) -> String? {
        switch referenceVerdict(model, base: base, allFolders: allFolders, serverKeys: serverKeys) {
        case .referenced(let where_):
            // The site carries its own full sentence: "your LLM settings currently USE" and "a
            // team role currently USES" disagree on the verb, so composing one here from a
            // fragment gets one of the two wrong.
            return where_.first ?? "Something currently uses this model."
        case .notReferenced:
            return nil
        case .undetermined(let unresolved):
            // The state the old Bool could not express, and the one the measured case lands in:
            // a reference this app could not match to ANY folder on disk. Reported as caution
            // rather than silence — absence of a warning reads as "nothing uses this".
            return "Couldn't verify. This app references \(unresolved.joined(separator: ", ")), "
                + "which it couldn't match to a folder on disk — this folder may be what backs it."
        }
    }

    /// The three-state answer, shared by the warning, the post-delete notice and the unload gate
    /// so they cannot disagree about what matched.
    func referenceVerdict(
        _ model: DownloadedModel, base: String, allFolders: [DownloadedModel],
        serverKeys: Set<String>?
    ) -> ModelReferenceResolver.Verdict {
        ModelReferenceResolver.resolve(
            folder: model,
            allFolders: allFolders,
            references: referencedModelSites(base: base),
            serverKeys: serverKeys
        )
    }

    // MARK: - Deletion

    /// Removes a downloaded model, unloading it first when it is resident.
    ///
    /// Deliberately does NOT rewrite any configuration. The reference set spans
    /// `teams.json` role overrides and per-task generated-team rosters, and
    /// silently rewriting those behind a delete is a bigger surprise than a
    /// stale model name — which already has a defined failure mode (preflight
    /// "model not found"). The confirmation dialog names the exposure up front
    /// via `downloadedModelReferenceWarning`, and a stale GLOBAL selection gets
    /// one plain info message afterwards. Warn before, inform after, mutate
    /// nothing.
    func deleteDownloadedModel(_ model: DownloadedModel, config: LLMConfig) async -> Result<Void, Error> {
        // Only LM Studio needs this: its files are about to move out from under
        // a runtime that has them open. Ollama evicts server-side as part of
        // `DELETE /api/delete`.
        // Gated on "residency is not a determinate NO", not on `model.isLoaded`. That flag is
        // set by the SAME hint match this whole entry is about, so on the measured case it read
        // `false` for a model that WAS loaded and the files were trashed out from under a live
        // runtime with no unload. `unloadResidentInstances` is documented best-effort, so an
        // unnecessary attempt costs nothing while a skipped one is unrecoverable.
        if config.provider == .lmStudio, model.isLoaded || !model.residencyIsDeterminate {
            await unloadResidentInstances(
                matching: model.referenceHints,
                baseURLString: config.baseURLString
            )
        }

        do {
            try await downloadedModelStore.delete(modelID: model.id, config: config)
        } catch {
            lastErrorMessage = "Couldn't remove \(model.displayName): \(error.localizedDescription)"
            return .failure(error)
        }

        let globalModel = configuration.llmModelName
        if !globalModel.isEmpty,
           model.referenceHints.contains(where: { ChatModelEnsurer.sameModel($0, globalModel) }) {
            lastInfoMessage = "Main LLM still points at \(globalModel) — pick a new model."
        }
        return .success(())
    }
}
