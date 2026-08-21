import Foundation

/// Downloaded-model management for Ollama.
///
/// Ollama treats model storage as server state and exposes a full CRUD surface
/// for it, so every operation here is a plain HTTP call against
/// `config.baseURLString` — including deletion, which therefore works against a
/// REMOTE Ollama host just as well as a local one. That is the whole reason the
/// two provider stores look nothing alike (see `LMStudioDownloadedModelStore`).
nonisolated struct OllamaDownloadedModelStore: DownloadedModelStore {

    private let session: any NetworkSession
    private let tokenResolver: any LLMTokenResolver

    init(
        session: any NetworkSession = URLSession.shared,
        tokenResolver: any LLMTokenResolver = DefaultLLMTokenResolver()
    ) {
        self.session = session
        self.tokenResolver = tokenResolver
    }

    // MARK: - Listing

    func listDownloaded(config: LLMConfig) async throws -> [DownloadedModel] {
        let entries = try await fetchTags(config: config)
        // Best-effort residency. A FAILED probe must not be rendered as "not
        // loaded" — same rule `OllamaClient.modelLoadDetails` follows when
        // `/api/ps` doesn't answer: omit the claim rather than invert it.
        let residentNames = await fetchResidentNames(config: config) ?? []

        return entries.map { entry in
            DownloadedModel(
                id: entry.name,
                displayName: entry.name,
                sizeBytes: entry.size,
                detail: Self.detailLine(for: entry),
                isLoaded: residentNames.contains(entry.name),
                referenceHints: [entry.name]
            )
        }
    }

    /// Second line: quantization and parameter size when the server reports
    /// them. `nil` when it reports neither — an empty row reads better than a
    /// placeholder.
    static func detailLine(for entry: OllamaClient.TagsResponse.ModelEntry) -> String? {
        var parts: [String] = []
        if let size = entry.details?.parameterSize, !size.isEmpty { parts.append(size) }
        if let quant = entry.details?.quantizationLevel, !quant.isEmpty { parts.append(quant) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func fetchTags(config: LLMConfig) async throws -> [OllamaClient.TagsResponse.ModelEntry] {
        let data = try await get(path: "api/tags", timeout: 5, config: config)
        return try JSONCoderFactory.makeWireDecoder()
            .decode(OllamaClient.TagsResponse.self, from: data)
            .models
    }

    /// Names currently resident per `/api/ps`. `nil` = the probe failed, which
    /// callers must treat as "unknown", never as "nothing is loaded".
    private func fetchResidentNames(config: LLMConfig) async -> Set<String>? {
        guard let data = try? await get(path: "api/ps", timeout: 5, config: config),
              let decoded = try? JSONCoderFactory.makeWireDecoder()
              .decode(OllamaClient.PSResponse.self, from: data)
        else { return nil }

        var names: Set<String> = []
        for entry in decoded.models {
            if let name = entry.name { names.insert(name) }
            if let model = entry.model { names.insert(model) }
        }
        return names
    }

    // MARK: - Deletion

    /// Always available: `DELETE /api/delete` runs on the server that owns the
    /// files, so it is as valid remotely as locally.
    func deletionCapability(config _: LLMConfig) async -> DownloadedModelDeletion {
        .permanent
    }

    func delete(modelID: String, config: LLMConfig) async throws {
        guard let baseURL = URL(string: config.baseURLString) else {
            throw LLMClientError.invalidBaseURL(config.baseURLString)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)
        // `model` is the current key. Ollama's `api/types.go` still accepts the
        // legacy `name`, but marks it deprecated — send only the supported one.
        // (A DELETE carrying a body is unusual, but `URLRequest` sends it fine.)
        request.httpBody = try JSONCoderFactory.makeWireEncoder().encode(DeleteRequest(model: modelID))

        let (data, response) = try await session.sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.missingResponse
        }
        if (200..<300).contains(http.statusCode) { return }
        // Already gone is the outcome the caller asked for. Mirrors
        // `NativeLMStudioClient.unloadModel`'s idempotent-404 rule so a
        // double-tap or a concurrent deletion elsewhere isn't a spurious error.
        if http.statusCode == 404 { return }
        throw LLMClientError.badHTTPStatus(http.statusCode, String(data: data, encoding: .utf8))
    }

    /// The files live on the Ollama host, which may not be this machine, so
    /// there is no path worth naming here.
    func storageLocationDescription(config _: LLMConfig) async -> String? { nil }

    // MARK: - Transport

    private func get(path: String, timeout: TimeInterval, config: LLMConfig) async throws -> Data {
        guard let baseURL = URL(string: config.baseURLString) else {
            throw LLMClientError.invalidBaseURL(config.baseURLString)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)

        let (data, response) = try await session.sessionData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.missingResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClientError.badHTTPStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    private struct DeleteRequest: Encodable {
        let model: String
    }
}
