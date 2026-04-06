import Foundation

/// Checks LM Studio server reachability. Extracted from views to eliminate duplicated HTTP logic.
enum LLMConnectionChecker {

    struct ConnectionResult {
        let isReachable: Bool
        let message: String
    }

    /// Returns `true` if the server at `baseURL` responds with a 2xx status code.
    static func check(
        baseURL: String,
        timeout: TimeInterval = 5.0,
        session: any NetworkSession = URLSession.shared
    ) async -> Bool {
        guard let url = URL(string: baseURL)?
            .appendingPathComponent("api/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.sessionData(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Checks connection and returns a result with a user-facing message.
    static func checkWithMessage(baseURL: String) async -> ConnectionResult {
        let reachable = await check(baseURL: baseURL)
        if reachable {
            return ConnectionResult(isReachable: true, message: "Successfully connected to LM Studio server.")
        } else {
            return ConnectionResult(isReachable: false, message: "Server returned error status or invalid URL.")
        }
    }

    /// Fetches available models from the LLM server using the given configuration.
    static func fetchAvailableModels(
        config: StoreConfiguration,
        client: any LLMClient = LLMClientRouter()
    ) async throws -> [String] {
        let fetchConfig = LLMConfig(
            provider: config.llmProvider,
            baseURLString: config.llmBaseURLString,
            modelName: config.llmModelName,
            maxTokens: config.llmMaxTokens,
            temperature: config.llmTemperature
        )
        return try await client.fetchModels(config: fetchConfig, visionOnly: false)
    }
}
