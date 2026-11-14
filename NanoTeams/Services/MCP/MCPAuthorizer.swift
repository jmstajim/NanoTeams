import Foundation

/// Puts credentials on an outgoing request, and reads what the server says when it refuses
/// them.
///
/// A protocol with two implementations rather than an `if` on the mode, because this is where
/// OAuth would attach if it is ever added — and because the one thing that must never drift
/// is where the secret comes from. Both implementations read the Keychain PER REQUEST and
/// hold nothing: a token cached on the connection actor is a token in a heap dump, and a
/// token passed into an initializer is a token in whatever built it.
nonisolated protocol MCPAuthorizer: Sendable {

    /// Returns the request with credentials attached. Returning rather than mutating in place
    /// keeps the seam free of exclusivity questions across the `await` the Keychain read may
    /// cost on a future implementation.
    func authorized(_ request: URLRequest) async throws -> URLRequest

    /// Classifies a refusal. `nil` means the status is not an authentication problem and the
    /// caller should report it as an ordinary HTTP failure.
    func challenge(status: Int, wwwAuthenticate: String?) -> MCPAuthChallenge?

    /// What this authorizer puts on a request, as the redaction every writer of this server's
    /// text applies — the error body the model reads, the status row, the frame log. The
    /// authorizer is the one place that knows what a server is sent, so it is the one that
    /// says what to scrub; like `authorized(_:)`, it reads the Keychain now and holds nothing.
    func credentialsToRedact() -> MCPRedaction.Credentials
}

/// Why a server refused the credentials, in the words the server status row shows. Already
/// redacted — a `WWW-Authenticate` header can carry an `error_description` that quotes the
/// token it rejected.
nonisolated enum MCPAuthChallenge: Hashable, Sendable {
    /// 401 and this client sent nothing. The repair is to add a token.
    case missingCredential(reason: String)
    /// 401 and this client did send something. The repair is to replace it.
    case rejectedCredential(reason: String)
    /// 403 — the credential was understood and is not allowed to do this. Re-entering it
    /// changes nothing, which is why it is a separate case.
    case forbidden(reason: String)

    var reason: String {
        switch self {
        case .missingCredential(let reason), .rejectedCredential(let reason), .forbidden(let reason):
            return reason
        }
    }
}

// MARK: - No authentication

/// For a server whose authority is the desktop session the user is already logged into
/// (a desktop app serving on loopback). Sends nothing, and still classifies a refusal — a loopback
/// server that starts demanding a token is something the user needs to be told about rather
/// than a connection that silently stops working.
nonisolated struct NoAuthorizer: MCPAuthorizer {

    init() {}

    func authorized(_ request: URLRequest) async throws -> URLRequest { request }

    func credentialsToRedact() -> MCPRedaction.Credentials { .none }

    func challenge(status: Int, wwwAuthenticate: String?) -> MCPAuthChallenge? {
        switch status {
        case 401:
            return .missingCredential(reason: Self.detail(
                "This server asks for a credential and none is configured.", wwwAuthenticate))
        case 403:
            return .forbidden(reason: Self.detail("This server refused the request.", wwwAuthenticate))
        default:
            return nil
        }
    }

    /// The server's `WWW-Authenticate` text after `lead`: on one line with nothing hidden (it
    /// reaches the model through the error message), scrubbed of `credentials` BEFORE it is
    /// cut — a challenge can quote the very token it refused.
    static func detail(
        _ lead: String, _ challenge: String?, credentials: MCPRedaction.Credentials = .none
    ) -> String {
        guard let challenge, !challenge.isEmpty else { return lead }
        return "\(lead) The server replied: \(credentials.excerpt(MCPTextSanitizer.singleLine(challenge), limit: 200))"
    }
}

// MARK: - Static bearer

