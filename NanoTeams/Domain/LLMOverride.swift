import Foundation

/// Per-role LLM configuration override within a team.
/// If a field is nil, the global default is used for that field.
///
/// Deliberately carries NO generation parameters (maxTokens / temperature /
/// samplers): the server's per-model config is the single source of truth for
/// sampling. Legacy `teams.json` files that still contain those keys decode
/// fine — unknown keys are ignored (pinned by `LLMOverrideTests`).
nonisolated struct LLMOverride: Codable, Hashable {
    var baseURLString: String?
    var modelName: String?
    /// Which API family the override server speaks. `nil` = inherit the
    /// global provider. Set this when the override URL points at a different
    /// provider than the global one (e.g. global chat on LM Studio, one role
    /// on an Ollama server) — without it the client would speak the wrong
    /// wire format to the override server.
    var provider: LLMProvider?

    /// True when no fields are set (effectively no override).
    var isEmpty: Bool {
        baseURLString == nil && modelName == nil && provider == nil
    }

    /// True when the URL field is non-nil and non-empty after trimming. Used
    /// by the override-card UIs to seed the "Override server URL & API token"
    /// sub-toggle from persisted state.
    var hasServerOverride: Bool {
        guard let s = baseURLString else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the model field is non-nil and non-empty after trimming.
    /// Used by the override-card UIs to seed the "Override model" sub-toggle
    /// from persisted state.
    var hasModelOverride: Bool {
        guard let m = modelName else { return false }
        return !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decodeIfPresent(String.self, forKey: .baseURLString)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        // Tolerant TWICE over: an unknown raw value (future provider in a
        // newer export) AND type garbage (hand-edited teams.json putting a
        // number here) both decode as nil = inherit global. Failing the whole
        // team decode would be far too harsh — the three-file store treats
        // any decode failure as corruption and wipes + re-bootstraps.
        provider = (try? container.decodeIfPresent(String.self, forKey: .provider))
            .flatMap { $0 }
            .flatMap(LLMProvider.init(rawValue:))
    }

    init(
        baseURLString: String? = nil,
        modelName: String? = nil,
        provider: LLMProvider? = nil
    ) {
        self.baseURLString = baseURLString
        self.modelName = modelName
        self.provider = provider
    }
}
