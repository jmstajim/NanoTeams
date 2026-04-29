import XCTest

@testable import NanoTeams

/// Pins the routing of the overriding resolver: the SecureField-supplied token
/// applies ONLY to the URL the user is testing against, never bleeds to other
/// URLs that the same request batch happens to touch.
final class OverridingLLMTokenResolverTests: XCTestCase {

    func testOverrideURL_winsOverFallback() {
        let fallback = StubLLMTokenResolver(["http://localhost:1234": "from-keychain"])
        let sut = OverridingLLMTokenResolver(
            overrides: ["http://localhost:1234": "from-securefield"],
            fallback: fallback
        )
        XCTAssertEqual(sut.token(forBaseURL: "http://localhost:1234"), "from-securefield")
    }

    func testNonOverrideURL_fallsThroughToFallback() {
        let fallback = StubLLMTokenResolver([
            "http://localhost:1234": "global-token",
            "http://other:9999": "other-token"
        ])
        // Override only on `:1234`. `:9999` must fall through.
        let sut = OverridingLLMTokenResolver(
            overrides: ["http://localhost:1234": "ui-typed"],
            fallback: fallback
        )
        XCTAssertEqual(sut.token(forBaseURL: "http://other:9999"), "other-token")
    }

    func testEmptyOverrides_behavesAsFallback() {
        let fallback = StubLLMTokenResolver(["http://localhost:1234": "tok"])
        let sut = OverridingLLMTokenResolver(overrides: [:], fallback: fallback)
        XCTAssertEqual(sut.token(forBaseURL: "http://localhost:1234"), "tok")
    }

    func testOverrideURLs_areNormalizedAtConstruction() {
        // Stored under one form; queried with another (case + trailing slash).
        let sut = OverridingLLMTokenResolver(
            overrides: ["HTTP://LOCALHOST:1234/": "ui"],
            fallback: StubLLMTokenResolver([:])
        )
        XCTAssertEqual(sut.token(forBaseURL: "http://localhost:1234"), "ui")
    }

    func testQueryURL_isNormalizedAtLookup() {
        let sut = OverridingLLMTokenResolver(
            overrides: ["http://localhost:1234": "ui"],
            fallback: StubLLMTokenResolver([:])
        )
        // Lookup with trailing slash + uppercase: normalize must apply.
        XCTAssertEqual(sut.token(forBaseURL: "HTTP://LOCALHOST:1234/"), "ui")
    }

    func testNoOverrideAndNoFallback_returnsNil() {
        let sut = OverridingLLMTokenResolver(
            overrides: [:],
            fallback: StubLLMTokenResolver([:])
        )
        XCTAssertNil(sut.token(forBaseURL: "http://localhost:1234"))
    }

    func testMultipleOverrides_eachOnlyAppliesToItsURL() {
        let fallback = StubLLMTokenResolver([:])
        let sut = OverridingLLMTokenResolver(
            overrides: [
                "http://server-a:1": "tok-a",
                "http://server-b:2": "tok-b"
            ],
            fallback: fallback
        )
        XCTAssertEqual(sut.token(forBaseURL: "http://server-a:1"), "tok-a")
        XCTAssertEqual(sut.token(forBaseURL: "http://server-b:2"), "tok-b")
        XCTAssertNil(sut.token(forBaseURL: "http://server-c:3"))
    }

    // MARK: - Empty-override drop (regression for the Vision/Embeddings card bug)

    /// Critical security invariant: an empty SecureField in a Vision /
    /// Embeddings / Role-override card MUST fall through to the Keychain
    /// resolver, not silently force an unauthenticated request. The earlier
    /// implementation forwarded `[url: ""]` and returned `""` for that URL,
    /// which suppressed the main LLM card's token even when the URL was
    /// inherited.
    func testEmptyOverride_isDroppedAndFallsThrough() {
        let fallback = StubLLMTokenResolver(["http://localhost:1234": "from-keychain"])
        let sut = OverridingLLMTokenResolver(
            overrides: ["http://localhost:1234": ""],
            fallback: fallback
        )
        XCTAssertEqual(
            sut.token(forBaseURL: "http://localhost:1234"),
            "from-keychain",
            "Empty override must NOT shadow the Keychain token. This is the regression "
                + "that orphaned tokens entered via Vision/Embeddings cards with empty URL fields."
        )
    }

    func testWhitespaceOnlyOverride_isDroppedAndFallsThrough() {
        let fallback = StubLLMTokenResolver(["http://localhost:1234": "from-keychain"])
        let sut = OverridingLLMTokenResolver(
            overrides: ["http://localhost:1234": "   \n\t  "],
            fallback: fallback
        )
        XCTAssertEqual(sut.token(forBaseURL: "http://localhost:1234"), "from-keychain")
    }

