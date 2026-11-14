import XCTest

@testable import NanoTeams

/// Where the credential comes from, where it goes, and — the part that matters — where it
/// does not.
final class MCPAuthorizerTests: XCTestCase {

    private let serverID = UUID()
    private let secret = "t.SECRET-1234"
    private var storage: InMemorySecureTokenStorage!

    override func setUp() {
        super.setUp()
        storage = InMemorySecureTokenStorage()
    }

    override func tearDown() {
        storage = nil
        super.tearDown()
    }

    private func config(
        authorization: MCPAuthorizationMode = .staticBearer, secretHeaderNames: [String] = []
    ) throws -> MCPServerConfig {
        MCPServerConfig(
            id: serverID,
            slug: try XCTUnwrap(MCPServerSlug("trade_room")),
            displayName: "Trade-Room",
            transport: .http(MCPHTTPConfig(
                urlString: "https://x/mcp",
                secretHeaderNames: secretHeaderNames,
                authorization: authorization)))
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://x/mcp")!)
    }

    // MARK: - No authentication

    func testNoAuthorizerSendsNothing() async throws {
        let authorized = try await NoAuthorizer().authorized(request())
        XCTAssertNil(authorized.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorized.allHTTPHeaderFields?.isEmpty ?? true)
    }

    /// A loopback server that starts demanding a token is something the user needs to be told
    /// about, not a connection that silently stops working.
    func testNoAuthorizerStillClassifiesARefusal() {
        XCTAssertEqual(NoAuthorizer().challenge(status: 401, wwwAuthenticate: nil),
                       .missingCredential(reason: "This server asks for a credential and none is configured."))
        guard case .forbidden = NoAuthorizer().challenge(status: 403, wwwAuthenticate: nil) else {
            return XCTFail("403 is a distinct case")
        }
        XCTAssertNil(NoAuthorizer().challenge(status: 500, wwwAuthenticate: nil))
        XCTAssertNil(NoAuthorizer().challenge(status: 200, wwwAuthenticate: nil))
    }

    /// A `WWW-Authenticate` header can carry an `error_description` that quotes the token it
    /// rejected.
    func testTheChallengeTextIsRedactedBeforeItIsShown() {
        let challenge = NoAuthorizer().challenge(
            status: 401, wwwAuthenticate: "Bearer realm=\"mcp\", error_description=\"Bearer \(secret) expired\"")
        XCTAssertFalse(challenge?.reason.contains(secret) ?? true, challenge?.reason ?? "")
        XCTAssertTrue(challenge?.reason.contains("realm") ?? false)
    }

    // MARK: - Static bearer

    func testTheBearerIsReadFromTheKeychainPerRequest() async throws {
        let config = try config()
        let authorizer = StaticBearerAuthorizer.make(config: config, storage: storage)
        try storage.setToken(secret, forKey: config.bearerSecretKey)
        var authorized = try await authorizer.authorized(request())
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")

        // Rotating the token takes effect on the next request, with no reconnect.
        try storage.setToken("t.ROTATED", forKey: config.bearerSecretKey)
        authorized = try await authorizer.authorized(request())
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer t.ROTATED")
    }

    /// Token passthrough: a client that forwards whatever credential it holds to whatever
    /// server it is talking to. The keys are derived from the server's own UUID, so there is
    /// nothing to forward.
    func testAnotherServersTokenIsNeverReachable() async throws {
        let mine = try config()
        let theirs = MCPServerConfig(
            id: UUID(), slug: try XCTUnwrap(MCPServerSlug("other")), displayName: "Other",
            transport: .http(MCPHTTPConfig(urlString: "https://y/mcp", authorization: .staticBearer)))
        try storage.setToken(secret, forKey: theirs.bearerSecretKey)

        let authorizer = StaticBearerAuthorizer.make(config: mine, storage: storage)
        let authorized = try await authorizer.authorized(request())
        XCTAssertNil(authorized.value(forHTTPHeaderField: "Authorization"))
    }

