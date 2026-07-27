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

        return models.map { model in
            let isLoaded = model.referenceHints.contains { hint in
                resident.contains { ChatModelEnsurer.sameModel($0, hint) }
            }
            guard isLoaded else { return model }
            return DownloadedModel(
                id: model.id,
                displayName: model.displayName,
                sizeBytes: model.sizeBytes,
                detail: model.detail,
                isLoaded: true,
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

    /// One sentence naming what would break, or `nil` when nothing points at
    /// this model.
    ///
    /// Both checks are the EXISTING single sources of truth, called as-is:
    /// `StoreConfiguration.referencesModel` enumerates the settings slots (and
    /// `StoreConfiguration+ModelResolution` documents that a caller-side copy of
    /// that enumeration is exactly how three override slots were once missed),
    /// while `modelIsStillReferenced` adds per-role overrides in `teams.json`
    /// and generated-team rosters on loaded tasks. Subtracting the first from
    /// the second is what distinguishes "your settings" from "a team role"
    /// without duplicating either list.
    func downloadedModelReferenceWarning(_ model: DownloadedModel, base: String) -> String? {
        let inSettings = model.referenceHints.contains {
            configuration.referencesModel($0, base: base)
        }
        if inSettings {
            return "Your LLM settings currently use this model."
        }
        let anywhere = model.referenceHints.contains {
            modelIsStillReferenced($0, base: base)
        }
        return anywhere ? "A team role currently uses this model." : nil
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
        if config.provider == .lmStudio, model.isLoaded {
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
