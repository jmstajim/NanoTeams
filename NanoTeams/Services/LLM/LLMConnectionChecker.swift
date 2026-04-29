import Foundation

/// Outcome of probing an LM Studio endpoint. Distinguishes the various
/// connection-level failure modes so the UI can give an actionable hint
/// ("hostname not found" vs. "connection refused" vs. "timed out") instead of
/// the historical generic "could not reach server".
enum LLMProbeOutcome {
    case http(Int)
    case dnsLookupFailed
    case connectionRefused
    case timedOut
    case offline
    case otherTransport(String)
    case invalidURL

    var statusCode: Int? {
        if case .http(let code) = self { return code }
        return nil
    }
}

/// Checks LM Studio server reachability. Extracted from views to eliminate duplicated HTTP logic.
enum LLMConnectionChecker {

    struct ConnectionResult {
        let isReachable: Bool
        let message: String
        /// Raw HTTP status when the request reached the server. `nil` for
        /// connection-level failures (DNS, connect refused, timeout). Lets the
        /// settings UI show "Authentication required" specifically for 401
        /// instead of generic "Server returned error".
        let statusCode: Int?
    }

    /// Probes the server, returning a typed outcome the caller can map to a
    /// user-facing message. Replaces the older `Int?` API which collapsed
    /// every transport error into "nil" and gave users no way to tell DNS
    /// failure from a closed port.
    ///
    /// `bearerToken` lets the UI Test-Connection button send the value the user
    /// just typed into the SecureField (not yet committed to Keychain). When
    /// `nil`, the resolver consults Keychain.
    static func probeOutcome(
        baseURL: String,
        bearerToken: String? = nil,
        timeout: TimeInterval = 5.0,
        session: any NetworkSession = URLSession.shared,
        resolver: any LLMTokenResolver = DefaultLLMTokenResolver()
    ) async -> LLMProbeOutcome {
        guard let url = URL(string: baseURL)?
            .appendingPathComponent("api/v1/models") else { return .invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let bearerToken {
            request.applyLMStudioBearer(literal: bearerToken)
        } else {
            request.applyLMStudioBearer(baseURL: baseURL, resolver: resolver)
        }
        do {
            let (_, response) = try await session.sessionData(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .otherTransport("non-HTTP response")
            }
            return .http(http.statusCode)
        } catch let urlErr as URLError {
            switch urlErr.code {
            case .cannotFindHost, .dnsLookupFailed:
                return .dnsLookupFailed
            case .cannotConnectToHost:
                return .connectionRefused
            case .timedOut:
                return .timedOut
            case .notConnectedToInternet:
                return .offline
            default:
                return .otherTransport(urlErr.localizedDescription)
            }
        } catch {
            return .otherTransport(error.localizedDescription)
        }
    }

    /// Back-compat wrapper: returns the HTTP status code if the server
    /// responded, or `nil` for any non-HTTP outcome.
    static func probe(
        baseURL: String,
        bearerToken: String? = nil,
        timeout: TimeInterval = 5.0,
        session: any NetworkSession = URLSession.shared,
        resolver: any LLMTokenResolver = DefaultLLMTokenResolver()
    ) async -> Int? {
        await probeOutcome(
            baseURL: baseURL, bearerToken: bearerToken,
            timeout: timeout, session: session, resolver: resolver
        ).statusCode
    }

    /// Returns `true` if the server at `baseURL` responds with a 2xx status code.
    static func check(
        baseURL: String,
        bearerToken: String? = nil,
        timeout: TimeInterval = 5.0,
        session: any NetworkSession = URLSession.shared,
        resolver: any LLMTokenResolver = DefaultLLMTokenResolver()
    ) async -> Bool {
        guard let status = await probe(
            baseURL: baseURL, bearerToken: bearerToken,
            timeout: timeout, session: session, resolver: resolver
        ) else { return false }
        return (200...299).contains(status)
    }

    /// Checks connection and returns a result with a user-facing message.
    static func checkWithMessage(
        baseURL: String,
        bearerToken: String? = nil,
        session: any NetworkSession = URLSession.shared,
        resolver: any LLMTokenResolver = DefaultLLMTokenResolver()
    ) async -> ConnectionResult {
        let outcome = await probeOutcome(
            baseURL: baseURL, bearerToken: bearerToken,
            session: session, resolver: resolver
        )
        switch outcome {
        case .http(let status) where (200...299).contains(status):
            return ConnectionResult(
                isReachable: true,
                message: "Successfully connected to LM Studio server.",
                statusCode: status
            )
        case .http(let status):
            return ConnectionResult(
                isReachable: false,
                message: LLMAuthErrorClassifier.message(forStatus: status, body: nil),
                statusCode: status
            )
        case .dnsLookupFailed:
            return ConnectionResult(
                isReachable: false,
                message: "Hostname not found. Check the URL — `\(baseURL)` does not resolve.",
                statusCode: nil
            )
        case .connectionRefused:
            return ConnectionResult(
                isReachable: false,
                message: "Connection refused at \(baseURL). LM Studio is not listening on that port.",
                statusCode: nil
            )
        case .timedOut:
            return ConnectionResult(
                isReachable: false,
                message: "Server did not respond within 5s. Check that LM Studio is running and reachable.",
                statusCode: nil
            )
        case .offline:
            return ConnectionResult(
                isReachable: false,
                message: "Device is offline. Connect to a network and try again.",
                statusCode: nil
            )
        case .otherTransport(let detail):
            return ConnectionResult(
                isReachable: false,
                message: "Could not reach LM Studio at \(baseURL): \(detail)",
                statusCode: nil
            )
        case .invalidURL:
            return ConnectionResult(
                isReachable: false,
                message: "Server address is not a valid URL: `\(baseURL)`.",
                statusCode: nil
            )
        }
    }

    /// Fetches available models from the LLM server using the given configuration.
    /// `bearerToken` lets the settings card pass a freshly-typed token before
    /// it's committed to Keychain.
    static func fetchAvailableModels(
        config: StoreConfiguration,
        bearerToken: String? = nil,
        client: (any LLMClient)? = nil
    ) async throws -> [String] {
        let fetchConfig = LLMConfig(
            provider: config.llmProvider,
            baseURLString: config.llmBaseURLString,
            modelName: config.llmModelName,
            maxTokens: config.llmMaxTokens,
            temperature: config.llmTemperature
        )
        let effectiveClient = client ?? makeRouter(bearerTokenOverride: bearerToken,
                                                    forBaseURL: config.llmBaseURLString)
        return try await effectiveClient.fetchModels(config: fetchConfig, visionOnly: false)
    }

    /// Builds a router that prefers an explicit bearer token (from a SecureField)
    /// over the Keychain lookup for one specific URL. All other URLs still go
    /// through the Keychain. Empty / whitespace tokens are dropped by the
    /// `OverridingLLMTokenResolver` constructor itself, so callers can blindly
    /// pass the SecureField value without their own guard.
    private static func makeRouter(
        bearerTokenOverride token: String?,
        forBaseURL baseURL: String
    ) -> LLMClientRouter {
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return LLMClientRouter()
        }
        return LLMClientRouter(tokenResolver: OverridingLLMTokenResolver(
            overrides: [baseURL: token]
        ))
    }
}
