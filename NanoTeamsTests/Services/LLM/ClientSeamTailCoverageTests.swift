import XCTest

@testable import NanoTeams

/// Wave 8 — the reachable remainder of the LLM client seams.
///
/// Each target here was located by dumping `xccov`'s zero-count lines and then CHECKING that the
/// branch can actually be entered, rather than assuming it. That check is the point: two of the
/// wave's candidates were dropped because probing showed the guard cannot fire at all (see
/// `WorkFolderContextBuilderDeadGuardTests`), and a test that quietly misses its branch is worse
/// than no test — it reads as coverage.
final class ClientSeamTailCoverageTests: XCTestCase {

    // MARK: - LLMClientRouter's token-injecting init

    /// Records every base URL a resolver was asked about, so a test can prove WHICH provider
    /// clients were built with it.
    private final class RecordingTokenResolver: LLMTokenResolver, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        let token: String?

        init(token: String? = "tok-injected") { self.token = token }

        nonisolated func token(forBaseURL urlString: String) -> String? {
            lock.withLock { asked.append(urlString) }
            return token
        }

        var askedURLs: [String] { lock.withLock { asked } }
    }

    /// `LLMClientRouter.init(tokenResolver:)` builds BOTH provider clients with the injected
    /// resolver. Its only production caller is `ExploratorySearchEmbeddingsCard`, which lives in
    /// `Views/` and therefore never runs under test — so until now nothing checked that the
    /// Ollama half was wired at all.
    ///
    /// That is not a hypothetical omission in this codebase: the Ollama client was retrofitted
    /// into a router that had only ever spoken to LM Studio, and CLAUDE.md's 2026-07-26 entry
    /// records a case where exactly one provider got a fix. A convenience init that silently
    /// forgot the second client would send the user's typed-but-unsaved token on the LM Studio
    /// "Test Connection" and omit it on the Ollama one, which presents as an unexplained 401.
    ///
    /// Driven through `fetchModels` against a closed port: the resolver is consulted while the
    /// request is being built, so the transport failure afterwards is irrelevant to what is
    /// being asserted.
    ///
    /// RED: drop `ollamaClient` from `init(tokenResolver:)` (leaving the default `OllamaClient()`)
    /// → the Ollama assertion fails because the default resolver is consulted instead.
    func testRouterTokenResolverInit_reachesBothProviderClients() async {
        let resolver = RecordingTokenResolver()
        let router = LLMClientRouter(tokenResolver: resolver)

        for provider in [LLMProvider.lmStudio, LLMProvider.ollama] {
            let config = LLMConfig(
                provider: provider,
                baseURLString: "http://127.0.0.1:1/\(provider.rawValue)",
                modelName: "m")
            _ = try? await router.fetchModels(config: config, visionOnly: false)
        }

        let asked = resolver.askedURLs
        XCTAssertTrue(asked.contains { $0.contains(LLMProvider.lmStudio.rawValue) },
                      "the LM Studio client was not built with the injected resolver; asked: \(asked)")
        XCTAssertTrue(asked.contains { $0.contains(LLMProvider.ollama.rawValue) },
                      """
                      the Ollama client was not built with the injected resolver — the settings \
                      UI's uncommitted token would reach LM Studio and not Ollama. asked: \(asked)
                      """)
    }

    // MARK: - LMStudioEmbeddingClient's endpoint construction

    /// `LMStudioEmbeddingClient.makeEndpointURL` guards `URL(string: config.baseURLString)` and
    /// throws `.transportError("Invalid baseURL: …")`. That arm is **unreachable, and the type
    /// system is why** — which is worth pinning rather than covering.
    ///
    /// This test started life trying to ENTER that arm and trapped instead: `EmbeddingConfig`'s
    /// memberwise init opens with `precondition(URL(string: baseURLString) != nil)`, so a config
    /// whose base does not parse cannot be constructed at all. The failable
    /// `init?(validating:)` — the one every untrusted path uses (settings fields, persisted
    /// overrides) — returns nil for the same input. Both doors are shut, so by the time
    /// `makeEndpointURL` sees a config, the string has already been proven to parse.
    ///
    /// The guard stays: it costs one branch and it is the correct shape if a third init is ever
    /// added without the precondition. What it must not do is masquerade as the handler for user
    /// error, because the handler for user error is `init?(validating:)` and that is where a
    /// reader should be sent. The production comment now says so.
    ///
    /// Fixtures were measured, not guessed. `URL(string:)` on this toolchain is lenient enough
    /// that `"not a url with spaces"` parses (it percent-encodes), so the obvious fixture would
    /// have asserted nothing; `""` and an unterminated IPv6 literal are the forms that return nil.
    ///
    /// RED: delete the `URL(string:)` precondition from `EmbeddingConfig.init` → the validating
    /// init keeps rejecting, but the invariant this test states ("no door admits an unparseable
    /// base") stops being true, and the third assertion below fails.
    func testEmbeddingConfig_refusesAnUnparseableBase_makingTheClientsGuardUnreachable() {
        let unparseable = ["", "http://[::1", "ht tp://x"]
        let lenient = ["not a url with spaces", "   "]

        for bad in unparseable {
            XCTAssertNil(URL(string: bad), "fixture is not actually unparseable: \(bad.debugDescription)")
            XCTAssertNil(
                EmbeddingConfig(validating: bad, modelName: "nomic"),
                """
                EmbeddingConfig(validating: \(bad.debugDescription)) built a config from a base \
                that cannot parse. That is the door untrusted input comes through, and it is what \
                makes LMStudioEmbeddingClient.makeEndpointURL's guard unreachable.
                """)
        }

        for tolerated in lenient {
            XCTAssertNotNil(URL(string: tolerated),
                            "\(tolerated.debugDescription) is expected to parse — if it no longer "
                                + "does, the fixtures above are no longer the interesting ones")
        }

        // The invariant, stated once: every construction door proves the base parses.
        XCTAssertNotNil(EmbeddingConfig(validating: "http://127.0.0.1:1234", modelName: "nomic"),
                        "a well-formed base must still be accepted, or the guard above is vacuous")
    }

    /// The empty-input short-circuit returns before any network work. Pinned because it is the
    /// path `SearchIndexCoordinator` takes on an empty batch, and a regression there turns a
    /// no-op into a round-trip against a server that may not be running.
    ///
    /// RED: move the `texts.isEmpty` return below the request build → this starts making a call
    /// and the assertion's timing changes from instant to a connection refusal.
    func testEmbeddingClient_emptyTexts_returnsWithoutACall() async throws {
        let client = LMStudioEmbeddingClient()
        let config = EmbeddingConfig(baseURLString: "http://127.0.0.1:1", modelName: "nomic")
        let vectors = try await client.embed(texts: [], config: config)
        XCTAssertTrue(vectors.isEmpty)
    }
}