    func testMixedOverrides_emptyDropped_nonEmptyKept() {
        let fallback = StubLLMTokenResolver(["http://server-b:2": "fallback-b"])
        let sut = OverridingLLMTokenResolver(
            overrides: [
                "http://server-a:1": "tok-a",
                "http://server-b:2": "",
                "http://server-c:3": "  \n  "
            ],
            fallback: fallback
        )
        XCTAssertEqual(sut.token(forBaseURL: "http://server-a:1"), "tok-a")
        XCTAssertEqual(
            sut.token(forBaseURL: "http://server-b:2"), "fallback-b",
            "Empty override for B must fall through to fallback."
        )
        XCTAssertNil(
            sut.token(forBaseURL: "http://server-c:3"),
            "Whitespace override for C is dropped; fallback has no entry → nil."
        )
    }

    func testOverride_isTrimmedBeforeStorage() {
        // A pasted token with a stray trailing newline should not break header
        // construction. The resolver normalizes the value at construction.
        let sut = OverridingLLMTokenResolver(
            overrides: ["http://x:1": "  abc \n"],
            fallback: StubLLMTokenResolver([:])
        )
        XCTAssertEqual(sut.token(forBaseURL: "http://x:1"), "abc")
    }

    // MARK: - Nesting trap (regression for the I1/I5 review findings)

    /// Pins the merge-and-flatten contract for nested overrides. CLAUDE.md
    /// states that a nested `OverridingLLMTokenResolver` MUST be flattened
    /// (no two-layer override chain) so the outer's overrides can never
    /// silently shadow the inner's. This test traps a future refactor that
    /// drops the flatten step — without it, a UI-typed token could leak
    /// past an inner override into the outer's URL space.
    ///
    /// The constructor fires `assertionFailure` on detected nesting,
    /// which is fatal in DEBUG. We test the pure `flatten` helper
    /// directly so the contract is verifiable without crashing the test
    /// process. The init's assertion path is exercised only as a smoke
    /// signal in DEBUG/CI by the build itself (any code that nests in a
    /// shipped path will halt the test target — that's the intent).
    func testFlatten_nestedFallback_mergesBothLayers() {
        let keychain = StubLLMTokenResolver(["http://keychain:1": "from-keychain"])
        let inner = OverridingLLMTokenResolver(
            overrides: ["http://server-a:1": "inner-a"],
            fallback: keychain
        )
        let result = OverridingLLMTokenResolver.flatten(
            newOverrides: ["http://server-b:2": "outer-b"],
            fallback: inner
        )

        XCTAssertTrue(
            result.didDetectNesting,
            "flatten must report nesting so the init can fire assertionFailure."
        )

        // Synthesize the merged resolver via `flatten`'s outputs (mirrors
        // exactly what the init would store, without invoking the init's
        // assertionFailure).
        let merged = SyntheticOverrideResolver(
            overrides: result.overrides,
            fallback: result.fallback
        )
        XCTAssertEqual(merged.token(forBaseURL: "http://server-a:1"), "inner-a")
        XCTAssertEqual(merged.token(forBaseURL: "http://server-b:2"), "outer-b")
        XCTAssertEqual(merged.token(forBaseURL: "http://keychain:1"), "from-keychain")
    }

    /// Outer wins on conflict — the user's freshly-typed Test Connection
    /// token must override an older nested override for the same URL.
    func testFlatten_nestedFallback_outerWinsOnConflict() {
        let inner = OverridingLLMTokenResolver(
            overrides: ["http://shared:1": "inner-stale"],
            fallback: StubLLMTokenResolver([:])
        )
        let result = OverridingLLMTokenResolver.flatten(
            newOverrides: ["http://shared:1": "outer-fresh"],
            fallback: inner
        )
        XCTAssertTrue(result.didDetectNesting)

        let merged = SyntheticOverrideResolver(
            overrides: result.overrides,
            fallback: result.fallback
        )
        XCTAssertEqual(merged.token(forBaseURL: "http://shared:1"), "outer-fresh")
    }

    /// Non-nested case must NOT report nesting — otherwise every normal
    /// construction would trip the assertion.
    func testFlatten_nonNestedFallback_doesNotReportNesting() {
        let result = OverridingLLMTokenResolver.flatten(
            newOverrides: ["http://x:1": "tok"],
            fallback: StubLLMTokenResolver(["http://x:2": "from-keychain"])
        )
        XCTAssertFalse(result.didDetectNesting)
        XCTAssertEqual(result.overrides["http://x:1"], "tok")
    }
}

// MARK: - Test-local helper

/// Minimal `LLMTokenResolver` that just routes overrides → fallback. Used by
/// the flatten tests above to materialize a resolver from `flatten`'s output
/// WITHOUT invoking `OverridingLLMTokenResolver.init` (which would fire
/// `assertionFailure` in DEBUG when nesting is detected). Mirrors the
/// behaviour of `OverridingLLMTokenResolver.token(forBaseURL:)` exactly.
private struct SyntheticOverrideResolver: LLMTokenResolver {
    let overrides: [String: String]
    let fallback: any LLMTokenResolver

    func token(forBaseURL urlString: String) -> String? {
        let key = KeychainSecureTokenStorage.normalize(baseURL: urlString)
        if let override = overrides[key] { return override }
        return fallback.token(forBaseURL: urlString)
    }
}
