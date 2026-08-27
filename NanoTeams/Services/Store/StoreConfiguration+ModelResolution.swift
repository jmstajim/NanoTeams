import Foundation

/// A concrete model some settings slot resolves to, in comparison form.
/// `normalizedBase` is folded through `String.normalizedBaseURL` so
/// `http://X:1234/` and `http://x:1234` are one server.
nonisolated struct ModelSlotReference: Hashable {
    let modelName: String
    let normalizedBase: String
}

/// How persisted settings slots resolve to a concrete (model, server) pair,
/// and which of them still point at a given model.
///
/// This lives on `StoreConfiguration` (GRASP Information Expert) because it
/// owns every slot. A caller-side copy of the enumeration silently rots each
/// time a slot is added — which is exactly how the team-generation, bash-judge
/// and computer-use-judge overrides came to be missed by the model-unload
/// guard while the global/Vision/embedding slots were covered.
extension StoreConfiguration {

    // MARK: - Vision fallback

    /// The server a Vision request actually goes to: the Vision override when
    /// set, otherwise the global server. Trimmed on BOTH branches — the
    /// asymmetric version of this let `"   "` behave as a real value on one
    /// side and as "inherit" on the other (see the I3 note on
    /// `isVisionConfigured`).
    var resolvedVisionBaseURL: String {
        let override = visionBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard override.isEmpty else { return override }
        return llmBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The provider the Vision slot speaks — its own when pinned, else the
    /// global one. Single source of truth shared by `visionLLMConfig`
    /// (request time), the Vision card's model-list fetches, and the
    /// model-switch residency hook.
    var resolvedVisionProvider: LLMProvider {
        visionProvider ?? llmProvider
    }

    /// Resolves a raw Vision model-name field through the empty→global
    /// fallback. Takes the value as a parameter rather than reading
    /// `visionModelName` so the model-switch hook can resolve the OLD value
    /// (which is no longer in the configuration) through the identical chain.
    func resolvedVisionModel(for raw: String) -> String {
        let override = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard override.isEmpty else { return override }
        return llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Slot references

    /// Every (model, server) pair a chat request could target from persisted
    /// settings. Order is irrelevant — callers only ever test membership.
    ///
    /// Deliberately excludes per-role overrides: those live in `teams.json`,
    /// not in settings, so the orchestrator contributes them separately from
    /// the work-folder snapshot.
    var referencedModelSlots: Set<ModelSlotReference> {
        var slots: Set<ModelSlotReference> = [
            ModelSlotReference(
                modelName: llmModelName.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedBase: llmBaseURLString.normalizedBaseURL
            )
        ]

        if let vision = visionLLMConfig {
            slots.insert(ModelSlotReference(
                modelName: vision.modelName,
                normalizedBase: vision.baseURLString.normalizedBaseURL
            ))
        }

        let embedding = effectiveEmbeddingConfig
        slots.insert(ModelSlotReference(
            modelName: embedding.modelName,
            normalizedBase: embedding.baseURLString.normalizedBaseURL
        ))

        // Judge overrides count only while their judge would actually be
        // consulted. A disabled feature's model is not "referenced" — keeping
        // it resident is the accumulation this reconciler exists to stop, and
        // it is the same rule Vision already gets for free via
        // `visionLLMConfig`'s `isVisionConfigured` gate.
        if bashJudgeIsActive { insertOverrideSlot(bashJudgeLLMOverride, into: &slots) }
        if computerUseJudgeIsActive { insertOverrideSlot(computerUseJudgeLLMOverride, into: &slots) }
        // Team generation has no on/off toggle — a configured override is
        // always a live slot.
        insertOverrideSlot(teamGenLLMOverride, into: &slots)

        // The benchmark's target model. Added 2026-08-25: it carries its own model name and
        // base URL and belonged to NO slot list, so deleting a model the benchmark targets
        // produced no warning at all — in either namespace, and even on an exact match. This
        // enumeration is the SSOT precisely so that omission is impossible to repeat.
        if let benchmarkTarget, !benchmarkTarget.modelName.isEmpty {
            slots.insert(ModelSlotReference(
                modelName: benchmarkTarget.modelName,
                normalizedBase: benchmarkTarget.baseURLString.normalizedBaseURL
            ))
        }

        return slots
    }

    /// The bash judge model is used by the Auto approval path AND by the
    /// "Ask AI" advisory on the MANUAL approval card
    /// (`BashAdviceService.advise`), so gating on `.auto` alone would unload a
    /// model Manual and Semi-automatic actively use. Only two things really
    /// retire it: bash off entirely, or Safety=Off, which short-circuits to
    /// allow before the judge is ever consulted.
    private var bashJudgeIsActive: Bool {
        bashMode != .off && bashRestrictionLevel != .off
    }

    /// Same shape for the computer-use judge.
    private var computerUseJudgeIsActive: Bool {
        computerUseMode == .auto && computerUseRestrictionLevel != .off
    }

    private func insertOverrideSlot(
        _ override: LLMOverride?, into slots: inout Set<ModelSlotReference>
    ) {
        if let slot = resolvedOverrideSlot(override) { slots.insert(slot) }
    }

    /// True when some settings slot still resolves to this (base, model) pair.
    /// Such a model must survive a sibling slot's switch — unloading it would
    /// break the slot that still points at it.
    func referencesModel(_ model: String, base: String) -> Bool {
        let normalizedBase = base.normalizedBaseURL
        return referencedModelSlots.contains { slot in
            slot.normalizedBase == normalizedBase
                && ChatModelEnsurer.sameModel(slot.modelName, model)
        }
    }

    /// Resolves an `LLMOverride` slot against the global config. An unset (or
    /// blank) field means "inherit the global value".
    ///
    /// Note the blank-field handling is deliberately WIDER than
    /// `LLMExecutionService.buildEffectiveConfig`, which nil-coalesces and so
    /// would send a literal empty model name. Treating blank as "inherit" here
    /// can only ever add a slot, i.e. skip an unload — the safe direction for
    /// a guard whose failure mode is killing a live request.
    private func resolvedOverrideSlot(_ override: LLMOverride?) -> ModelSlotReference? {
        guard let override, !override.isEmpty else { return nil }
        let model = Self.inherited(override.modelName, fallback: llmModelName)
        let base = Self.inherited(override.baseURLString, fallback: llmBaseURLString)
        guard !model.isEmpty else { return nil }
        return ModelSlotReference(modelName: model, normalizedBase: base.normalizedBaseURL)
    }

    private static func inherited(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
    }
}