    func testSecretHeadersAreResolvedTooAndInAStableOrder() async throws {
        let config = try config(authorization: .none, secretHeaderNames: ["X-Api-Key", "X-Tenant"])
        try storage.setToken("key-value", forKey: config.secretKey(forHeader: "X-Api-Key"))
        try storage.setToken("tenant-value", forKey: config.secretKey(forHeader: "X-Tenant"))
        let authorized = try await StaticBearerAuthorizer.make(config: config, storage: storage)
            .authorized(request())
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "X-Api-Key"), "key-value")
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "X-Tenant"), "tenant-value")
        XCTAssertNil(authorized.value(forHTTPHeaderField: "Authorization"))
    }

    /// An empty field is not authentication: sending an empty `Authorization` reads to a
    /// server as a malformed credential rather than as none.
    func testAnEmptyOrAbsentSecretSendsNoHeaderAtAll() async throws {
        let config = try config()
        let authorizer = StaticBearerAuthorizer.make(config: config, storage: storage)
        let withNothingSaved = try await authorizer.authorized(request())
        XCTAssertNil(withNothingSaved.value(forHTTPHeaderField: "Authorization"))
        try storage.setToken("   ", forKey: config.bearerSecretKey)
        let withBlankSaved = try await authorizer.authorized(request())
        XCTAssertNil(withBlankSaved.value(forHTTPHeaderField: "Authorization"))
    }

    /// A Keychain that is locked reads as "no token" here rather than as a throw: the request
    /// then comes back 401, which is the state the user can act on. A thrown Keychain error at
    /// this depth would be reported as a transport failure and send them looking at the network.
    func testALockedKeychainDegradesToNoTokenRatherThanFailingTheRequest() async throws {
        let config = try config()
        try storage.setToken(secret, forKey: config.bearerSecretKey)
        storage.readError = .unhandled(-25308)
        let authorized = try await StaticBearerAuthorizer.make(config: config, storage: storage)
            .authorized(request())
        XCTAssertNil(authorized.value(forHTTPHeaderField: "Authorization"))
    }

    /// The repair differs: add a token, replace the token, or accept that the token is not
    /// allowed to do this.
    func testARefusalIsClassifiedByWhetherACredentialWasActuallySent() async throws {
        let config = try config()
        let authorizer = StaticBearerAuthorizer.make(config: config, storage: storage)
        guard case .missingCredential = authorizer.challenge(status: 401, wwwAuthenticate: nil) else {
            return XCTFail("with no token saved, 401 means one is missing")
        }
        try storage.setToken(secret, forKey: config.bearerSecretKey)
        guard case .rejectedCredential = authorizer.challenge(status: 401, wwwAuthenticate: nil) else {
            return XCTFail("with a token saved, 401 means it was rejected")
        }
        guard case .forbidden(let reason) = authorizer.challenge(status: 403, wwwAuthenticate: nil) else {
            return XCTFail("403 is not an authentication failure")
        }
        XCTAssertTrue(reason.contains("read-only"), "a read-only token is the likeliest cause here")
        XCTAssertNil(authorizer.challenge(status: 404, wwwAuthenticate: nil))
    }

    /// A server declaring neither a bearer nor a secret header gets the no-op authorizer, so
    /// nothing reaches the Keychain at all.
    func testAServerWithoutCredentialsGetsTheNoOpAuthorizer() throws {
        XCTAssertTrue(StaticBearerAuthorizer.make(config: try config(authorization: .none), storage: storage)
            is NoAuthorizer)
        XCTAssertTrue(StaticBearerAuthorizer.make(config: try config(), storage: storage)
            is StaticBearerAuthorizer)
        XCTAssertTrue(StaticBearerAuthorizer.make(
            config: try config(authorization: .none, secretHeaderNames: ["X-Api-Key"]), storage: storage)
            is StaticBearerAuthorizer)
    }

    /// The rule `make` follows, pinned beside its doc (F57): secret headers are sent under
    /// BOTH modes — "No authentication" means no bearer, not no headers — and the bearer only
    /// under `.staticBearer`, even when a token saved under an earlier mode is still stored.
    func testSecretHeadersAreSentUnderEitherModeAndTheBearerOnlyUnderBearer() async throws {
        for authorization in MCPAuthorizationMode.allCases {
            let config = try config(authorization: authorization, secretHeaderNames: ["X-Api-Key"])
            try storage.setToken("key-value", forKey: config.secretKey(forHeader: "X-Api-Key"))
            try storage.setToken("t.SECRET", forKey: config.bearerSecretKey)

            let authorized = try await StaticBearerAuthorizer.make(config: config, storage: storage)
                .authorized(request())

            XCTAssertEqual(authorized.value(forHTTPHeaderField: "X-Api-Key"), "key-value", "\(authorization)")
            XCTAssertEqual(
                authorized.value(forHTTPHeaderField: "Authorization"),
                authorization == .staticBearer ? "Bearer t.SECRET" : nil, "\(authorization)")
        }
    }

    // MARK: - What the redaction is told (F11)

    /// The authorizer is the one place that knows what a server is sent, so it is the one
    /// that says what to scrub: every secret header's NAME, and every value it would send —
    /// read from the Keychain now, trimmed exactly as it is sent.
    func testTheBearerAuthorizerRedactsWhatItSends() throws {
        let config = try config(secretHeaderNames: ["X-Tenant", "X-Api-Key"])
        try storage.setToken("  \(secret)\n", forKey: config.bearerSecretKey)
        try storage.setToken("key-value", forKey: config.secretKey(forHeader: "X-Api-Key"))
        let credentials = StaticBearerAuthorizer.make(config: config, storage: storage).credentialsToRedact()
        XCTAssertEqual(credentials.headerNames, ["X-Api-Key", "X-Tenant"])
        XCTAssertEqual(Set(credentials.values), [secret, "key-value"], "an unsaved header has no value to scrub")

        // Read per call, like the request itself: a rotated token is what gets scrubbed next.
        try storage.setToken("t.ROTATED-9", forKey: config.bearerSecretKey)
        XCTAssertTrue(StaticBearerAuthorizer.make(config: config, storage: storage)
            .credentialsToRedact().values.contains("t.ROTATED-9"))
    }

    /// The same value set the manager's frame log reads — spelled once, through the factory
    /// that decides what a server is sent.
    func testTheLogReadsTheSameCredentialsTheTransportSends() throws {
        let config = try config(secretHeaderNames: ["X-Api-Key"])
        try storage.setToken(secret, forKey: config.bearerSecretKey)
        try storage.setToken("key-value", forKey: config.secretKey(forHeader: "X-Api-Key"))
        XCTAssertEqual(
            MCPRedaction.Credentials.sent(to: config, storage: storage),
            StaticBearerAuthorizer.make(config: config, storage: storage).credentialsToRedact())
        let plain = try self.config(authorization: .none)
        XCTAssertEqual(MCPRedaction.Credentials.sent(to: plain, storage: storage), .none)
    }

    /// What the frame log pays per line: nothing at all for a server that is sent no secret —
    /// the factory hands it `NoAuthorizer`, which never touches the Keychain — and one read per
    /// secret for one that is (the bearer, then each secret header), never more.
    func testTheFrameLogReadsOneKeychainItemPerSecretAndNoneForAServerWithout() throws {
        let counting = MCPCountingTokenStorage()
        _ = MCPRedaction.Credentials.sent(to: try config(authorization: .none), storage: counting)
        XCTAssertEqual(counting.reads, 0)

        let bearerOnly = try config()
        try counting.setToken(secret, forKey: bearerOnly.bearerSecretKey)
        _ = MCPRedaction.Credentials.sent(to: bearerOnly, storage: counting)
        XCTAssertEqual(counting.reads, 1)

        _ = MCPRedaction.Credentials.sent(to: try config(secretHeaderNames: ["X-Api-Key", "X-Tenant"]), storage: counting)
        XCTAssertEqual(counting.reads, 1 + 3)
    }

    func testNoAuthorizerRedactsNothingOfItsOwn() {
        XCTAssertEqual(NoAuthorizer().credentialsToRedact(), .none)
    }

    /// A locked Keychain gives the redaction no values rather than failing — the names still
    /// hold, and the request that follows carried no value to echo anyway.
    func testALockedKeychainLeavesTheNamesToRedactBy() throws {
        let config = try config(secretHeaderNames: ["X-Api-Key"])
        try storage.setToken(secret, forKey: config.bearerSecretKey)
        storage.readError = .unhandled(-25308)
        let credentials = StaticBearerAuthorizer.make(config: config, storage: storage).credentialsToRedact()
        XCTAssertEqual(credentials.values, [])
        XCTAssertEqual(credentials.headerNames, ["X-Api-Key"])
    }

    /// The challenge a 401 carries is scrubbed of the saved token by VALUE, before it is cut —
    /// no pattern has to recognise `key <token> revoked` as a credential.
    func testTheChallengeReasonIsScrubbedOfTheSavedTokenAndFlattened() throws {
        let config = try config()
        try storage.setToken("wk_live_8f3a9c2d", forKey: config.bearerSecretKey)
        let authorizer = StaticBearerAuthorizer.make(config: config, storage: storage)
        let challenge = authorizer.challenge(
            status: 401, wwwAuthenticate: "Bearer error_description=\"key wk_live_8f3a9c2d\u{202E} revoked\"")
        XCTAssertFalse(challenge?.reason.contains("wk_live_8f3a9c2d") ?? true, challenge?.reason ?? "")
        XCTAssertFalse(MCPTextSanitizer.containsStrippedCharacters(challenge?.reason ?? ""), challenge?.reason ?? "")
        let forbidden = authorizer.challenge(status: 403, wwwAuthenticate: "denied for wk_live_8f3a9c2d")
        XCTAssertFalse(forbidden?.reason.contains("wk_live_8f3a9c2d") ?? true, forbidden?.reason ?? "")
    }
}

/// A token store that counts its reads — each one is a Keychain round trip in production.
private nonisolated final class MCPCountingTokenStorage: SecureTokenStorage, @unchecked Sendable {
    private let inner = InMemorySecureTokenStorage()
    private let lock = NSLock()
    private var count = 0

    var reads: Int { lock.withLock { count } }

    func setToken(_ token: String?, forKey key: String) throws { try inner.setToken(token, forKey: key) }

    func loadToken(forKey key: String) throws -> String? {
        lock.withLock { count += 1 }
        return try inner.loadToken(forKey: key)
    }

    func accountNames(withPrefix prefix: String) throws -> [String] {
        try inner.accountNames(withPrefix: prefix)
    }
}
