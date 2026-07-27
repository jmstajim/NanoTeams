import Foundation

/// Reads and removes the model downloads that occupy disk on a provider's host.
///
/// Why this is NOT two more methods on `LLMClient`: every `LLMClient` method
/// presupposes a reachable server and is built around an injected
/// `NetworkSession`. LM Studio has no delete endpoint at any layer — not REST,
/// not the `lms` CLI, not the SDKs — so its implementation here is filesystem
/// I/O that must keep working while the server is DOWN (freeing 20 GB when
/// LM Studio isn't running is the common case, not an edge case) and that needs
/// the models-folder path, which `LLMConfig` doesn't carry. Two different
/// transports for two providers is exactly what a separate protocol is for.
///
/// Dispatch shape is copied from `LLMClientRouter` so the codebase has one
/// recognizable provider-dispatch pattern. Unlike that router's lifecycle
/// methods — which take a bare `baseURLString` and therefore always go to LM
/// Studio — every method here takes an `LLMConfig` so it CAN dispatch on
/// `config.provider`.
nonisolated protocol DownloadedModelStore: Sendable {

    /// Models occupying disk on the host serving `config.baseURLString`.
    func listDownloaded(config: LLMConfig) async throws -> [DownloadedModel]

    /// What deletion means at this endpoint — including whether it's possible
    /// at all. Never throws: an unreachable server or a missing models folder
    /// is a `.unavailable(reason:)`, which the UI can render, not an error.
    func deletionCapability(config: LLMConfig) async -> DownloadedModelDeletion

    /// Remove the download identified by `modelID`.
    ///
    /// Idempotent: a model that is already gone is success, not an error —
    /// same rule `NativeLMStudioClient.unloadModel` follows for a 404.
    func delete(modelID: String, config: LLMConfig) async throws

    /// Human-readable description of where these downloads live, for the card
    /// footer. `nil` when the location isn't knowable from here (a remote host).
    func storageLocationDescription(config: LLMConfig) async -> String?
}

// MARK: - Router

/// Routes downloaded-model operations to the correct provider store.
nonisolated struct DownloadedModelStoreRouter: DownloadedModelStore {
    private let lmStudioStore: any DownloadedModelStore
    private let ollamaStore: any DownloadedModelStore

    init(
        lmStudioStore: any DownloadedModelStore = LMStudioDownloadedModelStore(),
        ollamaStore: any DownloadedModelStore = OllamaDownloadedModelStore()
    ) {
        self.lmStudioStore = lmStudioStore
        self.ollamaStore = ollamaStore
    }

    private func store(for provider: LLMProvider) -> any DownloadedModelStore {
        switch provider {
        case .lmStudio: lmStudioStore
        case .ollama: ollamaStore
        }
    }

    func listDownloaded(config: LLMConfig) async throws -> [DownloadedModel] {
        try await store(for: config.provider).listDownloaded(config: config)
    }

    func deletionCapability(config: LLMConfig) async -> DownloadedModelDeletion {
        await store(for: config.provider).deletionCapability(config: config)
    }

    func delete(modelID: String, config: LLMConfig) async throws {
        try await store(for: config.provider).delete(modelID: modelID, config: config)
    }

    func storageLocationDescription(config: LLMConfig) async -> String? {
        await store(for: config.provider).storageLocationDescription(config: config)
    }
}