/// `Authorization: Bearer <secret>`, plus any extra headers the user declared secret.
///
/// The secret is resolved through a closure over `SecureTokenStorage` on every request. That
/// is not indirection for its own sake: it means rotating the token in Settings takes effect
/// on the next request with no reconnect, and it means this actor-reachable value type holds
/// no credential to leak.
///
/// **One server and one origin, one token.** The keys are derived from the server's UUID AND
/// the origin of the address it runs at (`MCPServerConfig.originAccountPrefix`), and `make`
/// builds them from the config the connection itself was built from. So one server's token is
/// never read for another — the token-passthrough failure, where a client forwards whatever
/// credential it holds to whatever server it is talking to — and a token is sent only to the
/// host it was entered for, BY CONSTRUCTION: a server keeps its UUID when its address is
/// edited, but a value typed for another scheme, host or port lives under an account whose name
/// says so, and this authorizer never reads it. It rests on no order of a save's steps, no
/// clean-up after a refused one, and no reload waiting for a re-point: until the third pass of
/// group D's review (2026-09-24) every address read `<uuid>/bearer`, and the token stayed on its
/// host only while all three held.
nonisolated struct StaticBearerAuthorizer: MCPAuthorizer {

    /// Keychain account for the bearer value, or `nil` for a server that only uses secret
    /// headers.
    private let bearerKey: String?
    /// Header name → Keychain account.
    private let secretHeaderKeys: [String: String]
    private let storage: any SecureTokenStorage

    init(bearerKey: String?, secretHeaderKeys: [String: String] = [:], storage: any SecureTokenStorage) {
        self.bearerKey = bearerKey
        self.secretHeaderKeys = secretHeaderKeys
        self.storage = storage
    }

    /// Builds the authorizer a config asks for. Secret headers are sent under BOTH modes — "No
    /// authentication" means no bearer, not no headers: an API-key header is how many servers
    /// authenticate — and the bearer only under `.staticBearer`, even when a token saved under
    /// an earlier mode is still in the Keychain. A server with neither gets `NoAuthorizer`, and
    /// the Keychain is never read for it. A header whose value is blank or absent is not sent at
    /// all (`authorized(_:)`): an empty value reads to a server as a malformed credential rather
    /// than as none. Pinned by
    /// `MCPAuthorizerTests.testSecretHeadersAreSentUnderEitherModeAndTheBearerOnlyUnderBearer`.
    static func make(config: MCPServerConfig, storage: any SecureTokenStorage) -> any MCPAuthorizer {
        let http = config.transport.http
        let headerKeys = Dictionary(uniqueKeysWithValues: http.secretHeaderNames.map {
            ($0, config.secretKey(forHeader: $0))
        })
        guard http.authorization == .staticBearer || !headerKeys.isEmpty else { return NoAuthorizer() }
        return StaticBearerAuthorizer(
            bearerKey: http.authorization == .staticBearer ? config.bearerSecretKey : nil,
            secretHeaderKeys: headerKeys,
            storage: storage)
    }

    func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        if let bearerKey, let token = nonEmptySecret(forKey: bearerKey) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (header, key) in secretHeaderKeys.sorted(by: { $0.key < $1.key }) {
            if let value = nonEmptySecret(forKey: key) {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }
        return request
    }

    /// A Keychain that is locked or refuses the ACL reads as "no token" here rather than as a
    /// throw: the request then comes back 401, which is the state the user can act on, and a
    /// thrown Keychain error at this depth would be reported as a transport failure and send
    /// them looking at the network.
    private func nonEmptySecret(forKey key: String) -> String? {
        guard let value = storage.token(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Every secret header's name, and every value `authorized(_:)` would send now — trimmed
    /// the same way, since the trimmed value is what a server can echo.
    func credentialsToRedact() -> MCPRedaction.Credentials {
        var values: [String] = []
        if let bearerKey, let token = nonEmptySecret(forKey: bearerKey) { values.append(token) }
        for key in secretHeaderKeys.values.sorted() {
            if let value = nonEmptySecret(forKey: key) { values.append(value) }
        }
        return MCPRedaction.Credentials(headerNames: secretHeaderKeys.keys.sorted(), values: values)
    }

    func challenge(status: Int, wwwAuthenticate: String?) -> MCPAuthChallenge? {
        guard status == 401 || status == 403 else { return nil }
        // Read only for a refusal: the Keychain is not touched for a status that is not one.
        let credentials = credentialsToRedact()
        guard status == 401 else {
            return .forbidden(reason: NoAuthorizer.detail(
                "The saved token is not allowed to do this. A read-only token cannot reach every tool.",
                wwwAuthenticate, credentials: credentials))
        }
        let hasCredential = bearerKey.map { nonEmptySecret(forKey: $0) != nil } ?? false
        return hasCredential
            ? .rejectedCredential(reason: NoAuthorizer.detail(
                "The server rejected the saved token.", wwwAuthenticate, credentials: credentials))
            : .missingCredential(reason: NoAuthorizer.detail(
                "This server asks for a token and none is saved.", wwwAuthenticate, credentials: credentials))
    }
}

nonisolated extension MCPRedaction.Credentials {
    /// What `config`'s server is sent, read now — spelled through the factory that decides
    /// what a server is sent, so the frame log and the transport can never disagree about it.
    static func sent(to config: MCPServerConfig, storage: any SecureTokenStorage) -> Self {
        StaticBearerAuthorizer.make(config: config, storage: storage).credentialsToRedact()
    }
}
